# Writing programs for causticos

A program here is a `.cst` file compiled to a `.cse` and put on the root image.
Four shapes, in the order they get harder: a terminal program, a window, a
network client, and audio.

Every one of them ends with the same three steps, so they are worth learning
once:

1. **Write** `userspace/<category>/<name>.cst`.
2. **Declare** it in `userspace/Causticfile` — this file *is* the build.
3. **Ship** it: add a `bin <name>` line to a profile in `profiles/`.

```
target "hello" {
    src "coreutils/hello.cst"
    out "build/hello.cse"
}
```

```sh
caustic-mk run run          # builds kernel + userspace + ISO, then boots it
```

There is no third list. A `bin` naming something that is not a target fails the
build by name, and `caustic-mk run doctor` checks every profile against the
manifest before you get that far.

---

## 1. A terminal program

The whole of `coreutils/echo.cst`:

```caustic
use "std/causticos/prog.cst" as prog;

fn main(argc as i64, argv as *u8) as i32 {
    let is i64 as i with mut = 1;
    while (i < argc) {
        prog.outs(prog.arg(argv, i));
        if (i < argc - 1) { prog.out(" ", 1); }
        i = i + 1;
    }
    prog.out("\n", 1);
    return 0;
}
```

`prog` is the small facade over the syscall ABI: `prog.arg(argv, i)` for an
argument, `prog.out(buf, len)` and `prog.outs(cstr)` for stdout, `prog.getc()`
and `prog.getline()` for stdin. Return 0 for success.

The import path is relative to the source file and reaches into the sibling
Caustic checkout — set `CAUSTIC_DIR` if yours is somewhere else.

File and text tools share `userspace/lib/futil` (a buffered reader, a whole-file
`slurp`, small parse helpers). Read `coreutils/wc.cst` before writing your own
line counter.

---

## 2. A window

A graphical program is a **client of the compositor**. It does not touch the
framebuffer: it asks for a shared memory segment, draws pixels into it, and
tells the window manager which rectangle changed. The compositor composites.

The conversation is 32-byte messages on `wmproto.WM_FD`, in this order:

```caustic
use "../../lib/wmproto/wmproto.cst" as wmp;
use "std/os/causticos.cst" as sys;

// 1. Read MSG_WELCOME — it carries the screen size and the size the WM gave you.
//    a = screen_w, b = screen_h, c = (win_w << 32) | win_h
let is [4]i64 as m;
let is [32]u8 as acc;
let is i64 as fill with mut = 0;
while (wmp.msg_read(wmp.WM_FD, &fill, cast(*u8, &acc[0]), &m[0]) != 1) { }

// 2. Make a pixel buffer big enough for the whole screen, once. A resize
//    changes which sub-rectangle you use, not the allocation.
let is i64 as npages = (m[1] * m[2] * 4 + 4095) / 4096;
let is i64 as seg = sys.seg_create(npages, 0);
let is i64 as va  = sys.mmap_fd(sys.PROT_READ | sys.PROT_WRITE, seg);

// 3. Send the FD FIRST, then the message announcing it. FD_SEND has a single
//    slot, so the order matters.
sys.fd_send(wmp.WM_FD, seg);
wmp.msg_send(wmp.WM_FD, wmp.MSG_HELLO, npages, m[1] * 4, wmp.PROTO_VER);
```

After that it is a loop: write 32-bit pixels into the mapping, send
`MSG_COMMIT` with the damaged rectangle, and read events.

| You send | Meaning |
|---|---|
| `MSG_HELLO` | here is my buffer (npages, stride, protocol version) |
| `MSG_COMMIT` | this rectangle changed: `a=x b=y c=(w<<32)\|h` |
| `MSG_SET_TITLE` | up to 16 bytes, packed into `b` and `c` |
| `MSG_CLOSE` | I am exiting |
| `MSG_SPAWN_REQ` | please open another terminal |
| `MSG_SPAWN_NAMED` | open a complete root filename; use `wmp.spawn_named(name, len)` |
| `MSG_POINTER_TRACK` | `a=1` subscribes to pointer motion without a button held; `a=0` stops it |

| You receive | Meaning |
|---|---|
| `MSG_WELCOME` | screen size + your window size |
| `MSG_KEY` | a keysym, normalised |
| `MSG_MOUSE_BTN` | button mask + x,y relative to your content |
| `MSG_MOUSE_MOVE` | latest content-relative pointer position, buttons and modifiers |
| `MSG_MOUSE_WHEEL` | delta + position |
| `MSG_RESIZE` | your new size |
| `MSG_FOCUS` | 0 or 1 |
| `MSG_CLOSE_REQ` | please exit |

Protocol version 3 sends `MSG_SPAWN_NAMED` filenames in a segment before the
message (`a=filename byte length`, `b=c=0`), following the same FD-send ordering
as the clipboard. Include `.cse`; do not use title packing or shell quoting.
The WM passes the selected image path literally, including spaces, apostrophes
and dollar signs. The 16-byte title field limits presentation, not file selection.

The launcher runs console applications inside `wterm` and passes the selected
image path literally. This gives `newterm` the terminal control channel it needs
to request another terminal; window applications are started directly.

Pointer motion is always delivered during a button grab. Unpressed motion is
opt-in through `MSG_POINTER_TRACK`; subscribers also receive the position when
the pointer leaves their content. Coordinates can be outside the window.
Motion is coalesced, so clients must use the latest position rather than count
events. The launcher uses this to update its application description panel;
terminals do not subscribe.

`userspace/wm/wmpat/wmpat.cst` is the smallest complete example — a window that
draws a pattern and handles resize. Read it start to finish; it is short.

A **text** window (a terminal, a TUI) uses the same protocol with
`kind = 1` in `MSG_HELLO`: the segment then holds packed character cells rather
than pixels, and the compositor renders the font. That is what `wterm` does, and
it is why a terminal costs a few hundred KB instead of a full framebuffer.

---

## 3. A network client

The network stack lives in **ring 3**, in `netd`. A program does not speak to
the NIC; it asks netd for an endpoint. netd is started by the compositor (it is
`/init`, so it is the one process allowed to), and it is already running by the
time your program does.

The layers, pick the one you need:

| Layer | Use it for |
|---|---|
| `lib/netcli` | a `Conn`: `read`, `write`, `write_all`, `read_exact`, `close` |
| `lib/http` | `build_request`, `read_head`, chunked bodies, redirects |
| `lib/tls` | TLS 1.3 with certificate verification, over any `Conn` |
| `DEV_NET` directly | raw ethernet frames — what `ping` uses for ICMP |

`wget` is the worked example that goes all the way up:

```caustic
use "../lib/netcli/netcli.cst" as nc;
use "../lib/http/http.cst"     as http;
use "../lib/tls/tls13.cst"     as tls;

// a TCP Conn, optionally wrapped in TLS, then HTTP on top
tls.client(&tlsctx, &raw, ...);
http.build_request(cast(*u8, &reqbuf[0]), 2048, ...);
http.read_head(&resp, &conn, 0);
```

`wget` downloads into a PID-specific directory reserved with `mkdir` in the
destination's parent, then renames the completed file to its requested name.
Only a complete HTTP 200 body and a successful close reach that publication
step; a successful zero-byte body still creates its output. HTTP errors,
certificate rejection, and truncated transfers discard this invocation's
temporary data without creating or truncating the requested destination.
A pre-existing temporary directory is refused, never reused or removed.
`test-shell-net.sh` exercises output absence, preservation of existing bytes,
successful replacement, and a legitimate empty response through the real shell.

`ping` is the opposite end — it opens `DEV_NET` and builds ICMP by hand. Both
are legitimate; the question is whether you want a byte stream or a packet.

Under QEMU the guest reaches the outside world through SLIRP, and nothing
reaches in unless a port is forwarded — `qemu-args.sh` forwards one for the
guest's `httpd`.

---

## 4. Audio

Two ways in, and the difference is whether you want to share.

**Through `soundd`** — the userspace mixer. More than one program can be audible
at once. The spawning process supplies a channel; `lib/sndcli`'s `adopt()`
checks it and `endpoint()` supplies one to a child. `open(id)` opens a voice at
the mixer's reported sample rate and channel count; `write(id, pcm, bytes)`
feeds PCM with backpressure, `drain(id)` waits for playback, and `close(id)`
releases the voice.

`aplay FILE.wav` and `aplay URL` use this path by default. A missing mixer
channel is an error, not a reason to take the hardware silently.


**Directly** — `sys.dev_open(sys.DEV_AUDIO_OUT, dev, 0)` gives you the device
itself: a DMA ring of PCM plus a control page, mapped into your address space.
There is no mixer in the kernel, so **one holder at a time** — and the grab
stack makes a second opener a takeover, not a refusal. Use this only when
exclusive control is intentional.

`aplay --direct [-d INDEX] FILE.wav` opts into this takeover; `-d` without
`--direct` is rejected. Releasing the device restores the previous holder,
including a displaced `soundd`. `arecord` uses `DEV_AUDIO_IN` for capture,
with the same mapped-ring shape.

---

## Where things live

```
userspace/
  coreutils/     cat, ls, grep, sort, …  (the ~45 small ones)
  sysutils/      ps, top, df, wget, ping, aplay, …
  editors/       vic, pager, hexedit
  shell/         the shell
  wm/            compositor, wm, wterm, launcher, wmpat
  soundd/        the audio mixer
  tests/         in-system harnesses (runall drives them)
  lib/           shared code — futil, netcli, http, tls, wmproto, sndcli, …
  Causticfile    every target: the build
profiles/        which of them ship, per image
```

## Testing it

The fastest loop is not a full boot: put your program on a root image as `/init`
and boot straight into it.

```sh
caustic-mk run iso -- --profile base --init mytest --out build/t.iso
caustic-mk run run -- --iso build/t.iso --headless
```

Whatever it writes to stdout comes out on the serial console. That is how the
`tests/*.cst` harnesses work, and `scripts/test-*.sh` wraps the pattern — read
`scripts/test-link.sh`, it is about thirty lines.

For something that needs the whole desktop, add `bin mytest` to
`profiles/desktop.profile` and open it from the launcher.

## Language notes

causticos is written in Caustic, and a few of its edges matter here:

- **Struct fields should be `i64`.** Mixed widths (`u8` next to a pointer) can
  alias each other. Byte arrays go last. `AllI64` and `VtableShape` in
  `tests/u64t.cst` assert the two proven shapes still behave.
- **`call()` for function pointers**, not a bare call.
- **No cyclic imports** — the compiler crashes on them, which is why composition
  is pushed up to `main`.
- Relative paths in `use` work, including `../`.

[caustic-language-gotchas]: more of these live in the Caustic repo's own docs.

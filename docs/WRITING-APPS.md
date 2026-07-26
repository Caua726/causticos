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
caustic-mk run build && caustic-mk run run
```

There is no third list. A `bin` naming something that is not a target fails the
build by name, and `caustic-mk run doctor` checks every profile against the
manifest before you get that far.

---

## 1. A terminal program

The whole of `coreutils/echo.cst`:

```caustic
use "../../../Caustic/std/causticos/prog.cst" as prog;

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
use "../../../../Caustic/std/os/causticos.cst" as sys;

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

| You receive | Meaning |
|---|---|
| `MSG_WELCOME` | screen size + your window size |
| `MSG_KEY` | a keysym, normalised |
| `MSG_MOUSE_BTN` | button mask + x,y relative to your content |
| `MSG_MOUSE_WHEEL` | delta + position |
| `MSG_RESIZE` | your new size |
| `MSG_FOCUS` | 0 or 1 |
| `MSG_CLOSE_REQ` | please exit |

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

`ping` is the opposite end — it opens `DEV_NET` and builds ICMP by hand. Both
are legitimate; the question is whether you want a byte stream or a packet.

Under QEMU the guest reaches the outside world through SLIRP, and nothing
reaches in unless a port is forwarded — `qemu-args.sh` forwards one for the
guest's `httpd`.

---

## 4. Audio

Two ways in, and the difference is whether you want to share.

**Through `soundd`** — the mixer. More than one program can be audible at once.
`lib/sndcli` handles finding it, loading a file, and attaching:

```caustic
use "../lib/sndcli/sndcli.cst" as snd;

if (snd.available() != 0) {
    let is i64 as len with mut = 0;
    let is i64 as img = snd.load(cast(*u8, "/tone.wav"), &len);
    // ... hand it to soundd
}
```

**Directly** — `sys.dev_open(sys.DEV_AUDIO_OUT, dev, 0)` gives you the device
itself: a DMA ring of PCM plus a control page, mapped into your address space.
There is no mixer in the kernel, so **one holder at a time** — and the grab
stack makes a second opener a takeover, not a refusal. That is the right shape
for a media player and the wrong one for a notification sound.

`aplay` and `arecord` are the worked examples. `DEV_AUDIO_IN` is capture, same
shape.

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

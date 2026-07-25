# CausticOS userspace

The programs that run *on* CausticOS, written in Caustic. This is where
userspace lives — the shell and its tools today, more (an editor, …) to come.

| program | what it does |
|---|---|
| `shell.cst`  | the framebuffer shell — the `/init`. Holds the surface + keyboard, renders an 8x16 console, runs a REPL: parse argv → builtin (`help`) or load `/<cmd>.cse` → spawn with a console channel + argv → pump stdout → wait. |
| `echo.cst`   | print the arguments |
| `cat.cst`    | print a file |
| `ls.cst`     | list a directory |
| `uptime.cst` | time since boot |
| `sysinfo.cst`| kernel version + limits |

## Building

These import the Caustic stdlib facades (`std/causticos/*`, `std/os/causticos.cst`)
from the **sibling Caustic compiler repo** (`../../Caustic/std/…`) — that stdlib is
the compiler's, entangled with its portable `io`/`os` facades, so it stays there.

```sh
caustic-mk build all       # -> build/<name>.cse, every target in ./Causticfile
caustic-mk build wterm     # just one
CAUSTIC_DIR=/path/to/Caustic caustic-mk build all   # if Caustic isn't the sibling dir
```

Then boot it: `caustic-mk run build -- --profile shell && caustic-mk run run` from the repository root.

# portable.sh — the handful of things that are not the same on every host.
#
# Sourced by the entry scripts. Two differences bite in practice and both have
# an honest answer rather than a workaround:
#
#   PY          Python is `python3` on Linux and in MSYS2, and frequently just
#               `python` on Windows (the python.org installer, and the Store
#               stub). Hardcoding `python3` fails there with "command not found"
#               for a Python that is installed and on PATH.
#
#   qemu_accel  Hardware virtualisation has a different name per host: KVM on
#               Linux, WHPX on Windows (Hyper-V), HVF on macOS. Passing
#               -enable-kvm on Windows is not slower, it is a hard error.
#               Everything falls back to TCG, which for a system this small
#               costs about 20% of boot time — measured, 3.4s vs 2.8s to a
#               ready desktop — so a machine with no acceleration at all is a
#               perfectly usable one.

# Python, by whichever name it has here.
if [ -z "${PY:-}" ]; then
    if command -v python3 >/dev/null 2>&1; then PY=python3
    elif command -v python >/dev/null 2>&1; then PY=python
    else PY=python3   # let it fail by name, so the error says what is missing
    fi
fi
export PY

# Echo the QEMU accelerator to use, and nothing else. `tcg` is always available.
qemu_accel() {
    case "$(uname -s 2>/dev/null || echo unknown)" in
        Linux)
            # WSL2 exposes /dev/kvm when nested virtualisation is on; without it
            # this correctly reports tcg rather than failing at launch.
            [ -w /dev/kvm ] && { echo kvm; return; } ;;
        Darwin)
            echo hvf; return ;;
        MINGW*|MSYS*|CYGWIN*)
            # Hyper-V's platform API. Present when "Windows Hypervisor Platform"
            # is enabled; QEMU refuses at startup when it is not, so ask first.
            if qemu-system-x86_64 -accel help 2>/dev/null | grep -qi whpx; then
                echo whpx; return
            fi ;;
    esac
    echo tcg
}

# True when the host is Windows-with-a-unix-shell (Git Bash / MSYS2). QEMU there
# is a native Windows binary and wants Windows paths, while the shell hands it
# MSYS ones — callers that pass a path to QEMU have to convert.
is_windows_shell() {
    case "$(uname -s 2>/dev/null || echo unknown)" in
        MINGW*|MSYS*|CYGWIN*) return 0 ;;
        *) return 1 ;;
    esac
}

# A path QEMU will accept. On MSYS, `cygpath -w` turns /c/foo into C:\foo;
# everywhere else the path is already right.
hostpath() {
    if is_windows_shell && command -v cygpath >/dev/null 2>&1; then
        cygpath -w "$1"
    else
        printf '%s' "$1"
    fi
}

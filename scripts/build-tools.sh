#!/usr/bin/env bash
source "$(dirname "$0")/portable.sh"
# build-tools.sh — build the toolchain binaries the chosen profile ships.
#
# A profile names them with `tool <target> <guestpath>` (the `dev` profile ships
# the compiler, assembler and linker); scripts/mkroot.py --tools says which
# targets that is. Each one is an ordinary target in the top Causticfile, so
# caustic-mk decides whether it is stale by its whole import closure, and a tree
# where nothing changed costs a stat per source.
#
# A profile that ships no tool builds nothing here — the desktop does not wait
# on a compiler it will not carry.
#
# Invoked from the Causticfile's `build` script with the same arguments as
# mkiso.sh, of which it reads only --profile.
set -euo pipefail

cd "$(dirname "$0")/.."

PROFILE="${COS_PROFILE:-desktop}"
while [ $# -gt 0 ]; do
    case "$1" in
        --profile) PROFILE="$2"; shift 2 ;;
        --profile=*) PROFILE="${1#*=}"; shift ;;
        # mkiso's other options: skipped with their values, so a value that
        # happens to read "--profile" is not taken for the option.
        --out|--cmdline|--init|--add|--size) shift 2 ;;
        *) shift ;;
    esac
done

TOOLS="$("${PY:-python3}" scripts/mkroot.py --profile "$PROFILE" --tools)"
[ -n "$TOOLS" ] || exit 0

# The tools — and the /src and /std the dev profile mirrors beside them — are
# built from the checkout as it stands, committed or not. That is what a dev
# image is for, but an image carrying edits nobody committed should say so.
CAUSTIC_DIR="${CAUSTIC_DIR:-../Caustic}"
if command -v git > /dev/null 2>&1 \
   && git -C "$CAUSTIC_DIR" rev-parse --git-dir > /dev/null 2>&1; then
    dirty="$(git -C "$CAUSTIC_DIR" status --porcelain --untracked-files=no 2>/dev/null | wc -l)"
    if [ "$dirty" -gt 0 ]; then
        echo "build-tools: $CAUSTIC_DIR has $dirty uncommitted change(s); the $PROFILE image carries them"
    fi
fi

for t in $TOOLS; do
    caustic-mk build "$t"
done

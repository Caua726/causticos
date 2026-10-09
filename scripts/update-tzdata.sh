#!/usr/bin/env bash
# update-tzdata.sh — refresh userspace/lib/tz/zoneinfo, the IANA time zone
# database the root image ships as /etc/zoneinfo.
#
# The input is the host's tzdata.zi: the whole public-domain tz source in the
# compact form distributions install beside their compiled zones. zic compiles
# it here, once, so building an image needs neither zic nor a host zoneinfo
# tree. `-b slim` drops transitions the footer rule already predicts; lib/tz
# evaluates that rule, and the tree stays about a third of the fat size.
#
# Links come out as hard links. Git stores each as its own path with the same
# blob, and the image builder copies them as plain files: a name that is a link
# in tzdata is still a name a user can choose.
#
# The database changes several times a year as governments change their
# clocks, so this is run now and then rather than once.
set -euo pipefail

R="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$R/userspace/lib/tz/zoneinfo"

command -v zic >/dev/null || { echo "update-tzdata: zic not found" >&2; exit 1; }

SRC=""
for c in /usr/share/zoneinfo/tzdata.zi /usr/share/lib/zoneinfo/tzdata.zi; do
    if [ -s "$c" ]; then SRC="$c"; break; fi
done
if [ -z "$SRC" ]; then
    echo "update-tzdata: no tzdata.zi found on this host" >&2
    exit 1
fi

VERSION=$(sed -n '1s/^# version //p' "$SRC")
[ -n "$VERSION" ] || { echo "update-tzdata: $SRC names no version" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
zic -b slim -d "$TMP/zoneinfo" "$SRC"
printf '%s\n' "$VERSION" > "$TMP/zoneinfo/+VERSION"

rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
mv "$TMP/zoneinfo" "$OUT"
N=$(find "$OUT" -type f ! -name '+VERSION' | wc -l)
echo "update-tzdata: $N zones, tzdata $VERSION from $SRC -> $OUT"

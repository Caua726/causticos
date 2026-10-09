#!/bin/bash
# test-https-real.sh — HTTPS against the real internet, with the trust store the
# machine ships.
#
# Every other TLS test talks to a server on the host with a certificate from
# scripts/make-test-certs.sh. That proves the protocol against OpenSSL and the
# refusals against chains built to be wrong, and nothing about the web: whether
# the 121 roots in /etc/ca.pem anchor the chains real sites send, whether the
# intermediates and key types those CAs use today are ones x509v can check,
# whether a real server's handshake has anything in it the local one never
# sends. This one types wget at the prompt of the shell image — the trust store
# untouched — and fetches from sites whose certificates come from different
# public CAs, comparing every byte with what the host fetched at the same time.
#
# Then three refusals with REAL chains, each required to fail for its own
# reason, read back from what wget said (a refusal for some other reason — the
# network down, say — is not the refusal being tested):
#
#   wrong name       a real site dialled by its address: the chain is perfect
#                    and it names a host, just not the one that was asked for
#   wrong anchors    /etc/ca.pem swapped for the test CA alone, then a real
#                    site: nothing anchors its chain
#   TLS 1.2 only     badssl.com, which has never offered 1.3: refused, and the
#                    message says why
#
# It needs the internet, so it is not part of the default run: ONLINE=1
# scripts/test-userspace.sh adds it, or run it alone. Exit 0 pass, 1 fail,
# 2 NOT RUN — the host itself could not reach a site, which is said in words
# and is never reported as a pass.
#
#   scripts/test-https-real.sh
set -e
cd "$(cd "$(dirname "$0")/.." && pwd)"

source "$(dirname "$0")/portable.sh"

# Static files on sites whose chains come from different CAs: Google Trust
# Services, Sectigo, Let's Encrypt (ISRG), DigiCert/GlobalSign behind
# Wikipedia, and Cloudflare's own edge.
SITES=(
    "https://www.google.com/robots.txt"
    "https://github.com/robots.txt"
    "https://letsencrypt.org/robots.txt"
    "https://en.wikipedia.org/robots.txt"
    "https://www.cloudflare.com/robots.txt"
)
WRONG_NAME_HOST=github.com
TLS12_URL="https://badssl.com/"

[ -f build/causticos.iso ] || { echo "build/causticos.iso missing — NOBOOT=1 scripts/run.sh"; exit 1; }
[ -f userspace/build/wget.cse ] || { echo "userspace not built"; exit 1; }
[ -f build/certs/ca.pem ] || bash scripts/make-test-certs.sh >/dev/null
command -v curl >/dev/null || { echo "not run: curl is needed on the host to fetch the reference copies"; exit 2; }

W=$(mktemp -d)
GOT=$W/got

# What the host gets, over TLS 1.3 like the guest — the reference every guest
# copy is compared with, and the proof the sites are reachable at all.
i=0
for u in "${SITES[@]}"; do
    i=$((i+1))
    if ! why=$(curl -sS --fail --tlsv1.3 --max-time 20 -o "$W/host$i" "$u" 2>&1); then
        echo "not run: the host cannot fetch $u over TLS 1.3 ($why)"
        rm -rf "$W"; exit 2
    fi
done
WRONG_NAME_IP=$(getent ahostsv4 "$WRONG_NAME_HOST" | awk 'NR==1 { print $1 }')
[ -n "$WRONG_NAME_IP" ] || { echo "not run: the host cannot resolve $WRONG_NAME_HOST"; rm -rf "$W"; exit 2; }
# The 1.2-only refusal means something only if the server really refuses 1.3
# and really serves 1.2; badssl.com turning 1.3 on one day must show up here,
# not as a mysterious failure inside the guest.
if curl -sS --tlsv1.3 --tls-max 1.3 --max-time 20 -o /dev/null "$TLS12_URL" 2>/dev/null; then
    echo "FAIL: $TLS12_URL now speaks TLS 1.3 — pick another 1.2-only server for this check"
    rm -rf "$W"; exit 1
fi
if ! why=$(curl -sS --fail --tls-max 1.2 --max-time 20 -o /dev/null "$TLS12_URL" 2>&1); then
    echo "not run: the host cannot reach $TLS12_URL over TLS 1.2 either ($why)"
    rm -rf "$W"; exit 2
fi

# Its own image, the shell flavour as shipped — /etc/ca.pem is the real bundle —
# plus the test CA at a path nothing reads, for the wrong-anchors check.
DISK=build/disk-https-real.img
"$PY" scripts/mkroot.py --profile shell --img "$DISK" -q \
    --add "build/certs/ca.pem:/etc/test-ca.pem"

MON=/tmp/causticos-httpsreal-mon.$$
LOG=$(mktemp)
QEMU_DISK="$DISK"
QEMU_KVM=1
# root= so the seeded disk is the root rather than the ISO's live one: the host
# reads every result back off it after each command.
if [ -n "${ROOTED_ISO:-}" ]; then
    QEMU_ISO="$ROOTED_ISO"
else
    QEMU_ISO=build/test-https-real.iso
    bash scripts/mkiso.sh --cmdline "root=ahci-p0" --out "$QEMU_ISO" >/dev/null
fi
source scripts/qemu-args.sh

qemu-system-x86_64 "${QEMU_ARGS[@]}" \
    -monitor "unix:$MON,server,nowait" \
    -serial stdio -display none > "$LOG" 2>&1 &
QPID=$!

mon() { printf '%s\n' "$1" | socat - "unix-connect:$MON" >/dev/null 2>&1 || true; }
cleanup() {
    kill -9 $QPID 2>/dev/null || true; wait $QPID 2>/dev/null || true
    rm -f "$MON" "$LOG"; rm -rf "$W"
}
trap cleanup EXIT

UP=0
for _ in $(seq 1 300); do
    if tr -d '\000' < "$LOG" | grep -q "shell: netd up"; then UP=1; break; fi
    kill -0 $QPID 2>/dev/null || break
    sleep 0.1
done
[ "$UP" = 1 ] || { echo "FAIL: the shell never reported netd up"; tail -20 "$LOG"; exit 1; }
for _ in $(seq 1 200); do
    tr -d '\000' < "$LOG" | grep -q "netd: dhcp bound" && break
    sleep 0.1
done

# ASCII to QEMU key names — what the commands below use and nothing more.
key_of() {
    case "$1" in
        [a-z0-9]) printf '%s' "$1" ;;
        [A-Z]) printf 'shift-%s' "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" ;;
        ' ') printf 'spc' ;;
        '-') printf 'minus' ;;
        '/') printf 'slash' ;;
        '.') printf 'dot' ;;
        ':') printf 'shift-semicolon' ;;
        '>') printf 'shift-dot' ;;
        '|') printf 'shift-backslash' ;;
        '&') printf 'shift-7' ;;
        *)  echo "no key name for '$1'" >&2; exit 1 ;;
    esac
}
type_line() {
    echo "typing: $1"
    local i K
    for (( i=0; i<${#1}; i++ )); do
        K=$(key_of "${1:$i:1}")
        mon "sendkey $K"
    done
    mon "sendkey ret"
}
# The disk is the only signal: the shell's output goes to a framebuffer nobody
# reads. A real site takes longer than the host's loopback, so 40 s, not 20.
wait_marker() {
    local i
    for (( i=0; i<200; i++ )); do
        sleep 0.2
        for m in "$@"; do
            if "$PY" scripts/fat32.py "$DISK" get "$m" "$GOT" >/dev/null 2>&1; then
                echo "$m"; return 0
            fi
        done
        kill -0 $QPID 2>/dev/null || return 1
    done
    return 1
}
said() { "$PY" scripts/fat32.py "$DISK" get "$1" "$GOT" >/dev/null 2>&1 && cat "$GOT"; }

# One fetch typed at the prompt: what wget printed goes to /eN, success or
# failure to a marker, and VERDICT is whichever marker appeared. Run in this
# shell, not in $(...), so a fetch with no verdict ends the script.
VERDICT=""
fetch() {
    local n="$1" url="$2"
    type_line "wget -q -O /r$n.txt $url > /e$n.txt 2>&1 && touch /ok$n || touch /no$n"
    VERDICT=$(wait_marker "ok$n" "no$n") || {
        # The shell's screen and the serial log are all that is left to say
        # what happened: a command line that never ran shows on the screen,
        # and lost keystrokes are reported by the kernel.
        mon "screendump /tmp/https-real-noverdict.ppm"
        echo "FAIL: no verdict for $url within 40 s (screen: /tmp/https-real-noverdict.ppm)"
        tr -d '\000' < "$LOG" | grep -E "kbd:|wget|panic|EXCEPTION" | tail -8
        exit 1
    }
}

i=0
for u in "${SITES[@]}"; do
    i=$((i+1))
    fetch "$i" "$u"
    if [ "$VERDICT" != "ok$i" ]; then
        echo "FAIL: $u was refused: $(said "e$i.txt")"
        exit 1
    fi
    "$PY" scripts/fat32.py "$DISK" get "r$i.txt" "$GOT" >/dev/null
    if ! cmp -s "$GOT" "$W/host$i"; then
        echo "FAIL: $u: the guest got $(stat -c%s "$GOT") bytes that differ from the host's $(stat -c%s "$W/host$i")"
        exit 1
    fi
    echo "  ok   $u — $(stat -c%s "$GOT") bytes, every one the host's"
done

# refused N URL REASON — the fetch must fail, and wget must have said REASON.
refused() {
    local n="$1" url="$2" reason="$3"
    fetch "$n" "$url"
    if [ "$VERDICT" = "ok$n" ]; then echo "FAIL: $url was accepted"; exit 1; fi
    local text; text=$(said "e$n.txt")
    case "$text" in
        *"$reason"*) echo "  ok   $url refused: $(printf '%s' "$text" | tr '\n' ' ')" ;;
        *) echo "FAIL: $url was refused for the wrong reason: $text (wanted: $reason)"; exit 1 ;;
    esac
}

refused 11 "https://$WRONG_NAME_IP/robots.txt" "the certificate is for a different host name"
refused 12 "$TLS12_URL" "this client speaks only TLS 1.3"

type_line "cp /etc/ca.pem /etc/ca.real && cp /etc/test-ca.pem /etc/ca.pem && touch /swapped"
wait_marker swapped >/dev/null || { echo "FAIL: could not swap the trust store"; exit 1; }
refused 13 "${SITES[0]}" "the chain does not lead to a certificate in /etc/ca.pem"

# And back: the same site, the real bundle again, accepted again — so the
# refusal above was the anchors and not the site going away.
type_line "cp /etc/ca.real /etc/ca.pem && touch /restored"
wait_marker restored >/dev/null || { echo "FAIL: could not restore the trust store"; exit 1; }
fetch 14 "${SITES[0]}"
[ "$VERDICT" = "ok14" ] || { echo "FAIL: ${SITES[0]} refused after the bundle came back: $(said e14.txt)"; exit 1; }
echo "  ok   ${SITES[0]} accepted again with the real bundle back"

echo "PASS: ${#SITES[@]} real sites over TLS 1.3, 3 real refusals for their own reasons"

#!/usr/bin/env bash
# Create .env for a new deployment, with every secret freshly generated.
#
#   ./scripts/init-env.sh \
#       --external-ip 198.51.100.7 \
#       --ns-hosts 203.0.113.10,203.0.113.11 \
#       --carrier-hosts 192.0.2.10,192.0.2.11
#
# What it will and will not do:
#   * Generates ARI_PASS, the NetSapiens digest credentials and the operator UI
#     password from /dev/urandom, so no secret ever comes from the repository.
#   * Writes the file mode 600 from the first byte (umask 077), not chmod'd after.
#   * NEVER overwrites an existing .env unless --force, which first keeps a 600
#     copy of the old one. Regenerating secrets on a live box would lock
#     NetSapiens out until its trunk is updated to match.
#   * Does not guess your network. Anything you do not pass is left as the
#     placeholder from .env.example and listed at the end, so the entrypoint
#     (which refuses to start on placeholders) cannot come up half-configured.
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXAMPLE="$ROOT/.env.example"
TARGET="${ENV_FILE:-$ROOT/.env}"
FORCE=0
declare -A SET=()

die() { echo "error: $*" >&2; exit 1; }
usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --external-ip)   SET[EXTERNAL_IP]="${2:?}"; shift 2 ;;
        --local-net)     SET[LOCAL_NET]="${2:?}"; shift 2 ;;
        --ns-hosts)      SET[NS_SIP_HOST]="${2:?}"; shift 2 ;;
        --carrier-hosts) SET[CARRIER_SIP_HOST]="${2:?}"; shift 2 ;;
        --max-calls)     SET[MAX_CONCURRENT_CALLS]="${2:?}"; shift 2 ;;
        --max-per-caller) SET[MAX_CONCURRENT_PER_CALLER]="${2:?}"; shift 2 ;;
        --force)         FORCE=1; shift ;;
        -h|--help)       usage 0 ;;
        *)               echo "unknown option: $1" >&2; usage 1 ;;
    esac
done

[ -f "$EXAMPLE" ] || die "missing $EXAMPLE"
if [ -e "$TARGET" ]; then
    [ "$FORCE" -eq 1 ] || die "$TARGET already exists. Refusing to overwrite -- regenerating secrets would lock out NetSapiens. Use --force to replace it (the old file is kept)."
    backup="$TARGET.bak.$(date +%Y%m%d%H%M%S)"
    cp -p "$TARGET" "$backup"; chmod 600 "$backup"
    echo "kept the old file as $backup"
fi

# Alphanumeric only: safe in .env, in SIP digest, and in a shell, with no quoting.
# head closes the pipe once it has enough bytes, so tr is killed by SIGPIPE (exit
# 141) -- which, under pipefail, would abort this whole script silently right
# after generating a perfectly good secret. The || true absorbs that; the length
# check is what guards against the case that actually matters, an unreadable
# /dev/urandom yielding an EMPTY secret.
rand() {
    local out
    out="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$1" || true)"
    [ "${#out}" -eq "$1" ] || die "could not read $1 random characters from /dev/urandom"
    printf '%s' "$out"
}

NS_USER="ns$(rand 8)"
GEN_ARI_PASS="$(rand 32)"
GEN_NS_PASS="$(rand 32)"
GEN_WEB_PASS="$(rand 24)"

setkey() {  # replace KEY=... in the working copy, or append it
    local key="$1" val="$2"
    if grep -qE "^${key}=" "$WORK"; then
        # '|' cannot appear in any value we set, so it is a safe sed delimiter
        sed -i "s|^${key}=.*|${key}=${val}|" "$WORK"
    else
        printf '%s=%s\n' "$key" "$val" >> "$WORK"
    fi
}

WORK="$(mktemp)"; trap 'rm -f "$WORK"' EXIT
cp "$EXAMPLE" "$WORK"
setkey ARI_PASS "$GEN_ARI_PASS"
setkey NS_AUTH_USER "$NS_USER"
setkey NS_AUTH_PASS "$GEN_NS_PASS"
setkey WEB_USER operator
setkey WEB_PASS "$GEN_WEB_PASS"
for k in "${!SET[@]}"; do setkey "$k" "${SET[$k]}"; done

install -m 600 "$WORK" "$TARGET"
echo "wrote $TARGET (mode $(stat -c %a "$TARGET"))"
echo
echo "Enter these on the NetSapiens trunk -- shown once, they are also in $TARGET:"
echo "    username: $NS_USER"
echo "    password: $GEN_NS_PASS"
echo
echo "Operator UI login (reach it through an SSH tunnel; see the README):"
echo "    username: operator"
echo "    password: $GEN_WEB_PASS"

# Anything still on its example value needs a human.
todo=()
grep -qE '^EXTERNAL_IP=203\.0\.113\.10$' "$TARGET" && todo+=("EXTERNAL_IP        (this VM's public IP, as the carrier and NetSapiens see it)")
grep -qE '^NS_SIP_HOST=core1\.example' "$TARGET" && todo+=("NS_SIP_HOST        (NetSapiens server IPs, comma separated)")
grep -qE '^CARRIER_SIP_HOST=sip\.carrier\.example' "$TARGET" && todo+=("CARRIER_SIP_HOST   (carrier gateway IPs; list your failover IPs too)")
grep -qE '^MAX_CONCURRENT_CALLS=0$' "$TARGET" && todo+=("MAX_CONCURRENT_CALLS (a little above your busiest hour; 0 = unlimited)")
if [ "${#todo[@]}" -gt 0 ]; then
    echo
    echo "Still to fill in by hand in $TARGET:"
    printf '    %s\n' "${todo[@]}"
fi

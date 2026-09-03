#!/usr/bin/env bash
# Rebuild the host firewall rules for this box from .env.
#
# SIP is the only thing that faces outward -- ARI, the operator UI and AMI are
# all bound to loopback -- and we only ever exchange signalling with the handful
# of addresses already named in .env. So port 5060 is opened to exactly those
# and closed to everyone else.
#
# Re-run this after changing NS_SIP_HOST or CARRIER_SIP_HOST. It is idempotent:
# every rule it creates is tagged, and a run deletes its own previous rules
# before writing the new set, so nothing accumulates and hand-made rules are
# left alone.
#
#   ./scripts/firewall.sh              # show the plan, change nothing
#   sudo ./scripts/firewall.sh --apply # actually apply it
set -euo pipefail

TAG='ns-announce'
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"
RTP_CONF="$ROOT/asterisk/etc/rtp.conf"
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

die() { echo "error: $*" >&2; exit 1; }

[ -f "$ENV_FILE" ] || die "no $ENV_FILE -- run from the repo, or set ENV_FILE"

# Pull only the keys we need. Sourcing the whole file would drag in passwords we
# have no reason to hold, and would execute anything that got pasted in there.
getenv() { sed -n "s/^[[:space:]]*$1=//p" "$ENV_FILE" | tail -1 | tr -d '"'\''[:space:]'; }

NS_SIP_HOST="$(getenv NS_SIP_HOST)"
CARRIER_SIP_HOST="$(getenv CARRIER_SIP_HOST)"
NS_SIP_PORT="$(getenv NS_SIP_PORT)"; NS_SIP_PORT="${NS_SIP_PORT:-5060}"
CARRIER_SIP_PORT="$(getenv CARRIER_SIP_PORT)"; CARRIER_SIP_PORT="${CARRIER_SIP_PORT:-5060}"

[ -n "$NS_SIP_HOST" ]      || die "NS_SIP_HOST is empty in $ENV_FILE"
[ -n "$CARRIER_SIP_HOST" ] || die "CARRIER_SIP_HOST is empty in $ENV_FILE"

# The RTP range is Asterisk's, so read it from Asterisk's config rather than
# keeping a second copy here that can drift out of step.
RTP_START="$(sed -n 's/^[[:space:]]*rtpstart[[:space:]]*=[[:space:]]*//p' "$RTP_CONF" | tail -1)"
RTP_END="$(sed -n 's/^[[:space:]]*rtpend[[:space:]]*=[[:space:]]*//p' "$RTP_CONF" | tail -1)"
[ -n "$RTP_START" ] && [ -n "$RTP_END" ] || die "could not read rtpstart/rtpend from $RTP_CONF"

# A hostname has to become an address, because that is all the firewall can
# match on. This is a snapshot: if a peer's DNS changes, the rule keeps pointing
# at the old address until this script is run again. Prefer literal IPs in .env.
resolve() {
    local host="$1"
    if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]]; then
        echo "$host"; return
    fi
    local ips
    ips="$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u)"
    [ -n "$ips" ] || die "cannot resolve '$host' -- put a literal IP in $ENV_FILE"
    echo "  note: '$host' resolved to $(echo $ips | tr '\n' ' ')" >&2
    echo "$ips"
}

PEERS=()
collect() {
    local list="$1" port="$2" label="$3" host ip
    IFS=',' read -ra hosts <<< "$list"
    for host in "${hosts[@]}"; do
        host="$(echo "$host" | tr -d '[:space:]')"
        [ -z "$host" ] && continue
        while read -r ip; do
            [ -z "$ip" ] && continue
            PEERS+=("$ip|$port|$label")
        done < <(resolve "$host")
    done
}
collect "$NS_SIP_HOST" "$NS_SIP_PORT" netsapiens
collect "$CARRIER_SIP_HOST" "$CARRIER_SIP_PORT" carrier

command -v ufw >/dev/null || die "ufw not installed (apt install ufw), or adapt this script to your firewall"

echo
echo "Planned rules (tag: $TAG)"
echo "-------------------------------------------------------------"
RULES=()
for peer in "${PEERS[@]}"; do
    IFS='|' read -r ip port label <<< "$peer"
    RULES+=("allow from $ip to any port $port proto udp|SIP from $label")
done
# Media can legitimately arrive from addresses that never appear in signalling,
# so the RTP range stays open. Asterisk's strictrtp=yes is what guards it: after
# the learning phase it drops packets from any other source on that port.
RULES+=("allow $RTP_START:$RTP_END/udp|RTP media (guarded by strictrtp)")
# Must come last. ufw evaluates in order, so this has to sit after the allows.
RULES+=("deny 5060/udp|block SIP from everyone else")

for r in "${RULES[@]}"; do printf '  ufw %-52s # %s\n' "${r%%|*}" "${r##*|}"; done
echo

existing="$(ufw status numbered 2>/dev/null | grep -c "$TAG" || true)"
echo "Existing '$TAG' rules to be removed first: $existing"

if [ "$APPLY" -ne 1 ]; then
    echo
    echo "Dry run -- nothing changed. Re-run with: sudo $0 --apply"
    exit 0
fi

[ "$(id -u)" -eq 0 ] || die "--apply needs root: sudo $0 --apply"

if ! ufw status | head -1 | grep -q 'active'; then
    echo
    echo "WARNING: ufw is INACTIVE. These rules are being stored but will not be"
    echo "enforced until you run 'ufw enable'."
    echo
    echo "Before you enable it, make sure SSH is allowed or you will lock yourself"
    echo "out of this box:    ufw allow OpenSSH"
    echo "This script will not enable ufw or touch default policies for you."
fi

# Delete our previous rules, highest number first -- deleting renumbers
# everything below, so ascending order would delete the wrong rules.
while read -r n; do
    [ -n "$n" ] && ufw --force delete "$n" >/dev/null
done < <(ufw status numbered 2>/dev/null | grep "$TAG" | sed 's/^\[[[:space:]]*\([0-9]*\).*/\1/' | sort -rn)

for r in "${RULES[@]}"; do
    # shellcheck disable=SC2086
    ufw ${r%%|*} comment "$TAG: ${r##*|}" >/dev/null
    printf '  added: %s\n' "${r%%|*}"
done

echo
ufw status verbose | grep -E "Status:|$TAG" || true
echo
echo "Done. SIP now reachable only from the peers in $ENV_FILE."

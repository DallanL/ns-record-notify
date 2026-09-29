#!/usr/bin/env bash
# Build the host firewall for this box from .env.
#
# SIP is the only thing that faces outward -- ARI, the operator UI and AMI are all
# bound to loopback -- and we only ever exchange signalling with the addresses
# named in .env. So 5060 is opened to exactly those and closed to everyone else.
#
#   ./scripts/firewall.sh                     show the plan, change nothing
#   sudo ./scripts/firewall.sh --apply        add/refresh the rules
#   sudo ./scripts/firewall.sh --apply --enable [--ssh-from CIDR]
#                                             ALSO switch the firewall on with
#                                             default-deny -- for a fresh VM
#
# Re-run after changing NS_SIP_HOST or CARRIER_SIP_HOST. It is idempotent: its
# rules carry a "ns-announce:" comment, a run deletes only those and rewrites
# them, and everything else in ufw is left alone.
#
# --enable is a separate flag on purpose. Switching on a default-deny firewall is
# how people lock themselves out of a remote machine, so the script does it only
# when asked, and only after making sure your SSH session is allowed:
#   * the port you are connected on (from $SSH_CONNECTION), and every port sshd
#     listens on, are allowed BEFORE the firewall is enabled;
#   * --ssh-from CIDR limits that to your admin address (strongly recommended --
#     an SSH port open to the whole internet is the most attacked service there is);
#   * that rule has its own "ns-announce-ssh" tag and is never deleted by a re-run.
set -euo pipefail

TAG='ns-announce'
SSH_TAG='ns-announce-ssh'
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"
RTP_CONF="$ROOT/asterisk/etc/rtp.conf"
APPLY=0; ENABLE=0; SSH_FROM=""

die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --apply)    APPLY=1; shift ;;
        --enable)   ENABLE=1; shift ;;
        --ssh-from) SSH_FROM="${2:?--ssh-from needs a CIDR or address}"; shift 2 ;;
        -h|--help)  sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)          die "unknown option: $1" ;;
    esac
done
[ "$ENABLE" -eq 1 ] && [ "$APPLY" -ne 1 ] && die "--enable only makes sense with --apply"

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

# A hostname has to become an address, because that is all the firewall can match
# on. This is a snapshot: if a peer's DNS changes the rule keeps the old address
# until this script is run again. Prefer literal IPs in .env.
resolve() {
    local host="$1"
    if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]]; then echo "$host"; return; fi
    local ips
    ips="$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u)"
    [ -n "$ips" ] || die "cannot resolve '$host' -- put a literal IP in $ENV_FILE"
    echo "  note: '$host' resolved to $(echo $ips | tr '\n' ' ')" >&2
    echo "$ips"
}

# Entries may be  ip | ip:port | hostname | cidr  (the same forms the carrier list
# accepts), so a gateway on its own port gets the right port opened.
PEERS=()
collect() {
    local list="$1" default_port="$2" label="$3" entry host port ip
    local IFS=','
    for entry in $list; do
        entry="$(echo "$entry" | tr -d '[:space:]')"
        [ -z "$entry" ] && continue
        port="$default_port"; host="$entry"
        if [[ "$entry" != */* && "$entry" == *:* ]]; then host="${entry%%:*}"; port="${entry#*:}"; fi
        [[ "$port" =~ ^[0-9]+$ ]] || die "bad port in '$entry'"
        while read -r ip; do
            [ -n "$ip" ] && PEERS+=("$ip|$port|$label")
        done < <(resolve "$host")
    done
}
collect "$NS_SIP_HOST" "$NS_SIP_PORT" netsapiens
collect "$CARRIER_SIP_HOST" "$CARRIER_SIP_PORT" carrier

command -v ufw >/dev/null || die "ufw not installed (apt install ufw), or adapt this script to your firewall"

# Every port sshd is on, plus the one this session is using. Reading only sshd's
# config would miss a session on a non-standard port; reading only the session
# would miss the ports that matter for the NEXT login.
ssh_ports() {
    {
        [ -n "${SSH_CONNECTION:-}" ] && awk '{print $4}' <<<"$SSH_CONNECTION"
        ss -H -tlnp 2>/dev/null | awk '/sshd/ {n=split($4,a,":"); print a[n]}'
        sshd -T 2>/dev/null | awk '$1=="port" {print $2}'
    } | grep -E '^[0-9]+$' | sort -un || true
    # ^ must never fail. Under pipefail a missing sshd, or simply finding no port,
    #   would abort the whole script SILENTLY -- and this is the lookup the lockout
    #   guard depends on, which needs to report "found nothing", not vanish.
}

echo
echo "Planned rules (tag: $TAG)"
echo "-------------------------------------------------------------"
RULES=()
for peer in "${PEERS[@]}"; do
    IFS='|' read -r ip port label <<< "$peer"
    RULES+=("allow from $ip to any port $port proto udp|SIP from $label")
done
# Media can legitimately arrive from addresses that never appear in signalling
# (a carrier's media servers are not its signalling gateways), so RTP stays open
# to any source. Asterisk's strictrtp=yes is what guards it: after the learning
# phase it drops packets from any other source on that port.
RULES+=("allow $RTP_START:$RTP_END/udp|RTP media (guarded by strictrtp)")
# Must come last: ufw evaluates in order, so this has to sit after the allows.
RULES+=("deny 5060/udp|block SIP from everyone else")
for r in "${RULES[@]}"; do printf '  ufw %-52s # %s\n' "${r%%|*}" "${r##*|}"; done

if [ "$ENABLE" -eq 1 ]; then
    echo
    echo "And, because --enable was given:"
    for p in $(ssh_ports); do
        printf '  ufw %-52s # keep your SSH access\n' "allow ${SSH_FROM:+from $SSH_FROM to any }port $p proto tcp"
    done
    echo "  ufw default deny incoming"
    echo "  ufw default allow outgoing"
    echo "  ufw enable"
    [ -z "$(ssh_ports)" ] && echo "  !! no SSH port detected -- --enable would refuse to run"
    [ -z "$SSH_FROM" ] && echo "  note: no --ssh-from, so SSH stays open to the whole internet"
fi

existing="$(ufw status numbered 2>/dev/null | grep -c "$TAG:" || true)"
echo
echo "Existing '$TAG' rules to be removed first: $existing"

if [ "$APPLY" -ne 1 ]; then
    echo
    echo "Dry run -- nothing changed. Re-run with: sudo $0 --apply [--enable]"
    exit 0
fi
[ "$(id -u)" -eq 0 ] || die "--apply needs root: sudo $0 --apply"

if [ "$ENABLE" -eq 1 ]; then
    ports="$(ssh_ports)"
    # Refuse rather than guess: enabling default-deny with no SSH rule is a lockout.
    [ -n "$ports" ] || die "could not find any SSH port to keep open, and --enable would lock you out. Add it yourself first: ufw allow <port>/tcp"
    for p in $ports; do
        # ufw skips a rule that already exists, so re-running does not stack copies.
        # shellcheck disable=SC2086
        ufw allow ${SSH_FROM:+from $SSH_FROM to any} port "$p" proto tcp comment "$SSH_TAG" >/dev/null
        echo "  ssh allowed: tcp/$p${SSH_FROM:+ from $SSH_FROM}"
    done
elif ! ufw status | head -1 | grep -q 'active'; then
    echo
    echo "WARNING: ufw is INACTIVE. These rules are stored but not enforced yet."
    echo "Re-run with --enable to switch it on safely (it keeps your SSH access), or"
    echo "'ufw enable' yourself after 'ufw allow OpenSSH'."
fi

# Delete our previous rules, highest number first -- deleting renumbers everything
# below, so ascending order would delete the wrong rules. The trailing colon keeps
# the SSH rule (tagged ns-announce-ssh) out of this.
while read -r n; do
    [ -n "$n" ] && ufw --force delete "$n" >/dev/null
done < <(ufw status numbered 2>/dev/null | grep "$TAG:" | sed 's/^\[[[:space:]]*\([0-9]*\).*/\1/' | sort -rn)

for r in "${RULES[@]}"; do
    # shellcheck disable=SC2086
    ufw ${r%%|*} comment "$TAG: ${r##*|}" >/dev/null
    printf '  added: %s\n' "${r%%|*}"
done

if [ "$ENABLE" -eq 1 ]; then
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw --force enable >/dev/null
    echo "  firewall ENABLED, default deny incoming"
fi

echo
ufw status verbose | grep -E "Status:|Default:|$TAG" || true
echo
echo "Done. SIP is now reachable only from the peers in $ENV_FILE."

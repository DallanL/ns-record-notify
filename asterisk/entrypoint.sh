#!/bin/bash
# Renders the env-dependent Asterisk configs, then execs Asterisk.
#
# Only pjsip.conf, ari.conf and http.conf depend on the environment. extensions.conf is
# static -- keeping it out of templating means dialplan ${EXTEN}-style variables can never
# be clobbered by envsubst.
set -euo pipefail

: "${EXTERNAL_IP:?EXTERNAL_IP must be set}"
: "${NS_SIP_HOST:?NS_SIP_HOST must be set}"
: "${CARRIER_SIP_HOST:?CARRIER_SIP_HOST must be set}"
: "${ARI_USER:?ARI_USER must be set}"
: "${ARI_PASS:?ARI_PASS must be set}"

# ---------------------------------------------------------------------------
# Refuse to start with secrets that are public knowledge or trivially guessed.
#
# .env.example ships ARI_PASS=change-me-please; a deployment that copies the
# example and forgets one line would otherwise come up looking healthy with a
# call-control password published in the repository. A warning is not enough --
# nobody reads container logs on a box that works. Failing closed makes the
# mistake impossible to miss, and the message says how to fix it.
#
# ALLOW_INSECURE_DEFAULTS=1 downgrades these to warnings, for the integration
# tests and for a lab on a private link. It is deliberately verbose to type.
# ---------------------------------------------------------------------------
weak_secret() {  # $1 = name, $2 = value, $3 = minimum length
    local name="$1" value="$2" min="$3" why=""
    case "${value,,}" in
        change-me*|changeme*|password*|admin*|secret*|asterisk*|123456*) why="is a well-known placeholder" ;;
    esac
    [ -z "$why" ] && [ "${#value}" -lt "$min" ] && why="is shorter than ${min} characters"
    [ -z "$why" ] && return 0
    if [ "${ALLOW_INSECURE_DEFAULTS:-}" = "1" ]; then
        echo "entrypoint: WARNING - ${name} ${why} (allowed by ALLOW_INSECURE_DEFAULTS=1)"
        return 0
    fi
    {
        echo "entrypoint: FATAL - ${name} ${why}."
        echo "entrypoint: Generate one with:  openssl rand -base64 24 | tr -d '/+='"
        echo "entrypoint: or run ./scripts/init-env.sh, which fills in every secret for you."
    } >&2
    exit 1
}
weak_secret ARI_PASS "$ARI_PASS" 16

# These MUST be exported: envsubst reads the process environment, so a plain
# shell assignment would substitute an empty string and silently produce, for
# example, `bindport = ` in http.conf.
export LOCAL_NET="${LOCAL_NET:-10.0.0.0/8}"

# Per-trunk media/signalling addressing. Defaults keep the single-path
# behaviour; set the *_BIND_IP pair to different interfaces when the two trunks
# leave the box by different routes.
NS_BIND_IP="${NS_BIND_IP:-0.0.0.0}"
CARRIER_BIND_IP="${CARRIER_BIND_IP:-0.0.0.0}"
NS_EXTERNAL_IP="${NS_EXTERNAL_IP:-$EXTERNAL_IP}"
CARRIER_EXTERNAL_IP="${CARRIER_EXTERNAL_IP:-$EXTERNAL_IP}"
export NS_SIP_PORT="${NS_SIP_PORT:-5060}"
export CARRIER_SIP_PORT="${CARRIER_SIP_PORT:-5060}"
export ARI_PORT="${ARI_PORT:-8088}"
export EXTERNAL_IP NS_SIP_HOST CARRIER_SIP_HOST ARI_USER ARI_PASS
CARRIER_USER="${CARRIER_USER:-}"
CARRIER_PASS="${CARRIER_PASS:-}"
NS_AUTH_USER="${NS_AUTH_USER:-}"
NS_AUTH_PASS="${NS_AUTH_PASS:-}"
CARRIER_RESPONSE_TIMEOUT_MS="${CARRIER_RESPONSE_TIMEOUT_MS:-16000}"
CARRIER_QUALIFY_SECONDS="${CARRIER_QUALIFY_SECONDS:-10}"
CARRIER_FAILOVER_ON="${CARRIER_FAILOVER_ON:-CONGESTION,CHANUNAVAIL}"
MAX_CONCURRENT_CALLS="${MAX_CONCURRENT_CALLS:-0}"
MAX_CONCURRENT_PER_CALLER="${MAX_CONCURRENT_PER_CALLER:-0}"

ENVSUBST_VARS='${EXTERNAL_IP} ${LOCAL_NET} ${NS_SIP_HOST} ${NS_SIP_PORT} ${CARRIER_SIP_HOST} ${CARRIER_SIP_PORT} ${ARI_USER} ${ARI_PASS} ${ARI_PORT} ${NS_TRANSPORT} ${CARRIER_TRANSPORT} ${CARRIER_SIP_T1_MS} ${CARRIER_SIP_TIMER_B_MS}'

render() {
    # Substitute ONLY the named variables, never anything else in the file.
    envsubst "$ENVSUBST_VARS" < "/etc/asterisk/templates/$1" > "/etc/asterisk/$1"
}

# pjsip.conf already holds the generated transports, so append rather than clobber.
render_append() {
    envsubst "$ENVSUBST_VARS" < "/etc/asterisk/templates/$1" >> "/etc/asterisk/$1"
}

# Emit the SIP transports before the rest of pjsip.conf.
#
# external_media_address is a PER-TRANSPORT setting, so a box whose two trunks
# leave by different interfaces (say NetSapiens over a WireGuard tunnel and the
# carrier over the local WAN) must have one transport per path. Advertising a
# single address to both makes one leg tell the far end to send media to an
# address our RTP does not come from, and symmetric/strict RTP then drops it --
# the call connects and nobody hears anything.
emit_transport() {
    local name="$1" bind="$2" extip="$3"
    cat >> /etc/asterisk/pjsip.conf <<TRANSPORT
[${name}]
type = transport
protocol = udp
bind = ${bind}:5060
external_media_address = ${extip}
external_signaling_address = ${extip}
local_net = ${LOCAL_NET}

TRANSPORT
}

emit_transports() {
    : > /etc/asterisk/pjsip.conf
    if [ "$NS_BIND_IP" = "$CARRIER_BIND_IP" ]; then
        if [ "$NS_EXTERNAL_IP" != "$CARRIER_EXTERNAL_IP" ]; then
            echo "entrypoint: FATAL - NS_EXTERNAL_IP and CARRIER_EXTERNAL_IP differ but both" >&2
            echo "entrypoint: trunks bind ${NS_BIND_IP}. Give each trunk its own *_BIND_IP." >&2
            exit 1
        fi
        # One path: emit a single transport and point BOTH endpoints at it.
        # Two transports cannot share a bind address -- the second fails with
        # "Address already in use" and its endpoint is left with no transport.
        emit_transport transport-ns "$NS_BIND_IP" "$NS_EXTERNAL_IP"
        export NS_TRANSPORT=transport-ns CARRIER_TRANSPORT=transport-ns
        echo "entrypoint: single SIP transport on ${NS_BIND_IP}, advertising ${NS_EXTERNAL_IP}"
    else
        emit_transport transport-ns "$NS_BIND_IP" "$NS_EXTERNAL_IP"
        emit_transport transport-carrier "$CARRIER_BIND_IP" "$CARRIER_EXTERNAL_IP"
        export NS_TRANSPORT=transport-ns CARRIER_TRANSPORT=transport-carrier
        echo "entrypoint: split transports -- NetSapiens ${NS_BIND_IP} advertising ${NS_EXTERNAL_IP}, carrier ${CARRIER_BIND_IP} advertising ${CARRIER_EXTERNAL_IP}"
    fi
}

# Dialplan globals live in their own included file so extensions.conf itself
# never passes through envsubst -- it is full of ${EXTEN}-style variables that
# envsubst would substitute away. Written unconditionally: extensions.conf
# #includes it, and the concurrency tests compare against these values, so a
# missing file would leave the comparison with an empty left-hand side and a
# dialplan expression error on every call.
write_globals() {
    for v in MAX_CONCURRENT_CALLS MAX_CONCURRENT_PER_CALLER; do
        if ! [[ "${!v}" =~ ^[0-9]+$ ]]; then
            echo "entrypoint: FATAL - ${v} must be a non-negative integer, got '${!v}'" >&2
            exit 1
        fi
    done
    cat > /etc/asterisk/globals.conf <<GLOBALS
; Generated by entrypoint.sh from the environment -- edits here are overwritten
; on restart. Set MAX_CONCURRENT_CALLS / MAX_CONCURRENT_PER_CALLER in .env.
MAX_CONCURRENT_CALLS = ${MAX_CONCURRENT_CALLS}
MAX_CONCURRENT_PER_CALLER = ${MAX_CONCURRENT_PER_CALLER}
CARRIER_COUNT = ${#CARRIER_HOSTS[@]}
CARRIER_FAILOVER_ON = ${CARRIER_FAILOVER_LIST}
GLOBALS
    if [ "$MAX_CONCURRENT_CALLS" = "0" ] && [ "$MAX_CONCURRENT_PER_CALLER" = "0" ]; then
        echo "entrypoint: WARNING - no concurrency cap set. A compromised or spoofed"
        echo "entrypoint: source can place unlimited simultaneous calls on the carrier trunk."
    else
        echo "entrypoint: concurrency caps -- total ${MAX_CONCURRENT_CALLS}, per caller ${MAX_CONCURRENT_PER_CALLER} (0 = unlimited)"
    fi
}

# CARRIER_SIP_HOST is a comma-separated list. Each entry is one of:
#   203.0.113.10          a gateway, on CARRIER_SIP_PORT
#   203.0.113.11:5080     a gateway on its own port
#   203.0.113.0/24        a CIDR -- matched on inbound traffic only, since a
#                         range cannot be dialled
# Every gateway is both a dial target (tried in the order listed) and an
# inbound match; CIDRs are match-only.
CARRIER_HOSTS=(); CARRIER_PORTS=(); CARRIER_CIDRS=()
parse_carriers() {
    local entry host port
    local IFS=','
    for entry in $CARRIER_SIP_HOST; do
        entry="$(echo "$entry" | tr -d '[:space:]')"
        [ -z "$entry" ] && continue
        if [[ "$entry" == */* ]]; then
            CARRIER_CIDRS+=("$entry")
            continue
        fi
        host="${entry%%:*}"
        port="$CARRIER_SIP_PORT"
        [[ "$entry" == *:* ]] && port="${entry#*:}"
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            echo "entrypoint: FATAL - bad port in CARRIER_SIP_HOST entry '${entry}'" >&2
            exit 1
        fi
        CARRIER_HOSTS+=("$host"); CARRIER_PORTS+=("$port")
    done
    if [ "${#CARRIER_HOSTS[@]}" -eq 0 ]; then
        echo "entrypoint: FATAL - CARRIER_SIP_HOST has no dialable gateway (CIDRs cannot be dialled)" >&2
        exit 1
    fi
}
parse_carriers

if ! [[ "$CARRIER_QUALIFY_SECONDS" =~ ^[0-9]+$ ]]; then
    echo "entrypoint: FATAL - CARRIER_QUALIFY_SECONDS must be a non-negative integer" >&2; exit 1
fi
# Asterisk will not accept Timer B below 64 x Timer T1 ("Timer B setting is too
# low. Setting to 32000") -- so the only way to shorten how long an unresponsive
# gateway is waited on is to lower T1 and let B follow. T1 is also the first
# retransmit interval, so it should stay comfortably above the round-trip time to
# the carrier: 100ms is the floor here, and the 16s default gives T1=250ms.
if ! [[ "$CARRIER_RESPONSE_TIMEOUT_MS" =~ ^[0-9]+$ ]] \
        || [ "$CARRIER_RESPONSE_TIMEOUT_MS" -lt 6400 ] || [ "$CARRIER_RESPONSE_TIMEOUT_MS" -gt 32000 ]; then
    echo "entrypoint: FATAL - CARRIER_RESPONSE_TIMEOUT_MS must be an integer from 6400 to 32000" >&2; exit 1
fi
export CARRIER_SIP_T1_MS=$(( (CARRIER_RESPONSE_TIMEOUT_MS + 63) / 64 ))
export CARRIER_SIP_TIMER_B_MS=$(( CARRIER_SIP_T1_MS * 64 ))
# Only statuses that mean "this gateway failed" may trigger a retry. BUSY is
# allowed but is normally the CALLEE being busy, so retrying it just places the
# same call again; ANSWER and CANCEL must never be retried.
CARRIER_FAILOVER_LIST="${CARRIER_FAILOVER_ON//,/-}"
for st in ${CARRIER_FAILOVER_ON//,/ }; do
    case "$st" in
        BUSY|CONGESTION|CHANUNAVAIL|NOANSWER) ;;
        *) echo "entrypoint: FATAL - CARRIER_FAILOVER_ON: '${st}' is not one of BUSY, CONGESTION, CHANUNAVAIL, NOANSWER" >&2; exit 1 ;;
    esac
done

write_globals
emit_transports
render_append pjsip.conf
render ari.conf
render http.conf

# Emit ONE identify object per host rather than a single comma-separated match.
# Asterisk resolves hostnames at config load, and a single unresolvable entry
# makes the whole identify object fail to load -- with a combined match that
# takes every other host down with it, rejecting all inbound INVITEs. Split this
# way, a bad entry only costs that one host.
emit_identifies() {
    local prefix="$1" endpoint="$2" hosts="$3" n=0 host
    local IFS=','
    for host in $hosts; do
        host="$(echo "$host" | tr -d '[:space:]')"
        [ -z "$host" ] && continue
        n=$((n + 1))
        cat >> /etc/asterisk/pjsip.conf <<IDENT

[${prefix}-${n}]
type = identify
endpoint = ${endpoint}
match = ${host}
IDENT
    done
    echo "entrypoint: ${endpoint} will be identified by ${n} host(s)"
}

emit_identifies netsapiens-identify netsapiens "$NS_SIP_HOST"
# One endpoint, one AOR and one identify per gateway. The AOR is qualified with
# OPTIONS so a gateway that is down is skipped instantly instead of being dialled
# and waited on; CARRIER_QUALIFY_SECONDS=0 turns that off for carriers that do
# not answer OPTIONS (they would otherwise be marked unavailable forever and
# never used).
emit_carriers() {
    local i idx n=${#CARRIER_HOSTS[@]} j=0 cidr
    for ((i = 0; i < n; i++)); do
        idx=$((i + 1))
        cat >> /etc/asterisk/pjsip.conf <<CARRIER

[carrier-${idx}](carrier-base)
aors = carrier-aor-${idx}
from_domain = ${CARRIER_HOSTS[i]}

[carrier-aor-${idx}]
type = aor
contact = sip:${CARRIER_HOSTS[i]}:${CARRIER_PORTS[i]}
qualify_frequency = ${CARRIER_QUALIFY_SECONDS}
qualify_timeout = 3.0

[carrier-identify-${idx}]
type = identify
endpoint = carrier-${idx}
match = ${CARRIER_HOSTS[i]}
CARRIER
    done
    for cidr in "${CARRIER_CIDRS[@]}"; do
        j=$((j + 1))
        cat >> /etc/asterisk/pjsip.conf <<CIDR

[carrier-identify-cidr-${j}]
type = identify
endpoint = carrier-1
match = ${cidr}
CIDR
    done
    echo "entrypoint: carrier gateways (tried in this order): $(
        for ((i = 0; i < n; i++)); do printf '%s:%s ' "${CARRIER_HOSTS[i]}" "${CARRIER_PORTS[i]}"; done)"
    [ "${#CARRIER_CIDRS[@]}" -gt 0 ] && echo "entrypoint: also matching inbound from: ${CARRIER_CIDRS[*]}"
    echo "entrypoint: failover on ${CARRIER_FAILOVER_ON}; response timeout ${CARRIER_SIP_TIMER_B_MS}ms (T1 ${CARRIER_SIP_T1_MS}ms); qualify every ${CARRIER_QUALIFY_SECONDS}s (0 = off)"
    return 0
}
emit_carriers

# Require NetSapiens to prove itself with digest auth, in ADDITION to the IP
# identify above -- not instead of it. The identify still decides which endpoint
# an INVITE belongs to; the auth then decides whether it is allowed in.
#
# This is what closes off blind source-IP spoofing. Identify alone trusts a
# field the sender controls, so anyone who can forge a packet from a NetSapiens
# address can place calls on our carrier trunk and never needs to see a reply --
# with toll fraud the payoff is the number they dialled, not the audio. Digest
# auth makes the caller answer a challenge, and our 401 (with its nonce) is
# routed to the REAL address, which a blind spoofer never receives.
#
# The AOR exists only so NetSapiens can REGISTER if its trunk is configured to.
# Nothing is ever dialled towards these contacts -- [from-carrier] rejects every
# inbound call -- but a trunk set to register will retry forever against a box
# that has no AOR to bind to.
if [[ -n "$NS_AUTH_USER" && -n "$NS_AUTH_PASS" ]]; then
    weak_secret NS_AUTH_PASS "$NS_AUTH_PASS" 12
    cat >> /etc/asterisk/pjsip.conf <<PJSIP

[netsapiens-auth]
type = auth
auth_type = userpass
username = ${NS_AUTH_USER}
password = ${NS_AUTH_PASS}

[netsapiens-aor]
type = aor
; One contact per NetSapiens core, with headroom. remove_existing = no stops a
; registering core from evicting its peers, which share this one AOR.
max_contacts = 10
remove_existing = no
PJSIP
    sed -i 's/^;auth = netsapiens-auth$/auth = netsapiens-auth/' /etc/asterisk/pjsip.conf
    sed -i 's/^;aors = netsapiens-aor$/aors = netsapiens-aor/' /etc/asterisk/pjsip.conf
    echo "entrypoint: NetSapiens digest auth REQUIRED for user ${NS_AUTH_USER}"
else
    # Without this, NetSapiens is trusted on source IP alone -- a field the sender
    # controls. On a public address that lets anyone able to forge a packet from a
    # NetSapiens IP place calls on the carrier trunk, so it is refused by default.
    if [ "${ALLOW_INSECURE_DEFAULTS:-}" = "1" ]; then
        echo "entrypoint: WARNING - no NS_AUTH_USER/NS_AUTH_PASS set. NetSapiens is trusted"
        echo "entrypoint: on source IP alone, which a spoofed packet can forge."
    else
        {
            echo "entrypoint: FATAL - NS_AUTH_USER and NS_AUTH_PASS are not set."
            echo "entrypoint: The NetSapiens trunk would be trusted on source IP alone, which a"
            echo "entrypoint: spoofed packet can forge -- toll fraud needs nothing more. Set both"
            echo "entrypoint: (and enter the same pair on the NetSapiens trunk), or set"
            echo "entrypoint: ALLOW_INSECURE_DEFAULTS=1 if this really is a private link."
        } >&2
        exit 1
    fi
fi

# Carrier trunks are commonly IP-authenticated. Only wire up digest auth and a registration
# when credentials were actually supplied, otherwise leave the endpoint unauthenticated.
if [[ -n "$CARRIER_USER" && -n "$CARRIER_PASS" ]]; then
    cat >> /etc/asterisk/pjsip.conf <<PJSIP

[carrier-auth]
type = auth
auth_type = userpass
username = ${CARRIER_USER}
password = ${CARRIER_PASS}

PJSIP
    # One registration per gateway: a carrier that requires REGISTER for outbound
    # service needs it on every gateway we might fail over to, not just the first.
    for ((i = 0; i < ${#CARRIER_HOSTS[@]}; i++)); do
        cat >> /etc/asterisk/pjsip.conf <<REG

[carrier-reg-$((i + 1))]
type = registration
transport = ${CARRIER_TRANSPORT}
outbound_auth = carrier-auth
server_uri = sip:${CARRIER_HOSTS[i]}:${CARRIER_PORTS[i]}
client_uri = sip:${CARRIER_USER}@${CARRIER_HOSTS[i]}
retry_interval = 60
REG
    done
    # Attach the auth to the outbound endpoint declared in the template.
    sed -i 's/^;outbound_auth = carrier-auth$/outbound_auth = carrier-auth/' /etc/asterisk/pjsip.conf
    echo "entrypoint: carrier digest auth enabled for user ${CARRIER_USER}"
else
    echo "entrypoint: no CARRIER_USER/CARRIER_PASS set -- assuming IP-authenticated carrier trunk"
fi

exec "$@"

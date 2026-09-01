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

ENVSUBST_VARS='${EXTERNAL_IP} ${LOCAL_NET} ${NS_SIP_HOST} ${NS_SIP_PORT} ${CARRIER_SIP_HOST} ${CARRIER_SIP_PORT} ${ARI_USER} ${ARI_PASS} ${ARI_PORT} ${NS_TRANSPORT} ${CARRIER_TRANSPORT}'

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
emit_identifies carrier-identify carrier "$CARRIER_SIP_HOST"

# Carrier trunks are commonly IP-authenticated. Only wire up digest auth and a registration
# when credentials were actually supplied, otherwise leave the endpoint unauthenticated.
if [[ -n "$CARRIER_USER" && -n "$CARRIER_PASS" ]]; then
    cat >> /etc/asterisk/pjsip.conf <<PJSIP

[carrier-auth]
type = auth
auth_type = userpass
username = ${CARRIER_USER}
password = ${CARRIER_PASS}

[carrier-reg]
type = registration
transport = transport-udp
outbound_auth = carrier-auth
server_uri = sip:${CARRIER_SIP_HOST}:${CARRIER_SIP_PORT}
client_uri = sip:${CARRIER_USER}@${CARRIER_SIP_HOST}
retry_interval = 60
PJSIP
    # Attach the auth to the outbound endpoint declared in the template.
    sed -i 's/^;outbound_auth = carrier-auth$/outbound_auth = carrier-auth/' /etc/asterisk/pjsip.conf
    echo "entrypoint: carrier digest auth enabled for user ${CARRIER_USER}"
else
    echo "entrypoint: no CARRIER_USER/CARRIER_PASS set -- assuming IP-authenticated carrier trunk"
fi

exec "$@"

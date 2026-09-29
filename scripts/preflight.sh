#!/usr/bin/env bash
# Audit this deployment for the things that get a public SIP box abused.
#
#   ./scripts/preflight.sh          checks that need no privileges
#   sudo ./scripts/preflight.sh     ...plus the firewall and effective sshd config
#
# Prints PASS / WARN / FAIL per check and exits 1 if anything FAILed. A WARN is a
# judgement call for you; a FAIL is something that should not go live.
#
# It reads the deployment and changes nothing.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"
ASTERISK="${ASTERISK_CONTAINER:-ns-announce-asterisk}"
CONTROLLER="${CONTROLLER_CONTAINER:-ns-announce-controller}"
PASSES=0; WARNS=0; FAILS=0
IS_ROOT=0; [ "$(id -u)" -eq 0 ] && IS_ROOT=1

pass() { PASSES=$((PASSES + 1)); printf '  [PASS] %s\n' "$1"; }
warn() { WARNS=$((WARNS + 1)); printf '  [WARN] %s\n' "$1"; [ -n "${2:-}" ] && printf '         -> %s\n' "$2"; return 0; }
fail() { FAILS=$((FAILS + 1)); printf '  [FAIL] %s\n' "$1"; [ -n "${2:-}" ] && printf '         -> %s\n' "$2"; return 0; }
section() { printf '\n%s\n' "$1"; }

getenv() { [ -f "$ENV_FILE" ] && sed -n "s/^[[:space:]]*$1=//p" "$ENV_FILE" | tail -1 | tr -d '"'\''[:space:]'; }

# Same rules the entrypoint enforces at startup -- keep the two in step.
weak() {  # value min-length -> prints the reason if weak
    local v="$1" min="$2"
    case "${v,,}" in change-me*|changeme*|password*|admin*|secret*|asterisk*|123456*) echo "is a well-known placeholder"; return ;; esac
    [ "${#v}" -lt "$min" ] && echo "is shorter than $min characters"
}

# ------------------------------------------------------------------ configuration
section "Configuration ($ENV_FILE)"
if [ ! -f "$ENV_FILE" ]; then
    fail ".env not found" "run ./scripts/init-env.sh"
else
    mode="$(stat -c %a "$ENV_FILE")"; owner="$(stat -c %U "$ENV_FILE")"
    if [ "$mode" = 600 ] || [ "$mode" = 400 ]; then pass ".env is mode $mode (owner $owner)"
    else fail ".env is mode $mode -- it holds every secret" "chmod 600 $ENV_FILE"; fi

    for spec in "ARI_PASS:16" "NS_AUTH_PASS:12" "WEB_PASS:12"; do
        k="${spec%%:*}"; min="${spec##*:}"; v="$(getenv "$k")"
        if [ -z "$v" ]; then
            case "$k" in
                WEB_PASS) pass "WEB_PASS unset (operator UI stays on loopback, unauthenticated)" ;;
                *)        fail "$k is not set" "run ./scripts/init-env.sh" ;;
            esac
        elif why="$(weak "$v" "$min")" && [ -n "$why" ]; then fail "$k $why"
        else pass "$k is set and strong"; fi
    done

    [ -n "$(getenv NS_AUTH_USER)" ] && pass "NetSapiens digest auth username set" \
        || fail "NS_AUTH_USER is not set" "without digest auth NetSapiens is trusted on a spoofable source IP"

    if [ "$(getenv ALLOW_INSECURE_DEFAULTS)" = "1" ]; then
        fail "ALLOW_INSECURE_DEFAULTS=1 is set" "it turns the startup refusals into warnings; remove it outside a lab"
    else pass "ALLOW_INSECURE_DEFAULTS is not set"; fi

    ext="$(getenv EXTERNAL_IP)"
    if [ -z "$ext" ] || [ "$ext" = "203.0.113.10" ]; then fail "EXTERNAL_IP is unset or still the example value" "the address the carrier and NetSapiens will send media to"
    else pass "EXTERNAL_IP=$ext"; fi
    for k in NS_SIP_HOST CARRIER_SIP_HOST; do
        v="$(getenv $k)"
        case "$v" in ""|*example*) fail "$k is unset or still the example value" ;; *) pass "$k is set" ;; esac
    done
    n="$(getenv CARRIER_SIP_HOST | tr ',' '\n' | grep -vc '/' || true)"
    if [ "${n:-0}" -ge 2 ]; then pass "carrier failover: $n gateways configured"
    else warn "only one carrier gateway is configured" "add the carrier's failover IPs to CARRIER_SIP_HOST if they publish any"; fi

    tot="$(getenv MAX_CONCURRENT_CALLS)"; per="$(getenv MAX_CONCURRENT_PER_CALLER)"
    if [ "${tot:-0}" = 0 ] && [ "${per:-0}" = 0 ]; then fail "no concurrency cap is set" "unlimited calls is the toll-fraud exposure; set MAX_CONCURRENT_CALLS a little above your busiest hour"
    elif [ "${tot:-0}" = 0 ]; then warn "MAX_CONCURRENT_CALLS is unlimited (only the per-caller cap is set)"
    else pass "concurrency caps set (total ${tot}, per caller ${per:-0})"; fi

    wh="$(getenv WEB_HOST)"
    case "${wh:-127.0.0.1}" in
        127.0.0.1|::1|localhost) pass "operator UI is bound to loopback" ;;
        *) if [ -n "$(getenv WEB_PASS)" ]; then warn "operator UI is on ${wh} (authenticated)" "an SSH tunnel is still safer than exposing it"
           else fail "operator UI is on ${wh} with no WEB_PASS" "it can stop announcements on live calls"; fi ;;
    esac
fi

# ------------------------------------------------------------------ what is listening
section "Network exposure"
if command -v ss >/dev/null; then
    ssh_ports="$( { ss -H -tlnp 2>/dev/null | awk '/sshd/ {n=split($4,a,":"); print a[n]}'; echo 22; } | sort -un | tr '\n' ' ')"
    bad=0; odd=()
    while read -r proto local; do
        addr="${local%:*}"; port="${local##*:}"
        case "$addr" in 127.*|"[::1]"|::1|"127.0.0.53%lo"|"127.0.0.54") continue ;; esac
        case "$port" in 8088|5038) fail "port $port ($proto) is listening on $addr -- internal control interface" "it must stay on 127.0.0.1"; bad=1; continue ;; esac
        [ "$proto" = udp ] && { [ "$port" = 5060 ] || { [ "$port" -ge 10000 ] && [ "$port" -le 20000 ]; } || [ "$port" = 68 ] || [ "$port" = 123 ]; } && continue
        [ "$proto" = tcp ] && [[ " $ssh_ports " == *" $port "* ]] && continue
        odd+=("$proto/$port on $addr")
    done < <(ss -H -ltnu 2>/dev/null | awk '{print $1, $5}')
    [ "$bad" -eq 0 ] && pass "no internal interface (ARI, AMI) listens beyond loopback"
    if [ "${#odd[@]}" -eq 0 ]; then pass "nothing unexpected is listening"
    else warn "other listeners exist: ${odd[*]}" "fine if they are yours, but each is attack surface on a public address"; fi
else warn "ss not available, skipped the listener check"; fi

# ------------------------------------------------------------------ firewall
section "Firewall"
if ! command -v ufw >/dev/null; then fail "ufw is not installed" "apt install ufw, then ./scripts/firewall.sh --apply --enable"
elif [ "$IS_ROOT" -ne 1 ]; then warn "firewall not checked (needs root)" "re-run with sudo"
else
    st="$(ufw status verbose 2>/dev/null)"
    if grep -q '^Status: active' <<<"$st"; then pass "ufw is active"; else fail "ufw is INACTIVE" "sudo ./scripts/firewall.sh --apply --enable --ssh-from <your-ip>"; fi
    grep -q 'Default: deny (incoming)' <<<"$st" && pass "default policy denies incoming" || fail "default incoming policy is not deny"
    if grep -q 'ns-announce: block SIP' <<<"$st"; then pass "5060 is closed to everyone but the listed peers"
    else fail "the SIP deny rule is missing" "sudo ./scripts/firewall.sh --apply"; fi
    if grep -Eq '^(22|[0-9]+)/tcp +ALLOW +Anywhere' <<<"$st"; then warn "SSH is open to the whole internet" "restrict it: ./scripts/firewall.sh --apply --enable --ssh-from <your-ip>"; fi
fi

# ------------------------------------------------------------------ host
section "Host"
if [ "$IS_ROOT" -eq 1 ] && command -v sshd >/dev/null; then
    eff="$(sshd -T 2>/dev/null)"
    pw="$(awk '$1=="passwordauthentication"{print $2}' <<<"$eff")"; rl="$(awk '$1=="permitrootlogin"{print $2}' <<<"$eff")"
    [ "$pw" = no ] && pass "SSH password login is disabled" || fail "SSH password login is enabled" "set PasswordAuthentication no -- a public VM is guessed at within minutes"
    case "$rl" in no|prohibit-password|without-password) pass "SSH root login is not password-based ($rl)" ;; *) fail "SSH root login is allowed ($rl)" ;; esac
else warn "sshd configuration not checked (needs root)"; fi
if dpkg -s unattended-upgrades >/dev/null 2>&1 && systemctl is-enabled unattended-upgrades >/dev/null 2>&1; then pass "unattended security upgrades are on"
else warn "unattended-upgrades is not enabled" "apt install unattended-upgrades"; fi
if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes; then pass "clock is NTP-synchronised"
else warn "clock is not NTP-synchronised" "SIP digest nonces and your logs depend on it"; fi

# ------------------------------------------------------------------ containers
section "Containers"
if ! command -v docker >/dev/null; then warn "docker not available"
elif ! docker inspect "$ASTERISK" >/dev/null 2>&1; then warn "$ASTERISK is not running -- container checks skipped" "docker compose up -d"
else
    for c in "$ASTERISK" "$CONTROLLER"; do
        docker inspect "$c" >/dev/null 2>&1 || { warn "$c not found"; continue; }
        u="$(docker inspect -f '{{.Config.User}}' "$c")"
        [ -n "$u" ] && [ "$u" != root ] && [ "$u" != 0 ] && pass "$c runs as '$u', not root" || fail "$c runs as root"
        [ "$(docker inspect -f '{{.HostConfig.Privileged}}' "$c")" = false ] && pass "$c is not privileged" || fail "$c is privileged"
        docker inspect -f '{{.HostConfig.CapDrop}}' "$c" | grep -qi all && pass "$c drops all capabilities" || fail "$c keeps default capabilities"
        docker inspect -f '{{.HostConfig.SecurityOpt}}' "$c" | grep -q no-new-privileges && pass "$c: no-new-privileges" || warn "$c: no-new-privileges not set"
        [ "$(docker inspect -f '{{.HostConfig.LogConfig.Config}}' "$c")" != "map[]" ] && pass "$c has log rotation" || warn "$c has unbounded logs" "add a logging: block to docker-compose.yml"
    done
    [ "$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}}' "$CONTROLLER" 2>/dev/null)" = true ] && pass "$CONTROLLER has a read-only filesystem" || warn "$CONTROLLER filesystem is writable"

    ast() { docker exec "$ASTERISK" asterisk -rx "$1" 2>/dev/null; }
    ast "manager show settings" | grep -q 'Manager (AMI): *No' && pass "AMI is disabled" || warn "AMI is enabled" "nothing here uses it"
    ast "http show status" | grep -q 'Bound to 127.0.0.1' && pass "ARI is bound to 127.0.0.1" || fail "ARI is not bound to loopback"
    ast "pjsip show endpoint netsapiens" | grep -q 'InAuth' && pass "NetSapiens must authenticate (digest)" || fail "NetSapiens endpoint has no digest auth"
    ver="$(ast 'core show version' | awk '{print $2}')"; [ -n "$ver" ] && pass "Asterisk $ver" || warn "could not read the Asterisk version"
    up="$(ast 'pjsip show contacts' | grep -c 'carrier-aor.*Avail' || true)"
    tot="$(ast 'pjsip show contacts' | grep -c 'carrier-aor' || true)"
    [ "${tot:-0}" -gt 0 ] && { [ "$up" = "$tot" ] && pass "all $tot carrier gateways are reachable" || warn "$up of $tot carrier gateways are reachable"; }
fi

printf '\n%s\n' "----------------------------------------------------------------"
printf '%d passed, %d warnings, %d FAILED\n' "$PASSES" "$WARNS" "$FAILS"
[ "$FAILS" -eq 0 ]

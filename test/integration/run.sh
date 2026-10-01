#!/usr/bin/env bash
# Spins up an isolated Asterisk + fake carrier and runs the SIP integration
# suite against them. Touches nothing on the host but Docker.
#
#   ./test/integration/run.sh              # build the image, then test
#   ./test/integration/run.sh nsa:22       # test an image that already exists
#
# The three-address layout matters. NetSapiens and the carrier must be DIFFERENT
# source addresses or their two identify objects both match, and the endpoint an
# INVITE lands on becomes a coin flip:
#   172.29.0.1  the Docker gateway -- what host traffic looks like, so it stands
#               in for NetSapiens
#   172.29.0.2  Asterisk
#   172.29.0.3  the fake carrier
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
IMAGE="${1:-}"
NET=itest-net
SUBNET=172.29.0.0/16

# Created lazily in phase 2: cleanup() also runs once mid-script to clear stale
# containers, and would delete this directory before it is ever used.
BADCFG=""
SOUNDS=""
cleanup() {
    docker rm -f itest-asterisk itest-carrier itest-carrier2 itest-ctl >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
    [ -n "$BADCFG" ] && rm -rf "$BADCFG"
    [ -n "$SOUNDS" ] && rm -rf "$SOUNDS"
    return 0
}
# ITEST_KEEP=1 leaves the containers up afterwards, for poking at a failure.
# cleanup() itself is also called once mid-script to clear stale containers, so
# the exit trap is a separate function.
teardown() { [ -n "${ITEST_KEEP:-}" ] && { echo "ITEST_KEEP set: leaving containers up"; return 0; }; cleanup; }
trap teardown EXIT

if [ -z "$IMAGE" ]; then
    IMAGE=ns-announce-asterisk:itest
    echo "building $IMAGE ..."
    docker build -q -t "$IMAGE" "$ROOT/asterisk" >/dev/null
fi

cleanup
docker network create --subnet "$SUBNET" "$NET" >/dev/null

start_carrier() {  # name ip [extra docker args, e.g. -e ANSWER=1]
    local name="$1" ip="$2"; shift 2
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker run -d --name "$name" --network "$NET" --ip "$ip" "$@" \
        -v "$HERE/fake-carrier.js:/app/fake-carrier.js:ro" \
        node:20-bookworm-slim node /app/fake-carrier.js >/dev/null
}
# Two gateways, as a carrier with a failover IP would publish. The first is the
# one every ordinary test dials; the second only matters to the failover phase.
start_carrier itest-carrier 172.29.0.3
start_carrier itest-carrier2 172.29.0.4

# The announcement under test is the prompt that ships in the repo, installed into a
# throwaway directory and mounted over the image's sounds. Until now the suite used
# whatever sat in the developer's own (gitignored) asterisk/sounds/ -- which does not
# exist on a fresh clone, so phase 2 could not pass there, and which tested a private
# recording rather than the one every deployment gets.
command -v sox >/dev/null || { echo "error: sox is required to install the bundled prompt (apt install sox)" >&2; exit 1; }
SOUNDS="$(mktemp -d)"
SOUNDS_DIR="$SOUNDS" "$ROOT/scripts/prompt.sh" install --default >/dev/null
chmod 755 "$SOUNDS"; chmod 644 "$SOUNDS"/*   # Asterisk runs as an unprivileged user

docker run -d --name itest-asterisk --network "$NET" --ip 172.29.0.2 \
    -p 15060:5060/udp \
    -v "$SOUNDS:/var/lib/asterisk/sounds/custom:ro" \
    --cap-drop ALL --security-opt no-new-privileges \
    -e EXTERNAL_IP=172.29.0.2 -e LOCAL_NET=172.29.0.0/16 \
    -e NS_SIP_HOST=172.29.0.1 -e CARRIER_SIP_HOST=172.29.0.3,172.29.0.4 \
    -e CARRIER_RESPONSE_TIMEOUT_MS=6400 -e CARRIER_QUALIFY_SECONDS=5 \
    -e ARI_USER=itest -e ARI_PASS=itest \
    -e NS_AUTH_USER=nsuser -e NS_AUTH_PASS=testpass \
    -e ALLOW_INSECURE_DEFAULTS=1 \
    -e MAX_CONCURRENT_CALLS=2 -e MAX_CONCURRENT_PER_CALLER=1 \
    "$IMAGE" >/dev/null

echo -n "waiting for asterisk "
for _ in $(seq 1 60); do
    if docker exec itest-asterisk asterisk -rx "core waitfullybooted" >/dev/null 2>&1; then
        echo "ready"; break
    fi
    echo -n .; sleep 1
done

# The carrier endpoint has to be qualified Available before Asterisk will build
# an outbound channel to it; without this the concurrency tests would all fail
# with "no route" for reasons that have nothing to do with the caps.
for g in carrier-1 carrier-2; do docker exec itest-asterisk asterisk -rx "pjsip qualify $g" >/dev/null 2>&1 || true; done
sleep 2

echo
# grep -c exits 1 when the count is zero, and with pipefail that aborts the whole
# run -- a perfectly clean startup would kill the test suite before it began.
warnings=$(docker logs itest-asterisk 2>&1 | sed 's/\x1b\[[0-9;]*m//g' \
    | grep -cE "WARNING|ERROR" || true)
echo "startup warnings from asterisk: ${warnings}"

rc=0
( cd "$HERE" && python3 suite.py ) || rc=$?

# ---------------------------------------------------------------------------
# Phase 2: the announcement path.
#
# Needs the opposite carrier behaviour from phase 1 -- a snoop has nothing to
# whisper into until the call is up -- so the carrier is restarted answering,
# and the controller is brought in. Phase 1 runs with NO controller, which is
# also what exercises the STASISSTATUS=FAILED fallback: every call there
# completed with Stasis unavailable.
# ---------------------------------------------------------------------------
echo
echo "--- phase 2: restarting carrier in answering mode ---"
start_carrier itest-carrier 172.29.0.3 -e ANSWER=1
sleep 2
for g in carrier-1 carrier-2; do docker exec itest-asterisk asterisk -rx "pjsip qualify $g" >/dev/null 2>&1 || true; done

CONTROLLER_IMAGE="${CONTROLLER_IMAGE:-ns-announce-controller:itest}"
if ! docker image inspect "$CONTROLLER_IMAGE" >/dev/null 2>&1; then
    echo "building $CONTROLLER_IMAGE ..."
    docker build -q -t "$CONTROLLER_IMAGE" "$ROOT/controller" >/dev/null
fi

# The negative control needs a config whose prompt does not exist. Built from
# the real rules.yaml so it stays in step with it.
BADCFG="$(mktemp -d)"
sed 's|^\(\s*\)media:.*|\1media: sound:custom/THIS-FILE-DOES-NOT-EXIST|' \
    "$ROOT/config/rules.yaml" > "$BADCFG/rules.yaml"

( cd "$HERE" && ITEST_CONFIG_DIR="$ROOT/config" ITEST_BAD_CONFIG_DIR="$BADCFG" \
    ITEST_CONTROLLER_IMAGE="$CONTROLLER_IMAGE" python3 announce.py ) || rc=$?

# ---------------------------------------------------------------------------
# Phase 3: carrier failover.
#
# Runs with no controller, so it also exercises the Stasis-unavailable fallback
# again. The carriers are recreated in different states by failover.py itself.
# ---------------------------------------------------------------------------
echo
echo "--- phase 3: carrier failover ---"
docker rm -f itest-ctl >/dev/null 2>&1 || true
( cd "$HERE" && python3 failover.py ) || rc=$?

if [ $rc -ne 0 ]; then
    echo; echo "--- asterisk log (last 30) ---"
    docker logs itest-asterisk 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tail -30
    echo; echo "--- controller log (last 20) ---"
    docker logs itest-ctl 2>&1 | tail -20 || true
fi
exit $rc

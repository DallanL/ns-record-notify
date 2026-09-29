#!/usr/bin/env python3
"""Carrier failover: several gateways, tried in order, retried only when a
gateway itself fails.

Runs against two fake carriers (itest-carrier, itest-carrier2) whose behaviour
is changed between scenarios by recreating them. What each gateway was ASKED to
dial is read from its own log, because the caller-side response cannot say
whether a call went to the right place -- or to two places at once.
"""
import json
import os
import re
import subprocess
import sys
import time

from checks import check, logs, summary
from sipdrive import Caller

ASTERISK = ('127.0.0.1', 15060)
HOST_IP = '172.29.0.1'
NS_USER, NS_PASS = 'nsuser', 'testpass'
NET = 'itest-net'
C1 = ('itest-carrier', '172.29.0.3')
C2 = ('itest-carrier2', '172.29.0.4')
HERE = os.path.dirname(os.path.abspath(__file__))
# run.sh starts Asterisk with these, so the timings below are short enough to test.
RESPONSE_TIMEOUT_S = 6.4   # 6400ms -- the shortest Asterisk allows (T1=100ms x 64)
QUALIFY_S = 5


def carrier(spec, mode=None):
    """(Re)create a fake carrier. mode: None (rings), 'down', or an env var such
    as 'REJECT=503'. Recreating also clears its log, so each scenario counts only
    its own INVITEs."""
    name, ip = spec
    subprocess.run(['docker', 'rm', '-f', name], capture_output=True)
    if mode == 'down':
        return
    cmd = ['docker', 'run', '-d', '--name', name, '--network', NET, '--ip', ip]
    if mode:
        cmd += ['-e', mode]
    cmd += ['-v', f'{HERE}/fake-carrier.js:/app/fake-carrier.js:ro',
            'node:20-bookworm-slim', 'node', '/app/fake-carrier.js']
    subprocess.run(cmd, capture_output=True, check=True)


def invites(spec):
    """Request-URIs this carrier was asked to dial."""
    rows = []
    for line in logs(spec[0]).splitlines():
        line = line.strip()
        if line.startswith('{') and '"uri"' in line:
            rows.append(json.loads(line)['uri'])
    return rows


def contact_states():
    out = subprocess.run(['docker', 'exec', 'itest-asterisk', 'asterisk', '-rx', 'pjsip show contacts'],
                         capture_output=True, text=True).stdout
    return {int(m.group(1)): m.group(2)
            for m in re.finditer(r'carrier-aor-(\d)/\S+\s+\S+\s+(\w+)', out)}


def wait_for(state1, state2, timeout=40):
    """Block until qualification reports the gateways in the wanted state.
    Failover scenarios are meaningless until Asterisk agrees about who is up."""
    want = {1: state1, 2: state2}
    deadline = time.time() + timeout
    while time.time() < deadline:
        got = contact_states()
        if all(got.get(k, '').startswith(v) for k, v in want.items()):
            return True
        time.sleep(1)
    return False


def live_channels():
    out = subprocess.run(['docker', 'exec', 'itest-asterisk', 'asterisk', '-rx', 'core show channels count'],
                         capture_output=True, text=True).stdout
    m = re.search(r'(\d+) active channel', out)
    return int(m.group(1)) if m else -1


def count_in_log(needle):
    return logs('itest-asterisk').count(needle)


def attempt(caller_id, dest):
    c = Caller(ASTERISK, HOST_IP, caller_id)
    r = c.authenticated_invite(dest, NS_USER, NS_PASS, timeout=RESPONSE_TIMEOUT_S * 4 + 8, stop_on_ringing=True)
    c.hangup_all()
    time.sleep(2)   # let Asterisk tear the call down before the next scenario counts channels
    return r['status'], r['elapsed']


def main():
    print('\n--- carrier failover (2 gateways, response timeout '
          f'{RESPONSE_TIMEOUT_S}s, qualify {QUALIFY_S}s) ---')

    # This phase is worthless unless it starts on an empty box. The concurrency
    # cap answers with the same fast 503 a failed gateway would, so a call left up
    # by an earlier phase makes "the calling PBX is told 503" pass for the WRONG
    # reason. An earlier version of this file did exactly that.
    check('starts with no calls left over from earlier phases', str(live_channels()), '0')
    rejected_before = count_in_log('REJECTED')

    carrier(C1); carrier(C2)
    check('both gateways are qualified reachable', str(wait_for('Avail', 'Avail')), 'True')

    print('\n  [1] healthy: the FIRST gateway takes the call and the second is left alone')
    status, _ = attempt('3001', '15552220001')
    check('call is offered', status, '180')
    check('gateway 1 was asked to dial it', str(len(invites(C1))), '1')
    check('gateway 2 was NOT asked -- no forking', str(len(invites(C2))), '0',
          detail='(a forked call would ring the destination twice)')

    print('\n  [2] gateway 1 is overloaded (503) -> fail over to gateway 2')
    carrier(C1, 'REJECT=503'); carrier(C2)
    wait_for('Avail', 'Avail')
    status, _ = attempt('3002', '15552220002')
    check('call still gets through', status, '180')
    check('gateway 1 was tried first', str(len(invites(C1))), '1')
    check('gateway 2 then took it', str(len(invites(C2))), '1')

    print('\n  [3] the CALLEE is busy (486) -> the call ENDS, no failover')
    carrier(C1, 'REJECT=486'); carrier(C2)
    wait_for('Avail', 'Avail')
    status, _ = attempt('3003', '15552220003')
    check('caller is told the destination is busy', status, '486')
    check('gateway 2 was NOT tried (would ring the same person again)', str(len(invites(C2))), '0')

    print('\n  [4] gateway 1 just died, qualification has not noticed yet')
    carrier(C1); carrier(C2)
    wait_for('Avail', 'Avail')
    carrier(C1, 'down')
    status, took = attempt('3004', '15552220004')
    check('call is rescued by gateway 2', status, '180')
    check(f'waited out the dead gateway (~{RESPONSE_TIMEOUT_S}s), then moved on -- not 32s',
          f'{took:.1f}s', lambda g: RESPONSE_TIMEOUT_S - 1.5 < took < RESPONSE_TIMEOUT_S + 4,
          detail='(too fast would mean it never actually waited)')
    check('gateway 2 took it', str(len(invites(C2))), '1')

    print('\n  [5] gateway 1 is down and qualification has marked it')
    check('gateway 1 is reported unavailable', str(wait_for('Unavail', 'Avail')), 'True')
    carrier(C2)   # fresh log
    wait_for('Unavail', 'Avail')
    status, took = attempt('3005', '15552220005')
    check('call goes straight to gateway 2', status, '180')
    check('...with no wait at all for the dead one', f'{took:.1f}s', lambda g: took < 2.5)

    print('\n  [6] emergency calls fail over too')
    carrier(C1, 'REJECT=503'); carrier(C2)
    wait_for('Avail', 'Avail')
    attempt('3006', '911')
    check('gateway 2 was asked for 911, not a dialplan label',
          str(invites(C2)[-1:] or ['none']), 'sip:911@')

    print('\n  [7] EVERY gateway is down')
    carrier(C1, 'down'); carrier(C2, 'down')
    check('both are reported unavailable', str(wait_for('Unavail', 'Unavail')), 'True')
    status, took = attempt('3007', '15552220007')
    check('the calling PBX is told 503 so IT can fail over', status, '503',
          detail='(a 404 here would read as a permanent failure)')
    check('and quickly', f'{took:.1f}s', lambda g: took < 5)
    check('it was the failover giving up, not something else',
          str(count_in_log('ALL 2 CARRIER GATEWAYS FAILED') >= 1), 'True')

    print('\n  [8] gateway 1 comes back -> it is preferred again')
    carrier(C1); carrier(C2)
    check('both gateways recover', str(wait_for('Avail', 'Avail')), 'True')
    status, _ = attempt('3008', '15552220008')
    check('call is offered', status, '180')
    check('gateway 1 is used again', str(len(invites(C1))), '1')
    check('gateway 2 is left alone', str(len(invites(C2))), '0')

    check('no scenario was turned away by the concurrency cap',
          str(count_in_log('REJECTED') - rejected_before), '0',
          detail='(a cap rejection looks like a failover result)')
    return summary('carrier failover')


if __name__ == '__main__':
    sys.exit(main())

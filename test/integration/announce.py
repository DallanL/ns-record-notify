#!/usr/bin/env python3
"""Announcement path: ARI snoop, whisper injection, and the repeat timer.

Split from suite.py because it needs the opposite carrier behaviour. The
concurrency tests need calls pinned at 180 Ringing to stay in their groups; a
snoop has nothing to whisper into until the call is actually up, so this half
runs against a carrier started with ANSWER=1.

The last section is a negative control, and it is the point of the whole file.
PlaybackFinished fires whether playback succeeded or failed, so "no error
appeared" proves nothing on its own -- a passing announcement check is only
meaningful once we have shown that a broken one would be caught.
"""
import json
import os
import subprocess
import sys
import time

from checks import check, absent, logs, summary
from sipdrive import Caller, RtpEndpoint, sdp_media_address

ASTERISK = ('127.0.0.1', 15060)
HOST_IP = '172.29.0.1'
NS_USER, NS_PASS = 'nsuser', 'testpass'
CONFIG_DIR = os.environ['ITEST_CONFIG_DIR']
BAD_CONFIG_DIR = os.environ['ITEST_BAD_CONFIG_DIR']


def start_controller(config_dir):
    subprocess.run(['docker', 'rm', '-f', 'itest-ctl'], capture_output=True)
    subprocess.run([
        'docker', 'run', '-d', '--name', 'itest-ctl',
        '--network', 'container:itest-asterisk',
        '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges',
        '-e', 'ARI_URL=http://127.0.0.1:8088',
        '-e', 'ARI_USER=itest', '-e', 'ARI_PASS=itest',
        '-e', 'RULES_PATH=/config/rules.yaml',
        '-e', 'WEB_HOST=127.0.0.1', '-e', 'WEB_PORT=8099',
        '-e', 'ANNOUNCE_INITIAL_DELAY_SECONDS=2',
        '-e', 'ANNOUNCE_INTERVAL_SECONDS=4',
        '-v', f'{config_dir}:/config:ro',
        os.environ.get('ITEST_CONTROLLER_IMAGE', 'ns-announce-controller:itest'),
    ], capture_output=True, check=True)
    for _ in range(30):
        if 'ARI websocket connected' in logs('itest-ctl'):
            return True
        time.sleep(1)
    return False


def place_call(caller_id, dest, settle, media=False):
    """Place a call. With media=True, also run a real RTP endpoint on the
    originating side, so what that party HEARS can be measured."""
    c = Caller(ASTERISK, HOST_IP, caller_id)
    resp = c.authenticated_invite(dest, NS_USER, NS_PASS)
    endpoint = None
    if media and resp['status'].endswith('200 OK'):
        remote = sdp_media_address(resp['raw'])
        if remote:
            endpoint = RtpEndpoint(40000)
            endpoint.start(remote)
    time.sleep(settle)
    return c, resp['status'], endpoint


def carrier_heard_since(t0_ms):
    """Loudest energy the fake carrier -- the TERMINATING party -- received."""
    peak = 0.0
    for line in logs('itest-carrier').splitlines():
        line = line.strip()
        if line.startswith('{') and '"heard"' in line:
            row = json.loads(line)
            if row['t'] >= t0_ms:
                peak = max(peak, row['rms'])
    return peak


def main():
    print('\n--- ARI announcement path ---')
    check('controller reaches ARI on the new build',
          'connected' if start_controller(CONFIG_DIR) else 'NO CONNECTION', 'connected')

    t0 = time.time()
    _c, status, ep = place_call('2001', '15551119999', settle=11, media=True)
    check('call is answered by the carrier', status, '200 OK')
    ctl = logs('itest-ctl')
    check('controller classified the call', ctl, 'outbound call classified')
    check('snoop attached and announcement started', ctl, 'announcement started')

    ast = logs('itest-asterisk')
    check('Asterisk opened the prompt file', ast, "Playing 'custom/recording-notice")
    plays = ast.count("Playing 'custom/recording-notice")
    check('prompt repeated on the interval (>=2 plays in 11s at 4s)',
          f'{plays} plays', lambda g: plays >= 2)
    absent('no playback failure reported', ctl, 'playback FAILED')

    # The checks above only prove Asterisk OPENED the file. They cannot tell
    # whether either party heard it, and this is the one that matters: the
    # announcement has to reach BOTH sides of the call, not just the caller.
    caller_peak = ep.loudest_since(t0) if ep else 0.0
    callee_peak = carrier_heard_since(int(t0 * 1000))
    check('ORIGINATING side hears the announcement', f'peak {caller_peak:.3f}',
          lambda g: caller_peak > 0.02, detail='(want > 0.02)')
    check('TERMINATING side hears the announcement', f'peak {callee_peak:.3f}',
          lambda g: callee_peak > 0.02, detail='(want > 0.02)')
    if ep:
        ep.stop()

    # Hang up before the negative control, or its call is the third concurrent
    # one and gets refused by the cap instead of reaching a playback at all.
    _c.hangup_all()
    time.sleep(3)

    print('\n--- negative control: is a broken prompt actually detected? ---')
    check('controller restarts with a nonexistent prompt',
          'connected' if start_controller(BAD_CONFIG_DIR) else 'NO CONNECTION', 'connected')
    _c2, _s, _ep = place_call('2002', '15551118888', settle=9)
    _c2.hangup_all()
    bad = logs('itest-ctl')
    check('a missing prompt IS reported as a failure', bad, 'playback FAILED',
          detail='(without this, the pass above would be meaningless)')

    return summary('announcement')


if __name__ == '__main__':
    sys.exit(main())

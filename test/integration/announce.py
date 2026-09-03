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
import os
import subprocess
import sys
import time

from checks import check, absent, logs, summary
from sipdrive import Caller

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


def place_call(caller_id, dest, settle):
    c = Caller(ASTERISK, HOST_IP, caller_id)
    status = c.authenticated_invite(dest, NS_USER, NS_PASS)['status']
    time.sleep(settle)
    return c, status


def main():
    print('\n--- ARI announcement path ---')
    check('controller reaches ARI on the new build',
          'connected' if start_controller(CONFIG_DIR) else 'NO CONNECTION', 'connected')

    _c, status = place_call('2001', '15551119999', settle=11)
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

    # Hang up before the negative control, or its call is the third concurrent
    # one and gets refused by the cap instead of reaching a playback at all.
    _c.hangup_all()
    time.sleep(3)

    print('\n--- negative control: is a broken prompt actually detected? ---')
    check('controller restarts with a nonexistent prompt',
          'connected' if start_controller(BAD_CONFIG_DIR) else 'NO CONNECTION', 'connected')
    _c2, _s = place_call('2002', '15551118888', settle=9)
    bad = logs('itest-ctl')
    check('a missing prompt IS reported as a failure', bad, 'playback FAILED',
          detail='(without this, the pass above would be meaningless)')

    return summary('announcement')


if __name__ == '__main__':
    sys.exit(main())

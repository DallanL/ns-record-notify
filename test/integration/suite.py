#!/usr/bin/env python3
"""Integration suite: drives a running Asterisk with raw SIP and checks the
security properties we rely on.

Every check here exists because something went wrong once. In particular the
emergency check asserts what the CARRIER was asked to dial, not the response the
caller got -- a Goto that clobbered ${EXTEN} once sent 911 to "sip:emergency@"
while still returning a perfectly healthy 180 Ringing to the caller.
"""
import json
import time
import sys

from checks import check, logs, summary
from sipdrive import Caller

ASTERISK = ('127.0.0.1', 15060)
HOST_IP = '172.29.0.1'
NS_USER, NS_PASS = 'nsuser', 'testpass'

def carrier_invites():
    out = logs('itest-carrier')
    rows = []
    for line in out.splitlines():
        line = line.strip()
        if line.startswith('{') and '"uri"' in line:
            rows.append(json.loads(line))
    return rows


def main():
    print('\n--- trunk authentication ---')
    good = Caller(ASTERISK, HOST_IP, '2001')
    check('unauthenticated INVITE is challenged', good.invite('15551110000')['status'], '401')
    bad = good.invite('15551110000', auth='Digest username="nsuser", realm="x", nonce="y", '
                                          'uri="sip:15551110000@127.0.0.1", response="0"')
    check('wrong password is rejected', bad['status'], '401')
    check('correct password gets through',
          good.authenticated_invite('15551110001', NS_USER, NS_PASS)['status'], '180 Ringing')

    print('\n--- concurrency caps (MAX_CONCURRENT_CALLS=2, MAX_CONCURRENT_PER_CALLER=1) ---')
    check('2nd call from same caller hits per-caller cap',
          good.authenticated_invite('15551110002', NS_USER, NS_PASS)['status'], '503')
    second = Caller(ASTERISK, HOST_IP, '2002')
    check('different caller is allowed (total now 2)',
          second.authenticated_invite('15551110003', NS_USER, NS_PASS)['status'], '180 Ringing')
    third = Caller(ASTERISK, HOST_IP, '2003')
    check('3rd concurrent call hits total cap',
          third.authenticated_invite('15551110004', NS_USER, NS_PASS)['status'], '503')

    print('\n--- emergency bypass (while fully capped) ---')
    check('911 is not blocked by the caps',
          third.authenticated_invite('911', NS_USER, NS_PASS)['status'], '180 Ringing')
    dialled = [r['uri'] for r in carrier_invites()]
    check('carrier was asked to dial 911, not a dialplan label',
          str(dialled[-1] if dialled else 'none'), 'sip:911@',
          detail='(the response alone cannot catch this)')

    # Clear the board. The identity checks need a call that actually reaches the
    # carrier, and everything above deliberately left the box at its cap.
    print('\n--- releasing capped calls ---')
    for c in (good, second, third):
        c.hangup_all()
    time.sleep(2)

    print('\n--- identity header relay ---')
    ident = 'eyJhbGciOiJFUzI1NiJ9.TEST;info=<https://x/c.pem>;alg=ES256;ppt=shaken'
    fourth = Caller(ASTERISK, HOST_IP, '2004')
    fourth.authenticated_invite('15551110005', NS_USER, NS_PASS, extra_headers=(
        f'Identity: {ident}',
        'P-Asserted-Identity: <sip:+15551110005@ns.example>',
        'Diversion: <sip:+15550009999@ns.example>;reason=unconditional',
    ))
    fourth.hangup_all()   # a call left up here holds a concurrency slot for every later phase
    rows = [r for r in carrier_invites() if '15551110005' in r['uri']]
    got = rows[-1] if rows else {}
    check('Identity survives the B2BUA hop byte-identical', got.get('identity', ''), ident)
    check('P-Asserted-Identity is relayed', got.get('pai', ''), '+15551110005')
    check('Diversion is relayed', got.get('diversion', ''), '+15550009999')

    return summary('signalling')


if __name__ == '__main__':
    sys.exit(main())

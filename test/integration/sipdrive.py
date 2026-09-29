"""Raw SIP driver for the integration suite.

Deliberately not a SIP library: the point is to send exactly what we want,
including unauthenticated and malformed requests that a well-behaved stack
would refuse to build.
"""
import hashlib
import math
import re
import socket
import threading
import time
import uuid

_PROVISIONAL = re.compile(r'^SIP/2\.0 1')


def _is_provisional(line):
    return bool(_PROVISIONAL.match(line))


class Caller:
    """One SIP endpoint.

    Sockets are kept open for the life of the object so that established calls
    stay up and keep occupying the concurrency groups under test -- closing them
    would let the calls tear down and quietly invalidate every later assertion.
    """

    def __init__(self, target, host_ip, caller_id='2001'):
        self.target = target
        self.host_ip = host_ip
        self.caller_id = caller_id
        self._sockets = []
        self._dialogs = []

    def _new_dialog(self):
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(3)
        s.bind(('0.0.0.0', 0))
        self._sockets.append(s)
        d = {'sock': s, 'call_id': uuid.uuid4().hex[:12], 'tag': uuid.uuid4().hex[:8], 'cseq': 0}
        self._dialogs.append(d)
        return d

    def invite(self, dest, auth=None, extra_headers=(), dialog=None, timeout=3, stop_on_ringing=False):
        """Send one INVITE. Returns status, the raw messages, and the dialog so a
        follow-up INVITE can reuse the same Call-ID (needed for digest retries)."""
        d = dialog or self._new_dialog()
        d['cseq'] += 1
        s = d['sock']
        lport = s.getsockname()[1]
        uri = f'sip:{dest}@{self.target[0]}'
        # A CANCEL has to carry the SAME branch and CSeq number as the INVITE it
        # cancels, so both are kept on the dialog.
        d['branch'] = f'z9hG4bK{uuid.uuid4().hex}'
        d['uri'] = uri
        body = (f'v=0\r\no=- 1 1 IN IP4 {self.host_ip}\r\ns=-\r\nc=IN IP4 {self.host_ip}\r\n'
                f't=0 0\r\nm=audio 40000 RTP/AVP 0\r\na=rtpmap:0 PCMU/8000\r\n')
        lines = [
            f'INVITE {uri} SIP/2.0',
            f'Via: SIP/2.0/UDP {self.host_ip}:{lport};branch={d["branch"]}',
            f'From: <sip:{self.caller_id}@{self.host_ip}>;tag={d["tag"]}',
            f'To: <{uri}>',
            f'Call-ID: {d["call_id"]}@{self.host_ip}',
            f'CSeq: {d["cseq"]} INVITE',
            f'Contact: <sip:{self.caller_id}@{self.host_ip}:{lport}>',
            'Max-Forwards: 70',
        ]
        lines += list(extra_headers)
        if auth:
            lines.append(f'Authorization: {auth}')
        lines += ['Content-Type: application/sdp', f'Content-Length: {len(body)}', '', body]
        s.sendto('\r\n'.join(lines).encode(), self.target)

        s.settimeout(timeout)
        began = time.time()
        raw, status_lines, deadline = [], [], began + timeout
        while time.time() < deadline:
            try:
                msg = s.recv(4096).decode(errors='replace')
            except socket.timeout:
                break
            raw.append(msg)
            first = msg.split('\r\n')[0]
            if first.startswith('SIP/2.0 2'):
                # A 2xx completes the dialog: remember the remote tag and target
                # so the call can be torn down later, and ACK it. Without the ACK
                # Asterisk retransmits the 200 and eventually tears the call down
                # on its own, which silently changes concurrency mid-suite.
                d['to_tag'] = _param(msg, 'To', 'tag')
                d['remote_target'] = _contact_uri(msg) or d['uri']
                self._ack(d)
            if first not in status_lines:
                status_lines.append(first)
                # Stop at the first non-provisional response; 100/180 are just
                # progress and more may follow.
                if not _is_provisional(first):
                    break
                # 180/183 mean the call is being offered somewhere, which is all a
                # failover test needs to know -- and waiting out the full timeout
                # on a call that rings forever would swamp the timing it measures.
                if stop_on_ringing and (first.startswith('SIP/2.0 180') or first.startswith('SIP/2.0 183')):
                    break
        final = [x for x in status_lines if not _is_provisional(x)]
        return {
            'status': final[-1] if final else (status_lines[-1] if status_lines else 'NO RESPONSE'),
            'raw': raw,
            'dialog': d,
            'uri': uri,
            'elapsed': time.time() - began,
        }

    def authenticated_invite(self, dest, user, password, extra_headers=(), **kw):
        """INVITE, absorb the 401, answer the challenge on the same dialog."""
        first = self.invite(dest, extra_headers=extra_headers)
        challenge = challenge_of(first['raw'])
        if not challenge:
            return first
        auth = digest_for(challenge, user, password, first['uri'])
        return self.invite(dest, auth=auth, extra_headers=extra_headers, dialog=first['dialog'], **kw)

    def _ack(self, d):
        s = d['sock']
        lport = s.getsockname()[1]
        msg = '\r\n'.join([
            f'ACK {d["remote_target"]} SIP/2.0',
            f'Via: SIP/2.0/UDP {self.host_ip}:{lport};branch=z9hG4bK{uuid.uuid4().hex}',
            f'From: <sip:{self.caller_id}@{self.host_ip}>;tag={d["tag"]}',
            f'To: <{d["uri"]}>;tag={d["to_tag"]}',
            f'Call-ID: {d["call_id"]}@{self.host_ip}',
            f'CSeq: {d["cseq"]} ACK',
            'Max-Forwards: 70', 'Content-Length: 0', '', '',
        ])
        s.sendto(msg.encode(), self.target)

    def _bye(self, d):
        s = d['sock']
        lport = s.getsockname()[1]
        d['cseq'] += 1
        msg = '\r\n'.join([
            f'BYE {d["remote_target"]} SIP/2.0',
            f'Via: SIP/2.0/UDP {self.host_ip}:{lport};branch=z9hG4bK{uuid.uuid4().hex}',
            f'From: <sip:{self.caller_id}@{self.host_ip}>;tag={d["tag"]}',
            f'To: <{d["uri"]}>;tag={d["to_tag"]}',
            f'Call-ID: {d["call_id"]}@{self.host_ip}',
            f'CSeq: {d["cseq"]} BYE',
            'Max-Forwards: 70', 'Content-Length: 0', '', '',
        ])
        s.sendto(msg.encode(), self.target)

    def hangup_all(self):
        """CANCEL every call this caller has outstanding.

        Needed between sections: a test that leaves calls up silently changes the
        starting concurrency for every test after it, which is exactly how the
        header-relay checks first came to be rejected by the total cap rather
        than actually failing.
        """
        for d in self._dialogs:
            try:
                # An answered call needs a BYE; CANCEL is only valid while the
                # INVITE transaction is still pending.
                if d.get('to_tag'):
                    self._bye(d)
                    continue
            except OSError:
                continue
            s = d['sock']
            lport = s.getsockname()[1]
            msg = '\r\n'.join([
                f'CANCEL {d["uri"]} SIP/2.0',
                f'Via: SIP/2.0/UDP {self.host_ip}:{lport};branch={d["branch"]}',
                f'From: <sip:{self.caller_id}@{self.host_ip}>;tag={d["tag"]}',
                f'To: <{d["uri"]}>',
                f'Call-ID: {d["call_id"]}@{self.host_ip}',
                f'CSeq: {d["cseq"]} CANCEL',
                'Max-Forwards: 70', 'Content-Length: 0', '', '',
            ])
            try:
                s.sendto(msg.encode(), self.target)
            except OSError:
                pass

    def close(self):
        for s in self._sockets:
            s.close()
        self._sockets = []


def digest_for(challenge, user, password, uri, method='INVITE'):
    realm = re.search(r'realm="([^"]*)"', challenge).group(1)
    nonce = re.search(r'nonce="([^"]*)"', challenge).group(1)
    ha1 = hashlib.md5(f'{user}:{realm}:{password}'.encode()).hexdigest()
    ha2 = hashlib.md5(f'{method}:{uri}'.encode()).hexdigest()
    resp = hashlib.md5(f'{ha1}:{nonce}:{ha2}'.encode()).hexdigest()
    return (f'Digest username="{user}", realm="{realm}", nonce="{nonce}", '
            f'uri="{uri}", response="{resp}", algorithm=MD5')


def challenge_of(raw_messages):
    for m in raw_messages:
        found = re.search(r'WWW-Authenticate:\s*(.*)', m)
        if found:
            return found.group(1).strip()
    return None


def _param(msg, header, name):
    line = re.search(rf'^{header}:\s*(.*)$', msg, re.I | re.M)
    if not line:
        return ''
    found = re.search(rf'{name}=([^;\s>]+)', line.group(1))
    return found.group(1) if found else ''


def _contact_uri(msg):
    line = re.search(r'^Contact:\s*(.*)$', msg, re.I | re.M)
    if not line:
        return ''
    found = re.search(r'<([^>]+)>', line.group(1))
    return found.group(1) if found else line.group(1).strip()


def _ulaw_to_lin(u):
    u = ~u & 0xFF
    v = (((u & 0x0F) << 3) + 0x84) << ((u >> 4) & 7)
    v -= 0x84
    return (-v if u & 0x80 else v) / 32768.0


_ULAW = [_ulaw_to_lin(i) for i in range(256)]


def _lin_to_ulaw(sample):
    """16-bit signed linear -> mu-law byte (standard G.711 encoding)."""
    sign = 0x80 if sample < 0 else 0
    sample = min(abs(sample), 32635) + 0x84
    exp, mask = 7, 0x4000
    while exp > 0 and not (sample & mask):
        exp, mask = exp - 1, mask >> 1
    mant = (sample >> (exp + 3)) & 0x0F
    return ~(sign | (exp << 4) | mant) & 0xFF


def tone_payload(freq=1000, amplitude=0.3):
    """160 samples (20 ms) of a sine tone. 1 kHz has a period of exactly 8
    samples at 8 kHz, so consecutive packets are identical and phase-continuous."""
    return bytes(_lin_to_ulaw(int(amplitude * 32767 * math.sin(2 * math.pi * freq * n / 8000)))
                 for n in range(160))


def sdp_media_address(raw_messages):
    """(host, port) of the audio stream in the first message carrying SDP."""
    for m in raw_messages:
        ip = re.search(r'^c=IN IP4 (\S+)', m, re.M)
        port = re.search(r'^m=audio (\d+)', m, re.M)
        if ip and port:
            return ip.group(1), int(port.group(1))
    return None


class RtpEndpoint:
    """One side of a call's media.

    Sends PCMU SILENCE and records the loudest energy it receives. Sending
    silence rather than nothing matters twice over: Asterisk latches the remote
    address from the first packets it sees, so a silent peer would never be
    heard back; and because the endpoint itself contributes nothing audible,
    anything it receives that is not silence must be audio Asterisk injected.
    """

    def __init__(self, local_port, tone=False):
        # tone=True stands in for a caller who is TALKING; the default is silence.
        self.payload = tone_payload() if tone else b'\xff' * 160
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(('0.0.0.0', local_port))
        self.sock.settimeout(0.2)
        self.samples = []            # (time, per-packet RMS)
        self._stop = threading.Event()
        self._threads = []

    def start(self, remote, send_seconds=None):
        """`send_seconds` stops transmitting after that long while still
        receiving -- a stand-in for a phone doing silence suppression, which
        stops sending RTP entirely while its user is quiet."""
        began = time.time()

        def send():
            seq, ts = 0, 0
            while not self._stop.is_set():
                if send_seconds is not None and time.time() - began > send_seconds:
                    time.sleep(0.02)
                    continue
                hdr = bytes([0x80, 0]) + (seq & 0xFFFF).to_bytes(2, 'big') \
                    + (ts & 0xFFFFFFFF).to_bytes(4, 'big') + (0xBADA55).to_bytes(4, 'big')
                self.sock.sendto(hdr + self.payload, remote)
                seq, ts = seq + 1, ts + 160
                time.sleep(0.02)

        def recv():
            while not self._stop.is_set():
                try:
                    pkt, _ = self.sock.recvfrom(2048)
                except socket.timeout:
                    continue
                except OSError:
                    return
                if len(pkt) > 12:
                    body = pkt[12:]
                    rms = math.sqrt(sum(_ULAW[b] ** 2 for b in body) / len(body))
                    self.samples.append((time.time(), rms))

        for fn in (send, recv):
            t = threading.Thread(target=fn, daemon=True)
            t.start()
            self._threads.append(t)

    def loudest_since(self, t0):
        return max((r for t, r in self.samples if t >= t0), default=0.0)

    def stop(self):
        self._stop.set()
        for t in self._threads:
            t.join(timeout=1)
        self.sock.close()

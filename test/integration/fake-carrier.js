// A carrier that never answers.
//
// Calls have to STAY UP for a concurrency cap to be observable, so this holds
// every INVITE at 180 Ringing indefinitely rather than answering or rejecting.
// It also answers OPTIONS, without which Asterisk's qualify marks the endpoint
// unreachable and refuses to build outbound channels at all.
//
// It logs every request-URI it is asked to dial, which is the only place that
// catches the destination being wrong -- the caller-side SIP response looks
// identical whether Asterisk dialled the right number or the wrong one.
const dgram = require('dgram');
const s = dgram.createSocket('udp4');
const hdr = (m, n) => (m.match(new RegExp('^' + n + ':\\s*(.*)$', 'im')) || [])[1] || '';

// ---------------------------------------------------------------------------
// RTP. With ANSWER=1 the carrier is a real media endpoint: it sends PCMU
// silence to whatever address the INVITE's SDP names, and reports any energy it
// RECEIVES. Since both parties send pure silence, anything audible arriving here
// is audio Asterisk injected -- which is what lets a test say whether the
// TERMINATING side of a call actually hears the announcement, rather than
// inferring it from the fact that playback "succeeded".
// ---------------------------------------------------------------------------
const ulaw = (u) => {
  u = ~u & 0xff;
  const exp = (u >> 4) & 7;
  let v = (((u & 0x0f) << 3) + 0x84) << exp;
  v -= 0x84;
  return (u & 0x80 ? -v : v) / 32768;
};
let rtpRemote = null, rxPeak = 0, rtpSeq = 0, rtpTs = 0;
if (process.env.ANSWER === '1') {
  const rtp = dgram.createSocket('udp4');
  rtp.on('message', (pkt) => {
    if (pkt.length <= 12) return;
    let sum = 0;
    for (let i = 12; i < pkt.length; i++) { const x = ulaw(pkt[i]); sum += x * x; }
    rxPeak = Math.max(rxPeak, Math.sqrt(sum / (pkt.length - 12)));
  });
  rtp.bind(40002);
  setInterval(() => {                      // 20ms of silence, PCMU
    if (!rtpRemote) return;
    const pkt = Buffer.alloc(172, 0xff);
    pkt[0] = 0x80; pkt[1] = 0;
    pkt.writeUInt16BE(rtpSeq++ & 0xffff, 2);
    pkt.writeUInt32BE(rtpTs, 4); rtpTs += 160;
    pkt.writeUInt32BE(0xc0ffee, 8);
    rtp.send(pkt, rtpRemote.port, rtpRemote.host);
  }, 20);
  setInterval(() => {
    if (rxPeak > 0.02) console.log(JSON.stringify({ heard: true, rms: +rxPeak.toFixed(3), t: Date.now() }));
    rxPeak = 0;
  }, 250);
}

// A real carrier answers a CANCEL with 200 AND ends the INVITE with 487. Without
// the 487 the calling side never sees the transaction finish, so a cancelled
// call can linger and keep holding a concurrency slot -- which would make later
// tests fail for reasons that have nothing to do with what they are testing.
const pending = new Map();   // Call-ID -> the INVITE still awaiting a final response
const respondTo = (msg, rinfo, line) => {
  const b = ['Via: ' + hdr(msg, 'Via'), 'From: ' + hdr(msg, 'From'),
             'To: ' + hdr(msg, 'To') + ';tag=fakecarrier', 'Call-ID: ' + hdr(msg, 'Call-ID'),
             'CSeq: ' + hdr(msg, 'CSeq'), 'Content-Length: 0', '', ''].join('\r\n');
  s.send(Buffer.from('SIP/2.0 ' + line + '\r\n' + b), rinfo.port, rinfo.address);
};

s.on('message', (buf, rinfo) => {
  const m = buf.toString();
  const first = m.split('\r\n')[0];
  const method = first.split(' ')[0];
  const base = [
    'Via: ' + hdr(m, 'Via'),
    'From: ' + hdr(m, 'From'),
    'To: ' + hdr(m, 'To') + ';tag=fakecarrier',
    'Call-ID: ' + hdr(m, 'Call-ID'),
    'CSeq: ' + hdr(m, 'CSeq'),
    'Content-Length: 0', '', '',
  ].join('\r\n');
  const reply = (line) => s.send(Buffer.from('SIP/2.0 ' + line + '\r\n' + base), rinfo.port, rinfo.address);

  // REJECT=503 models a gateway that is busy or overloaded; REJECT=486 models a
  // CALLEE that is busy. Both still answer OPTIONS, so qualification keeps
  // reporting the gateway as reachable -- exactly the case where failover has to
  // come from the call itself failing rather than from the gateway being marked
  // down.
  const REASONS = { 503: '503 Service Unavailable', 486: '486 Busy Here', 404: '404 Not Found' };
  if (method === 'OPTIONS') reply('200 OK');
  else if (method === 'INVITE' && process.env.REJECT) reply(REASONS[process.env.REJECT] || process.env.REJECT);
  else if (method === 'INVITE') {
    pending.set(hdr(m, 'Call-ID'), { m, rinfo });
    reply('100 Trying');
    setTimeout(() => reply('180 Ringing'), 50);
    // ANSWER=1 makes the call go up, which is what the announcement path needs:
    // a snoop audiohook has nothing to whisper into while the call is still
    // ringing. Left off by default so the concurrency tests can assert on the
    // 180 Ringing that keeps calls pinned in their groups.
    if (process.env.ANSWER === '1') {
      setTimeout(() => {
        const sdp = ['v=0', 'o=- 2 2 IN IP4 172.29.0.3', 's=-', 'c=IN IP4 172.29.0.3',
                     't=0 0', 'm=audio 40002 RTP/AVP 0', 'a=rtpmap:0 PCMU/8000', ''].join('\r\n');
        const ok = ['SIP/2.0 200 OK', 'Via: ' + hdr(m, 'Via'), 'From: ' + hdr(m, 'From'),
                    'To: ' + hdr(m, 'To') + ';tag=fakecarrier', 'Call-ID: ' + hdr(m, 'Call-ID'),
                    'CSeq: ' + hdr(m, 'CSeq'), 'Contact: <sip:carrier@172.29.0.3:5060>',
                    'Content-Type: application/sdp', 'Content-Length: ' + sdp.length,
                    '', sdp].join('\r\n');
        s.send(Buffer.from(ok), rinfo.port, rinfo.address);
      }, 400);
    }
  }
  else if (method === 'CANCEL') {
    reply('200 OK');
    const p = pending.get(hdr(m, 'Call-ID'));
    if (p) { respondTo(p.m, p.rinfo, '487 Request Terminated'); pending.delete(hdr(m, 'Call-ID')); }
  }
  else if (method === 'BYE') reply('200 OK');

  if (method === 'INVITE' && process.env.ANSWER === '1') {
    const ip = (m.match(/^c=IN IP4 (\S+)/m) || [])[1];
    const port = (m.match(/^m=audio (\d+)/m) || [])[1];
    if (ip && port) rtpRemote = { host: ip, port: +port };
  }
  if (method === 'BYE' || method === 'CANCEL') rtpRemote = null;

  if (method === 'INVITE') {
    // Identity headers are relayed by a pre-dial handler, so what arrives here
    // is the only proof they survived the B2BUA hop.
    console.log(JSON.stringify({
      uri: first.split(' ')[1] || '',
      identity: hdr(m, 'Identity'),
      pai: hdr(m, 'P-Asserted-Identity'),
      diversion: hdr(m, 'Diversion'),
    }));
  }
});
s.bind(5060, () => console.log('{"ready":true}'));

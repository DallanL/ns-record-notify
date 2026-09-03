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

  if (method === 'OPTIONS') reply('200 OK');
  else if (method === 'INVITE') {
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
  else if (method === 'CANCEL' || method === 'BYE') reply('200 OK');

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

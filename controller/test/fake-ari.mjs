import http from 'node:http';
import { WebSocketServer } from 'ws';

export const seen = [];
let sockets = [];

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://x');
  const p = url.pathname;
  seen.push(`${req.method} ${p}`);

  if (req.method === 'GET' && /\/ari\/channels\/[^/]+\/variable$/.test(p)) {
    const v = url.searchParams.get('variable');
    const values = { NS_PAI: '"Jo Smith" <sip:1001@pbx.example.com>', NS_FROM: '<sip:1001@pbx.example.com>', NS_DEST: '5551212' };
    if (values[v]) { res.writeHead(200, {'content-type':'application/json'}); return res.end(JSON.stringify({ value: values[v] })); }
    res.writeHead(404); return res.end('{}');
  }
  if (req.method === 'GET' && p === '/ari/channels') { res.writeHead(200,{'content-type':'application/json'}); return res.end('[]'); }
  if (req.method === 'POST' && /\/snoop$/.test(p)) {
    const id = url.searchParams.get('snoopId');
    seen.push(`SNOOP spy=${url.searchParams.get('spy')} whisper=${url.searchParams.get('whisper')}`);
    res.writeHead(200,{'content-type':'application/json'}); return res.end(JSON.stringify({ id }));
  }
  if (req.method === 'POST' && /\/play$/.test(p)) {
    seen.push(`PLAY media=${url.searchParams.get('media')}`);
    res.writeHead(200,{'content-type':'application/json'}); return res.end(JSON.stringify({ id: url.searchParams.get('playbackId') }));
  }
  res.writeHead(204); res.end();
});

const wss = new WebSocketServer({ server, path: '/ari/events' });
wss.on('connection', (ws) => { sockets.push(ws); });

export function emit(event) { for (const s of sockets) s.send(JSON.stringify(event)); }
export function start(port) { return new Promise((r) => server.listen(port, '127.0.0.1', r)); }
export function stop() { wss.close(); server.close(); }

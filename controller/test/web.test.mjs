// Access control for the operator UI, exercised against the real express app.
import assert from 'node:assert/strict';
import { createServer, listen } from '../src/web.js';
import { authFromEnv, exposureError, isLoopback } from '../src/auth.js';

const registry = {
  calls: new Map(),
  list: () => [],
  startAnnouncement: async () => ({ ok: true }),
  stopAnnouncement: async () => ({ ok: true }),
  stopAll: async () => ({ stopped: 0 }),
};
const rules = { config: { enabled: true }, load: () => ({}) };
const basic = (u, p) => 'Basic ' + Buffer.from(`${u}:${p}`).toString('base64');

async function serve(auth) {
  const server = await listen(createServer({ registry, rules, auth }), 0, '127.0.0.1');
  return { base: `http://127.0.0.1:${server.address().port}`, close: () => new Promise((r) => server.close(r)) };
}
const status = async (base, path, init) => (await fetch(base + path, init)).status;

// ---- no credentials configured (loopback deployment): everything is open -----
{
  const s = await serve(null);
  assert.equal(await status(s.base, '/api/calls'), 200);
  assert.equal(await status(s.base, '/'), 200);
  await s.close();
  console.log('open mode ok: no auth configured, nothing is challenged');
}

// ---- credentials configured -----------------------------------------------------
const auth = { user: 'operator', pass: 'correct-horse-battery' };
{
  const s = await serve(auth);

  const anon = await fetch(s.base + '/api/calls');
  assert.equal(anon.status, 401);
  assert.match(anon.headers.get('www-authenticate'), /^Basic realm=/);

  assert.equal(await status(s.base, '/', {}), 401, 'the static UI is protected too, not just the API');
  assert.equal(await status(s.base, '/api/calls', { headers: { authorization: basic('operator', 'wrong-password-x') } }), 401);
  assert.equal(await status(s.base, '/api/calls', { headers: { authorization: basic('root', 'correct-horse-battery') } }), 401, 'right password, wrong user');
  assert.equal(await status(s.base, '/api/calls', { headers: { authorization: basic('operator', 'correct-horse-battery') } }), 200);
  assert.equal(await status(s.base, '/api/calls', { headers: { authorization: 'Bearer correct-horse-battery' } }), 401, 'a different scheme is not accepted');
  assert.equal(await status(s.base, '/api/calls', { headers: { authorization: 'Basic !!!not-base64!!!' } }), 401, 'garbage credentials do not crash it');

  // A password containing ':' must still work: only the FIRST colon splits user from password.
  const colon = await serve({ user: 'operator', pass: 'pass:with:colons-123' });
  assert.equal(await status(colon.base, '/api/calls', { headers: { authorization: basic('operator', 'pass:with:colons-123') } }), 200);
  await colon.close();

  assert.equal(await status(s.base, '/api/health'), 200, 'healthcheck stays open so the container can report healthy');
  console.log('authentication ok: 401 without/with wrong credentials, UI and API both protected');

  // ---- cross-site request forgery: the browser attaches Basic auth by itself ----
  const ok = { authorization: basic('operator', 'correct-horse-battery') };
  const post = (origin) => status(s.base, '/api/announce/stop-all', {
    method: 'POST', headers: { ...ok, ...(origin ? { origin } : {}) },
  });
  assert.equal(await post(null), 200, 'no Origin (curl, scripts) is fine');
  assert.equal(await post(s.base), 200, 'same origin is fine');
  assert.equal(await post('https://evil.example'), 403, 'a foreign page cannot press "stop all"');
  assert.equal(await post('not a url'), 403, 'a malformed Origin is refused, not waved through');
  assert.equal(await status(s.base, '/api/calls', { headers: { ...ok, origin: 'https://evil.example' } }), 200, 'reads are not state-changing');
  console.log('csrf ok: cross-origin POSTs are refused');

  // ---- response hardening --------------------------------------------------------
  const res = await fetch(s.base + '/api/calls', { headers: ok });
  assert.equal(res.headers.get('x-frame-options'), 'DENY');
  assert.equal(res.headers.get('x-content-type-options'), 'nosniff');
  assert.equal(res.headers.get('x-powered-by'), null);
  assert.match(res.headers.get('cache-control'), /no-store/);
  await s.close();
  console.log('headers ok: framing denied, sniffing off, framework not advertised');
}

// ---- configuration guards -------------------------------------------------------
assert.equal(authFromEnv({}), null);
assert.deepEqual(authFromEnv({ WEB_USER: 'a', WEB_PASS: 'long-enough-pass' }), { user: 'a', pass: 'long-enough-pass' });
assert.throws(() => authFromEnv({ WEB_USER: 'a' }), /together/);
assert.throws(() => authFromEnv({ WEB_PASS: 'long-enough-pass' }), /together/);
assert.throws(() => authFromEnv({ WEB_USER: 'a', WEB_PASS: 'short' }), /at least 12/);

assert.equal(exposureError('127.0.0.1', null), null, 'loopback without auth is the safe default');
assert.equal(exposureError('localhost', null), null);
assert.equal(exposureError('::1', null), null);
assert.match(exposureError('0.0.0.0', null), /refusing/, 'the public bind that was silently allowed before');
assert.match(exposureError('10.0.0.5', null), /refusing/);
assert.match(exposureError('::', null), /refusing/);
assert.equal(exposureError('0.0.0.0', auth), null, 'binding wide is fine once it is authenticated');
assert.equal(isLoopback('LOCALHOST'), true);
console.log('config guards ok: a non-loopback bind without credentials is refused');

console.log('\nWEB ALL PASS');

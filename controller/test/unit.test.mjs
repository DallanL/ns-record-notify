import assert from 'node:assert';
import { Rules, extractExtension } from '../src/rules.js';
import { Announcer } from '../src/announcer.js';

// ---- extractExtension ----
assert.equal(extractExtension({ pai: '"Jo" <sip:1001@pbx.example.com>' }), '1001');
assert.equal(extractExtension({ pai: null, from: '<sip:2044@d.com>;tag=x' }), '2044');
assert.equal(extractExtension({ from: '<sips:3001@d.com>' }), '3001');
assert.equal(extractExtension({ callerNumber: '5551212' }), '5551212');
assert.equal(extractExtension({}), null);
console.log('extractExtension ok');

// ---- Rules ----
const r = new Rules(new URL('../../config/rules.yaml', import.meta.url).pathname);
// shipped default is disabled
assert.equal(r.evaluate({ dialed: '5551212' }).announce, false);
r.config.enabled = true;
// every routed call is in scope regardless of who placed it or what was dialed
assert.equal(r.evaluate({ dialed: '5551212' }).announce, true);
assert.equal(r.evaluate({ dialed: '+15551212' }).announce, true);
assert.equal(r.evaluate({ dialed: null }).announce, true, 'unknown destination still announces');
// emergency must never announce
for (const d of ['911', '1911', '+1911', '112', '933', '999', '000']) {
  assert.equal(r.evaluate({ dialed: d }).announce, false, `emergency ${d} must not announce`);
  assert.equal(r.isBlockedDestination(d), true, `${d} must be blocked for manual start too`);
}
assert.equal(r.isBlockedDestination('5551212'), false);
console.log('rules ok');

// ---- Announcer state machine against a fake ARI ----
const calls = [];
const fakeAri = {
  snoopWhisper: async (id, snoopId) => { calls.push(['snoop', id, snoopId]); return { id: snoopId }; },
  play: async (ch, media, pid) => { calls.push(['play', ch, media, pid]); return { id: pid }; },
  stopPlayback: async (pid) => { calls.push(['stopPlayback', pid]); },
  hangup: async (id) => { calls.push(['hangup', id]); },
};

const a = new Announcer({
  ari: fakeAri,
  channelId: 'PJSIP/ns-0001',
  config: { media: 'sound:custom/x', intervalSeconds: 1, initialDelaySeconds: 0, maxDurationSeconds: 0 },
});

assert.equal(a.status, 'idle');
await a.start();
assert.equal(a.active, true);
assert.equal(calls[0][0], 'snoop');
assert.equal(calls[0][3] === undefined, true);

await new Promise((res) => setTimeout(res, 50));
assert.equal(a.status, 'playing', 'should be playing after first tick');
assert.equal(calls.filter((c) => c[0] === 'play').length, 1);

// while a playback is still running, the next tick must NOT stack a second play
await new Promise((res) => setTimeout(res, 1100));
assert.equal(calls.filter((c) => c[0] === 'play').length, 1, 'must not overlap playbacks');

// once it finishes, the following tick plays again
a.notePlaybackFinished(calls.find((c) => c[0] === 'play')[3]);
assert.equal(a.status, 'waiting');
await new Promise((res) => setTimeout(res, 1100));
assert.equal(calls.filter((c) => c[0] === 'play').length, 2, 'should resume after finish');

await a.stop();
assert.equal(a.active, false);
assert.equal(a.status, 'idle');
// stop() must NOT hang the snoop up -- Asterisk cannot tear it down while the
// spied channel lives, so it is reused instead of accumulating.
assert.ok(!calls.some((c) => c[0] === 'hangup'), 'stop must leave the snoop attached');

// no further plays after stop
const after = calls.filter((c) => c[0] === 'play').length;
await new Promise((res) => setTimeout(res, 1300));
assert.equal(calls.filter((c) => c[0] === 'play').length, after, 'no plays after stop');

// stop is idempotent
await a.stop();

// restarting reuses the SAME snoop rather than creating another
const snoopsBefore = calls.filter((c) => c[0] === 'snoop').length;
await a.start();
assert.equal(calls.filter((c) => c[0] === 'snoop').length, snoopsBefore, 'restart must reuse the snoop');
await a.stop();

// dispose tears the snoop down
await a.dispose();
assert.ok(calls.some((c) => c[0] === 'hangup'), 'dispose must hang up the snoop');
// dispose must prevent any later start
await a.start();
assert.equal(a.active, false, 'disposed announcer must not restart');
console.log('announcer ok');
console.log('\nALL PASS');

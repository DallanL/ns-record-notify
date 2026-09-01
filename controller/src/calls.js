import { Announcer } from './announcer.js';
import { extractExtension } from './rules.js';
import { DigitMatcher } from './dtmf.js';
import { log } from './log.js';

/**
 * Tracks outbound calls and wires ARI events to announcement lifecycle.
 *
 * Flow for one call:
 *   1. StasisStart (appArgs=classify) -- read identity headers, evaluate rules,
 *      then immediately continue back to the dialplan so Dial() can run.
 *   2. ChannelStateChange -> Up -- Dial() answered; start announcing if matched.
 *   3. ChannelDestroyed / StasisEnd -- tear everything down.
 *
 * We rely on the WebSocket's subscribeAll=true to keep receiving events for a
 * channel after it has left our Stasis app; without it step 2 and 3 never
 * arrive.
 */
export class CallRegistry {
  constructor({ ari, rules }) {
    this.ari = ari;
    this.rules = rules;
    this.calls = new Map(); // channelId -> call record
  }

  attach() {
    this.ari.on('StasisStart', (e) => this.#onStasisStart(e).catch(this.#logFailure('StasisStart')));
    this.ari.on('ChannelStateChange', (e) => this.#onStateChange(e).catch(this.#logFailure('ChannelStateChange')));
    this.ari.on('ChannelDestroyed', (e) => this.#onDestroyed(e).catch(this.#logFailure('ChannelDestroyed')));
    this.ari.on('PlaybackFinished', (e) => this.#onPlaybackFinished(e));
    this.ari.on('ChannelEnteredBridge', (e) => this.#onEnteredBridge(e));
    this.ari.on('ChannelDtmfReceived', (e) => this.#onDtmf(e).catch(this.#logFailure('ChannelDtmfReceived')));
    this.ari.on('connected', () => this.#reconcile().catch(this.#logFailure('reconcile')));
  }

  #logFailure(where) {
    return (err) => log.error(`handler ${where} failed`, { message: err.message });
  }

  async #onStasisStart(event) {
    const channel = event.channel;

    // Snoop channels we created also enter the app. They are not calls.
    if (channel.id.startsWith('snoop-')) return;

    // Only the classify hop from the dialplan is ours to act on.
    if (!(event.args ?? []).includes('classify')) return;

    const [pai, from, dest] = await Promise.all([
      this.ari.getChannelVar(channel.id, 'NS_PAI'),
      this.ari.getChannelVar(channel.id, 'NS_FROM'),
      this.ari.getChannelVar(channel.id, 'NS_DEST'),
    ]);

    // Extension is for the operator UI only -- every call routed here is in
    // scope, so it plays no part in the decision.
    const extension = extractExtension({ pai, from, callerNumber: channel.caller?.number });
    const dialed = dest || channel.dialplan?.exten || null;
    const decision = this.rules.evaluate({ dialed });

    const call = {
      channelId: channel.id,
      channelName: channel.name,
      extension,
      dialed,
      callerName: channel.caller?.name || null,
      pai,
      startedAt: Date.now(),
      answeredAt: null,
      autoAnnounce: decision.announce,
      reason: decision.reason,
      // Set once the dialplan Dial() bridges the two legs, so DTMF from the far
      // party can be attributed back to this call.
      bridgeId: null,
      peerChannelId: null,
      digits: new DigitMatcher(
        this.rules.config.dtmfDigits,
        this.rules.config.dtmfTimeoutSeconds * 1000,
      ),
      announcer: new Announcer({
        ari: this.ari,
        channelId: channel.id,
        config: this.rules.config,
      }),
    };
    this.calls.set(channel.id, call);

    log.info('outbound call classified', {
      channelId: channel.id,
      extension,
      dialed,
      announce: decision.announce,
      reason: decision.reason,
    });

    // Hand the channel straight back to the dialplan. Everything after this is
    // a native Dial(), which is what keeps early media and CDRs correct.
    await this.ari.continueInDialplan(channel.id);
  }

  async #onStateChange(event) {
    const call = this.calls.get(event.channel?.id);
    if (!call || call.answeredAt) return;
    if (event.channel.state !== 'Up') return;

    call.answeredAt = Date.now();
    log.debug('call answered', { channelId: call.channelId });

    if (call.autoAnnounce) {
      await call.announcer.start().catch((err) =>
        log.error('could not start announcement', { channelId: call.channelId, message: err.message }));
    }
  }

  async #onDestroyed(event) {
    const id = event.channel?.id;
    const call = this.calls.get(id);
    if (!call) return;
    this.calls.delete(id);
    await call.announcer.dispose();
    log.info('call ended', { channelId: id, durationSeconds: Math.round((Date.now() - call.startedAt) / 1000) });
  }

  /**
   * Track bridge membership so the outbound leg can be identified. Dial()
   * creates the bridge, so this is the only place the peer channel is learnt.
   */
  #onEnteredBridge(event) {
    const bridgeId = event.bridge?.id;
    const channelId = event.channel?.id;
    if (!bridgeId || !channelId) return;

    const own = this.calls.get(channelId);
    if (own) {
      own.bridgeId = bridgeId;
      // The outbound leg usually enters the bridge FIRST, before we have a
      // bridgeId to match it against, so pick it up from the membership list
      // rather than relying on event order.
      const peer = (event.bridge.channels ?? []).find((id) => id !== channelId);
      if (peer && own.peerChannelId === null) {
        own.peerChannelId = peer;
        log.debug('peer leg identified', { channelId, peer });
      }
      return;
    }

    // Late-joining leg, for the opposite ordering.
    for (const call of this.calls.values()) {
      if (call.bridgeId === bridgeId && call.peerChannelId === null) {
        call.peerChannelId = channelId;
        log.debug('peer leg identified', { channelId: call.channelId, peer: channelId });
        return;
      }
    }
  }

  /**
   * A digit pressed on either leg can stop the announcement.
   *
   * This only works while a snoop channel is attached: in a native RTP bridge
   * Asterisk passes DTMF straight through without surfacing it, and it is the
   * announcement's own audiohook that causes the frames to be processed. That is
   * sufficient, since there is nothing to stop before the first announcement,
   * and the snoop persists for the rest of the call once created.
   */
  async #onDtmf(event) {
    const channelId = event.channel?.id;
    const digit = event.digit;
    if (!channelId || !digit) return;

    let call = this.calls.get(channelId);
    let side = 'caller';
    if (!call) {
      call = [...this.calls.values()].find((c) => c.peerChannelId === channelId);
      side = 'callee';
    }
    if (!call || !call.digits.enabled) return;

    const allowed = this.rules.config.dtmfAcceptFrom;
    if (allowed !== 'any' && allowed !== side) {
      log.debug('ignoring DTMF from disallowed side', { channelId: call.channelId, side, allowed });
      return;
    }

    if (!call.digits.press(digit)) return;

    log.info('announcement stopped by DTMF', {
      channelId: call.channelId,
      side,
      digits: this.rules.config.dtmfDigits,
    });
    call.autoAnnounce = false;
    call.reason = `stopped by ${side} via DTMF`;
    await call.announcer.stop();
  }

  #onPlaybackFinished(event) {
    const playbackId = event.playback?.id;
    if (!playbackId) return;
    for (const call of this.calls.values()) {
      if (call.announcer.ownsPlayback(playbackId)) {
        call.announcer.notePlaybackFinished(playbackId);
        return;
      }
    }
  }

  /**
   * After a websocket reconnect we may hold records for calls that ended while
   * we were disconnected. Drop anything Asterisk no longer knows about so the
   * operator view and the snoop channels do not leak.
   */
  async #reconcile() {
    if (this.calls.size === 0) return;
    const live = new Set((await this.ari.listChannels()).map((c) => c.id));
    for (const [id, call] of [...this.calls]) {
      if (!live.has(id)) {
        this.calls.delete(id);
        await call.announcer.dispose();
        log.info('reaped stale call after reconnect', { channelId: id });
      }
    }
  }

  // ---- operator actions ----------------------------------------------------

  list() {
    return [...this.calls.values()].map((c) => ({
      channelId: c.channelId,
      extension: c.extension,
      dialed: c.dialed,
      callerName: c.callerName,
      answered: c.answeredAt !== null,
      startedAt: c.startedAt,
      answeredAt: c.answeredAt,
      autoAnnounce: c.autoAnnounce,
      reason: c.reason,
      announcement: c.announcer.status,
      plays: c.announcer.playCount,
    }));
  }

  async startAnnouncement(channelId) {
    const call = this.calls.get(channelId);
    if (!call) throw Object.assign(new Error('no such call'), { status: 404 });
    if (this.rules.isBlockedDestination(call.dialed)) {
      throw Object.assign(new Error(`destination ${call.dialed} is blocked from announcements`), { status: 403 });
    }
    if (!call.answeredAt) {
      throw Object.assign(new Error('call is not answered yet'), { status: 409 });
    }
    await call.announcer.start();
    return { ok: true };
  }

  async stopAnnouncement(channelId) {
    const call = this.calls.get(channelId);
    if (!call) throw Object.assign(new Error('no such call'), { status: 404 });
    // Stop must also cancel the automatic behaviour, otherwise nothing changes.
    call.autoAnnounce = false;
    call.reason = 'stopped by operator';
    await call.announcer.stop();
    return { ok: true };
  }

  async stopAll() {
    let stopped = 0;
    for (const call of this.calls.values()) {
      call.autoAnnounce = false;
      if (call.announcer.active) stopped += 1;
      call.reason = 'stopped by operator';
      await call.announcer.stop();
    }
    return { ok: true, stopped };
  }
}

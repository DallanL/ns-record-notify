import { randomUUID } from 'node:crypto';
import { log } from './log.js';

/**
 * Drives the repeating announcement on a single answered call.
 *
 * Injection works by attaching one snoop channel with whisper=both to the
 * NetSapiens-side channel. Audio played to that snoop channel is transmitted
 * into both directions of the monitored channel, so it reaches the internal
 * caller and the far party. Snoop attaches an audiohook rather than re-bridging,
 * which is what lets the call itself stay on a plain dialplan Dial().
 *
 * The interval is deliberately play-once-then-wait rather than a looped file:
 * a looped file talks over the entire conversation and cannot be cut cleanly
 * mid-loop, whereas a discrete playback has a playbackId we can delete.
 *
 * Snoop lifetime is per CALL, not per announcement. Verified against Asterisk
 * 20.6: `DELETE /channels/{snoopId}` returns 204 but does not actually tear a
 * snoop channel down while the spied channel is still up -- Asterisk reaps it
 * with the call. Creating one per start/stop cycle therefore accumulates idle
 * Snoop channels on a long call, so we create at most one and reuse it.
 */
export class Announcer {
  constructor({ ari, channelId, config }) {
    this.ari = ari;
    this.channelId = channelId;
    this.config = config;

    this.snoopId = null;
    this.playbackId = null;
    this.timer = null;
    this.maxTimer = null;
    this.running = false;
    this.playing = false;
    this.startedAt = null;
    this.playCount = 0;
    this.failedPlays = 0;
    this.disposed = false;
  }

  /** True while the announcement is scheduled to keep playing. */
  get active() {
    return this.running;
  }

  get status() {
    if (!this.running) return 'idle';
    return this.playing ? 'playing' : 'waiting';
  }

  async #ensureSnoop() {
    if (this.snoopId) return this.snoopId;
    const snoopId = `snoop-${randomUUID()}`;
    await this.ari.snoopWhisper(this.channelId, snoopId);
    this.snoopId = snoopId;
    return snoopId;
  }

  async start() {
    if (this.running || this.disposed) return;

    try {
      await this.#ensureSnoop();
    } catch (err) {
      log.error('failed to create snoop channel', { channelId: this.channelId, message: err.message });
      throw err;
    }

    this.running = true;
    this.startedAt = Date.now();

    log.info('announcement started', {
      channelId: this.channelId,
      snoopId: this.snoopId,
      intervalSeconds: this.config.intervalSeconds,
    });

    this.timer = setTimeout(() => this.#tick(), Math.max(0, this.config.initialDelaySeconds * 1000));

    if (this.config.maxDurationSeconds > 0) {
      this.maxTimer = setTimeout(() => {
        log.info('announcement hit max duration, stopping', { channelId: this.channelId });
        this.stop();
      }, this.config.maxDurationSeconds * 1000);
    }
  }

  async #tick() {
    if (!this.running) return;

    // Never stack playbacks on top of each other. If the prompt is longer than
    // the configured interval we simply wait for the next tick.
    if (this.playing) {
      log.debug('skipping tick, previous playback still running', { channelId: this.channelId });
    } else {
      this.playbackId = `play-${randomUUID()}`;
      this.playing = true;
      try {
        await this.ari.play(this.snoopId, this.config.media, this.playbackId);
        this.playCount += 1;
      } catch (err) {
        this.playing = false;
        this.playbackId = null;
        log.warn('playback failed', { channelId: this.channelId, message: err.message });
      }
    }

    if (!this.running) return;
    this.timer = setTimeout(() => this.#tick(), Math.max(1000, this.config.intervalSeconds * 1000));
  }

  /**
   * Called by the registry when ARI reports one of our playbacks finished.
   *
   * PlaybackFinished fires whether the playback succeeded or not, so the state
   * field is the only thing that distinguishes them. A failure here almost
   * always means Asterisk could not resolve the media -- worth shouting about,
   * because everything else looks healthy while nobody hears anything.
   */
  notePlaybackFinished(playbackId, state) {
    if (playbackId !== this.playbackId) return;
    this.playing = false;
    this.playbackId = null;
    if (state === 'failed') {
      this.failedPlays += 1;
      log.error('playback FAILED -- callers heard nothing', {
        channelId: this.channelId,
        media: this.config.media,
        hint: 'check the file exists under Asterisk\'s data directory: '
          + 'asterisk -rx "core show settings" | grep "Data directory"',
      });
    }
  }

  ownsPlayback(playbackId) {
    return this.playbackId === playbackId;
  }

  /**
   * Stop announcing. Idempotent. The snoop channel is intentionally left
   * attached so a later start() on the same call can reuse it; it costs nothing
   * while silent and is reaped when the call ends.
   */
  async stop() {
    if (!this.running) return;
    this.running = false;

    clearTimeout(this.timer);
    clearTimeout(this.maxTimer);
    this.timer = null;
    this.maxTimer = null;

    const { playbackId } = this;
    this.playbackId = null;
    this.playing = false;

    if (playbackId) {
      await this.ari.stopPlayback(playbackId).catch((err) =>
        log.warn('stopPlayback failed', { playbackId, message: err.message }));
    }

    log.info('announcement stopped', { channelId: this.channelId, plays: this.playCount });
  }

  /**
   * Release everything for a call that has ended. Asterisk hangs the snoop up
   * with the spied channel, so the explicit hangup here is belt-and-braces for
   * the case where we tear down before the call does.
   */
  async dispose() {
    await this.stop();
    this.disposed = true;
    const { snoopId } = this;
    this.snoopId = null;
    if (snoopId) {
      await this.ari.hangup(snoopId).catch((err) =>
        log.debug('snoop hangup failed', { snoopId, message: err.message }));
    }
  }
}

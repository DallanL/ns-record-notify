import { EventEmitter } from 'node:events';
import WebSocket from 'ws';
import { log } from './log.js';

/**
 * Minimal ARI client: REST over fetch, events over a WebSocket.
 *
 * Deliberately not using node-ari-client. We need only a handful of operations,
 * and we need `subscribeAll=true` so we observe channels created by the dialplan
 * Dial() -- not just the ones that enter our Stasis app.
 */
export class Ari extends EventEmitter {
  constructor({ baseUrl, username, password, app }) {
    super();
    this.baseUrl = baseUrl.replace(/\/$/, '');
    this.username = username;
    this.password = password;
    this.app = app;
    this.ws = null;
    this.closed = false;
    this.reconnectDelay = 1000;
  }

  get #authHeader() {
    return `Basic ${Buffer.from(`${this.username}:${this.password}`).toString('base64')}`;
  }

  async request(method, path, query = {}) {
    const url = new URL(`${this.baseUrl}/ari${path}`);
    for (const [k, v] of Object.entries(query)) {
      if (v !== undefined && v !== null) url.searchParams.set(k, String(v));
    }

    const res = await fetch(url, {
      method,
      headers: { Authorization: this.#authHeader, Accept: 'application/json' },
    });

    if (!res.ok) {
      const body = await res.text().catch(() => '');
      const err = new Error(`ARI ${method} ${path} -> ${res.status} ${body}`.trim());
      err.status = res.status;
      throw err;
    }

    if (res.status === 204) return null;
    const text = await res.text();
    return text ? JSON.parse(text) : null;
  }

  // ---- operations we actually use -----------------------------------------

  /** Resume dialplan execution at the priority after Stasis(). */
  continueInDialplan(channelId) {
    return this.request('POST', `/channels/${encodeURIComponent(channelId)}/continue`);
  }

  getChannelVar(channelId, variable) {
    return this.request('GET', `/channels/${encodeURIComponent(channelId)}/variable`, { variable })
      .then((r) => r?.value ?? null)
      // An unset variable is a 404 from ARI, which is not an error for us.
      .catch((e) => (e.status === 404 ? null : Promise.reject(e)));
  }

  listChannels() {
    return this.request('GET', '/channels');
  }

  /**
   * Attach a snoop channel that transmits into BOTH directions of the target.
   * This is the injection primitive: audio played to the returned channel is
   * heard by both parties on the monitored call, and it works alongside a plain
   * dialplan Dial() because snoop attaches an audiohook rather than re-bridging.
   */
  snoopWhisper(targetChannelId, snoopId) {
    return this.request('POST', `/channels/${encodeURIComponent(targetChannelId)}/snoop`, {
      app: this.app,
      spy: 'none',
      whisper: 'both',
      snoopId,
    });
  }

  play(channelId, media, playbackId) {
    return this.request('POST', `/channels/${encodeURIComponent(channelId)}/play`, {
      media,
      playbackId,
    });
  }

  stopPlayback(playbackId) {
    return this.request('DELETE', `/playbacks/${encodeURIComponent(playbackId)}`)
      .catch((e) => (e.status === 404 ? null : Promise.reject(e)));
  }

  hangup(channelId) {
    return this.request('DELETE', `/channels/${encodeURIComponent(channelId)}`)
      .catch((e) => (e.status === 404 ? null : Promise.reject(e)));
  }

  // ---- event stream --------------------------------------------------------

  connect() {
    if (this.closed) return;

    const url = new URL(`${this.baseUrl.replace(/^http/, 'ws')}/ari/events`);
    url.searchParams.set('app', this.app);
    // Without this we would only see channels that enter Stasis, and would miss
    // the outbound leg and the hangup of channels that have continued to dialplan.
    url.searchParams.set('subscribeAll', 'true');

    const ws = new WebSocket(url, { headers: { Authorization: this.#authHeader } });
    this.ws = ws;

    ws.on('open', () => {
      this.reconnectDelay = 1000;
      log.info('ARI websocket connected', { app: this.app });
      this.emit('connected');
    });

    ws.on('message', (raw) => {
      let event;
      try {
        event = JSON.parse(raw.toString());
      } catch {
        log.warn('ARI sent unparseable event');
        return;
      }
      this.emit('event', event);
      if (event.type) this.emit(event.type, event);
    });

    ws.on('error', (err) => log.warn('ARI websocket error', { message: err.message }));

    ws.on('close', () => {
      this.ws = null;
      if (this.closed) return;
      log.warn('ARI websocket closed, reconnecting', { delayMs: this.reconnectDelay });
      this.emit('disconnected');
      setTimeout(() => this.connect(), this.reconnectDelay);
      this.reconnectDelay = Math.min(this.reconnectDelay * 2, 30000);
    });
  }

  close() {
    this.closed = true;
    this.ws?.close();
  }
}

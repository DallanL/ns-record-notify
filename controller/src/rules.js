import { readFileSync } from 'node:fs';
import { parse } from 'yaml';
import { log } from './log.js';

/**
 * Destinations that must never be announced over, independent of config.
 * An announcement talking over an emergency call is a safety problem, so this
 * is enforced in code rather than left to a config file someone can edit.
 */
const EMERGENCY = new Set(['911', '1911', '+1911', '933', '112', '999', '000']);

function globToRegExp(pattern) {
  const escaped = String(pattern).replace(/[.+^${}()|[\]\\]/g, '\\$&');
  return new RegExp(`^${escaped.replace(/\*/g, '.*').replace(/\?/g, '.')}$`);
}

function matchesAny(compiled, value) {
  return value != null && compiled.some((re) => re.test(value));
}

export class Rules {
  constructor(path) {
    this.path = path;
    this.load();
  }

  load() {
    const raw = parse(readFileSync(this.path, 'utf8')) ?? {};
    const announcement = raw.announcement ?? {};
    const safety = raw.safety ?? {};

    this.config = {
      media: announcement.media ?? 'sound:custom/recording-notice',
      intervalSeconds: Number(announcement.interval_seconds ?? 30),
      initialDelaySeconds: Number(announcement.initial_delay_seconds ?? 3),
      maxDurationSeconds: Number(announcement.max_duration_seconds ?? 0),
      enabled: announcement.enabled === true,
    };

    this.excludeDialed = (safety.exclude_dialed ?? []).map(globToRegExp);

    log.info('rules loaded', {
      path: this.path,
      enabled: this.config.enabled,
      exclusions: this.excludeDialed.length,
      intervalSeconds: this.config.intervalSeconds,
    });
    return this.config;
  }

  /**
   * Every call routed through this box is in scope -- selection is done upstream
   * by the NetSapiens dial rule. The only reasons not to announce are the master
   * switch being off, or the destination being one we must never talk over.
   *
   * Returns { announce, reason }; the reason is surfaced in the operator UI so
   * it is obvious why a given call was or was not picked up.
   */
  evaluate({ dialed }) {
    if (this.isBlockedDestination(dialed)) {
      const d = (dialed ?? '').trim();
      return {
        announce: false,
        reason: EMERGENCY.has(d) ? 'emergency destination' : 'destination excluded',
      };
    }
    if (!this.config.enabled) {
      return { announce: false, reason: 'announcements disabled' };
    }
    return { announce: true, reason: 'routed through announcer' };
  }

  /** Blocked destinations cannot be announced even by a manual operator start. */
  isBlockedDestination(dialed) {
    const d = (dialed ?? '').trim();
    return EMERGENCY.has(d) || matchesAny(this.excludeDialed, d);
  }
}

/**
 * Best-effort identification of the originating user, for DISPLAY in the
 * operator UI only -- it no longer affects whether a call is announced.
 * NetSapiens puts the originating identity in P-Asserted-Identity, falling back
 * to From; both are SIP URIs like `"Name" <sip:1001@domain>`.
 */
export function extractExtension({ pai, from, callerNumber }) {
  for (const header of [pai, from]) {
    if (!header) continue;
    const match = header.match(/sips?:([^@>;\s]+)@/i);
    if (match) return match[1];
  }
  return callerNumber || null;
}

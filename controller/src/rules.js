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

function compileList(patterns) {
  return (patterns ?? []).map(globToRegExp);
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
    const matching = raw.matching ?? {};

    this.config = {
      media: announcement.media ?? 'sound:custom/recording-notice',
      intervalSeconds: Number(announcement.interval_seconds ?? 30),
      initialDelaySeconds: Number(announcement.initial_delay_seconds ?? 3),
      maxDurationSeconds: Number(announcement.max_duration_seconds ?? 0),
      enabled: matching.enabled === true,
    };

    this.extensions = compileList(matching.extensions);
    this.dialed = compileList(matching.dialed);
    this.excludeDialed = compileList(matching.exclude_dialed);

    log.info('rules loaded', {
      path: this.path,
      enabled: this.config.enabled,
      extensions: (matching.extensions ?? []).length,
      intervalSeconds: this.config.intervalSeconds,
    });
    return this.config;
  }

  /**
   * Decide whether a call should be announced automatically.
   * Returns { announce: boolean, reason: string } -- the reason is surfaced in
   * the operator UI so it is obvious why a given call was or was not picked up.
   */
  evaluate({ extension, dialed }) {
    const normalizedDialed = (dialed ?? '').trim();

    if (EMERGENCY.has(normalizedDialed)) {
      return { announce: false, reason: 'emergency destination' };
    }
    if (matchesAny(this.excludeDialed, normalizedDialed)) {
      return { announce: false, reason: 'destination excluded' };
    }
    if (!this.config.enabled) {
      return { announce: false, reason: 'matching disabled' };
    }
    if (!matchesAny(this.extensions, extension)) {
      return { announce: false, reason: `extension ${extension ?? 'unknown'} not in scope` };
    }
    if (this.dialed.length > 0 && !matchesAny(this.dialed, normalizedDialed)) {
      return { announce: false, reason: 'destination not in scope' };
    }
    return { announce: true, reason: `extension ${extension} in scope` };
  }

  /** Emergency destinations are blocked even for manual operator starts. */
  isBlockedDestination(dialed) {
    const d = (dialed ?? '').trim();
    return EMERGENCY.has(d) || matchesAny(this.excludeDialed, d);
  }
}

/**
 * NetSapiens identifies the originating user in P-Asserted-Identity, falling
 * back to From. Both are SIP URIs like `"Name" <sip:1001@domain>`; we want the
 * user part. Whether NetSapiens sends the extension or the company DID here is
 * platform-dependent and must be confirmed against a real INVITE.
 */
export function extractExtension({ pai, from, callerNumber }) {
  for (const header of [pai, from]) {
    if (!header) continue;
    const match = header.match(/sips?:([^@>;\s]+)@/i);
    if (match) return match[1];
  }
  return callerNumber || null;
}

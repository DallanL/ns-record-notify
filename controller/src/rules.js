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

const DTMF_CHARS = /^[0-9*#A-Da-d]*$/;

/**
 * Environment overrides for the handful of settings that belong to a deployment
 * rather than to policy. An env var that is DEFINED wins, even when empty --
 * that is how DTMF_STOP_DIGITS= disables the feature without editing YAML.
 *
 * Unlike config/rules.yaml these are read at startup only, so changing one needs
 * a container restart rather than POST /api/reload.
 */
function envOverride(name, fallback, parse) {
  if (!(name in process.env)) return { value: fallback, source: 'rules.yaml' };
  const parsed = parse(process.env[name]);
  if (parsed === null) {
    log.warn(`ignoring invalid ${name}, falling back to rules.yaml`, { value: process.env[name] });
    return { value: fallback, source: 'rules.yaml (invalid env)' };
  }
  return { value: parsed, source: name };
}

const asSeconds = (raw) => {
  const n = Number(raw);
  return Number.isFinite(n) && n >= 0 ? n : null;
};

const asDigits = (raw) => (DTMF_CHARS.test(raw) ? raw : null);

const asAcceptFrom = (raw) => (['caller', 'callee', 'any'].includes(raw) ? raw : null);

export class Rules {
  constructor(path) {
    this.path = path;
    this.load();
  }

  load() {
    const raw = parse(readFileSync(this.path, 'utf8')) ?? {};
    const announcement = raw.announcement ?? {};
    const safety = raw.safety ?? {};
    const dtmf = raw.dtmf_stop ?? {};

    const interval = envOverride('ANNOUNCE_INTERVAL_SECONDS',
      Number(announcement.interval_seconds ?? 30), asSeconds);
    const initialDelay = envOverride('ANNOUNCE_INITIAL_DELAY_SECONDS',
      Number(announcement.initial_delay_seconds ?? 3), asSeconds);
    const digits = envOverride('DTMF_STOP_DIGITS',
      String(dtmf.digits ?? ''), asDigits);
    const acceptFrom = envOverride('DTMF_ACCEPT_FROM',
      ['caller', 'callee', 'any'].includes(dtmf.accept_from) ? dtmf.accept_from : 'any',
      asAcceptFrom);

    this.config = {
      media: announcement.media ?? 'sound:custom/recording-notice',
      intervalSeconds: interval.value,
      initialDelaySeconds: initialDelay.value,
      maxDurationSeconds: Number(announcement.max_duration_seconds ?? 0),
      enabled: announcement.enabled === true,
      dtmfDigits: digits.value,
      dtmfAcceptFrom: acceptFrom.value,
      dtmfTimeoutSeconds: Number(dtmf.sequence_timeout_seconds ?? 5),
    };
    this.sources = {
      intervalSeconds: interval.source,
      initialDelaySeconds: initialDelay.source,
      dtmfDigits: digits.source,
      dtmfAcceptFrom: acceptFrom.source,
    };

    this.excludeDialed = (safety.exclude_dialed ?? []).map(globToRegExp);

    // Log where each overridable value came from -- with two possible sources,
    // "why is my YAML edit not taking effect" is otherwise a guessing game.
    log.info('rules loaded', {
      path: this.path,
      enabled: this.config.enabled,
      exclusions: this.excludeDialed.length,
      initialDelaySeconds: `${this.config.initialDelaySeconds} (${this.sources.initialDelaySeconds})`,
      intervalSeconds: `${this.config.intervalSeconds} (${this.sources.intervalSeconds})`,
      dtmfStop: `${this.config.dtmfDigits || '(disabled)'} (${this.sources.dtmfDigits})`,
      dtmfAcceptFrom: `${this.config.dtmfAcceptFrom} (${this.sources.dtmfAcceptFrom})`,
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

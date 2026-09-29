import { createHash, timingSafeEqual } from 'node:crypto';

/**
 * Access control for the operator UI and API.
 *
 * The API can stop announcements on live calls, so on anything but loopback it
 * must not be open. Rather than trust the deployer to remember, the controller
 * refuses to bind a non-loopback address without credentials (see exposureError)
 * -- a wrong setting is a startup failure, not a silent hole.
 */

const LOOPBACK = new Set(['127.0.0.1', '::1', 'localhost']);
const MIN_PASSWORD = 12;

export const isLoopback = (host) => LOOPBACK.has(String(host).toLowerCase());

/** Credentials from the environment, or null if none are configured. */
export function authFromEnv(env = process.env) {
  const user = env.WEB_USER ?? '';
  const pass = env.WEB_PASS ?? '';
  if (!user && !pass) return null;
  if (!user || !pass) throw new Error('WEB_USER and WEB_PASS must be set together');
  if (pass.length < MIN_PASSWORD) {
    throw new Error(`WEB_PASS must be at least ${MIN_PASSWORD} characters`);
  }
  return { user, pass };
}

/** A reason the requested bind address is unsafe, or null if it is fine. */
export function exposureError(host, auth) {
  if (isLoopback(host) || auth) return null;
  return (
    `refusing to serve the operator UI on ${host} without authentication: it can stop ` +
    'announcements on live calls. Set WEB_USER and WEB_PASS, or bind WEB_HOST=127.0.0.1 ' +
    'and reach it through an SSH tunnel.'
  );
}

// Compare digests, not the strings: timingSafeEqual needs equal lengths, and
// hashing first means neither the length nor the content of the real credential
// is observable through response timing.
const digest = (v) => createHash('sha256').update(String(v)).digest();
const same = (a, b) => timingSafeEqual(digest(a), digest(b));

/** HTTP Basic auth. /api/health stays open so the container healthcheck works. */
export function basicAuth({ user, pass }) {
  return (req, res, next) => {
    if (req.path === '/api/health') return next();
    const [scheme, encoded] = (req.headers.authorization ?? '').split(' ');
    if (scheme === 'Basic' && encoded) {
      const decoded = Buffer.from(encoded, 'base64').toString('utf8');
      const i = decoded.indexOf(':');
      // Both comparisons always run, so a wrong username is not faster than a
      // wrong password.
      const userOk = same(i < 0 ? decoded : decoded.slice(0, i), user);
      const passOk = same(i < 0 ? '' : decoded.slice(i + 1), pass);
      if (userOk && passOk) return next();
    }
    res.set('WWW-Authenticate', 'Basic realm="ns-record-notify", charset="UTF-8"');
    res.status(401).type('text/plain').send('authentication required');
  };
}

/**
 * Basic auth is attached to cross-site requests by the browser automatically,
 * so without this any web page the operator visits could submit a form to
 * "stop all announcements". Browsers always send Origin on such a POST; scripts
 * like curl do not, and are unaffected.
 */
export function sameOriginOnly(req, res, next) {
  if (['GET', 'HEAD', 'OPTIONS'].includes(req.method)) return next();
  const origin = req.headers.origin;
  if (origin) {
    let host = null;
    try { host = new URL(origin).host; } catch { /* malformed Origin is rejected below */ }
    if (host !== req.headers.host) {
      return res.status(403).type('text/plain').send('cross-origin request refused');
    }
  }
  next();
}

export function securityHeaders(_req, res, next) {
  res.set({
    'X-Content-Type-Options': 'nosniff',
    'X-Frame-Options': 'DENY',            // the UI has a "stop all" button: no clickjacking
    'Referrer-Policy': 'no-referrer',
    'Cache-Control': 'no-store',
  });
  next();
}

import { Ari } from './ari.js';
import { Rules } from './rules.js';
import { CallRegistry } from './calls.js';
import { createServer, listen } from './web.js';
import { log } from './log.js';

const ariBaseUrl = process.env.ARI_URL ?? `http://127.0.0.1:${process.env.ARI_PORT ?? 8088}`;
const rulesPath = process.env.RULES_PATH ?? '/config/rules.yaml';
const webPort = Number(process.env.WEB_PORT ?? 8080);
const webHost = process.env.WEB_HOST ?? '127.0.0.1';

const rules = new Rules(rulesPath);

const ari = new Ari({
  baseUrl: ariBaseUrl,
  username: process.env.ARI_USER ?? 'announcer',
  password: process.env.ARI_PASS ?? '',
  app: 'announcer',
});

const registry = new CallRegistry({ ari, rules });
registry.attach();
ari.connect();

let server;
try {
  server = await listen(createServer({ registry, rules }), webPort, webHost);
} catch {
  // listen() has already logged what is wrong and how to fix it; a stack trace
  // on top of that only obscures it.
  ari.close();
  process.exit(1);
}

process.on('SIGHUP', () => {
  log.info('SIGHUP received, reloading rules');
  try {
    rules.load();
  } catch (err) {
    log.error('rules reload failed, keeping previous config', { message: err.message });
  }
});

async function shutdown(signal) {
  log.info(`${signal} received, shutting down`);
  // Stop every announcement before exiting -- otherwise snoop channels are left
  // attached to live calls with nothing driving or cleaning them up.
  await registry.stopAll().catch(() => {});
  ari.close();
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 5000).unref();
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

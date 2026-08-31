import express from 'express';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { log } from './log.js';

const publicDir = join(dirname(fileURLToPath(import.meta.url)), '..', 'public');

export function createServer({ registry, rules }) {
  const app = express();
  app.use(express.json());
  app.use(express.static(publicDir));

  const handle = (fn) => async (req, res) => {
    try {
      res.json(await fn(req));
    } catch (err) {
      res.status(err.status ?? 500).json({ error: err.message });
    }
  };

  app.get('/api/health', (_req, res) => res.json({ ok: true, calls: registry.calls.size }));

  app.get('/api/calls', handle(async () => ({
    calls: registry.list(),
    config: {
      enabled: rules.config.enabled,
      intervalSeconds: rules.config.intervalSeconds,
      media: rules.config.media,
    },
  })));

  app.post('/api/calls/:id/announce/start', handle((req) => registry.startAnnouncement(req.params.id)));
  app.post('/api/calls/:id/announce/stop', handle((req) => registry.stopAnnouncement(req.params.id)));
  app.post('/api/announce/stop-all', handle(() => registry.stopAll()));

  app.post('/api/reload', handle(async () => {
    const config = rules.load();
    // Live calls hold a reference to the config object, so replacing its
    // contents rather than the object keeps running announcements consistent.
    return { ok: true, config };
  }));

  return app;
}

export function listen(app, port, host) {
  return new Promise((resolve) => {
    const server = app.listen(port, host, () => {
      log.info('operator UI listening', { host, port });
      resolve(server);
    });
  });
}

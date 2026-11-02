import { B1Authority, authorityConfig } from './authority.mjs';
import { createHandler } from './http.mjs';

const apps = new WeakSet();
export function isB1App(value) { return apps.has(value); }
export function createApp(config) {
  const validated = authorityConfig(config);
  const authority = new B1Authority(validated);
  const { handler, close: closeHandler } = createHandler(authority, validated.limits);
  let closed = false;
  const app = Object.freeze({
    mode: 'SYNTHETIC_FIXTURE_ONLY',
    storeKind: validated.db.kind,
    handler,
    bindOrigin: origin => authority.bindOrigin(origin),
    revokeInstallation: input => authority.revokeInstallation(input),
    close: async () => { if (!closed) { closed = true; closeHandler(); await authority.close(); } },
  });
  apps.add(app);
  return app;
}

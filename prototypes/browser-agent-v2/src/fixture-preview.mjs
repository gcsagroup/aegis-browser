import { fileURLToPath } from 'node:url';
import { createRunContext } from './run-context.mjs';
import { startFixtureServer } from './fixture-server.mjs';

export async function startFixturePreview() {
  const context = createRunContext({ scenarioId: 'E0', candidate: 'fixture-preview' });
  const fixture = await startFixtureServer({ runRoot: context.runRoot, secure: false });
  process.stdout.write(`${JSON.stringify({ origin: fixture.origin, runRoot: context.runRoot })}\n`);
  const stop = async () => {
    await fixture.close();
    process.exit(0);
  };
  process.once('SIGINT', stop);
  process.once('SIGTERM', stop);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  startFixturePreview().catch((error) => {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  });
}

import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const setup = await readFile(new URL('../site/setup.sh', import.meta.url), 'utf8');
const source = (await readFile(new URL('../site/worker.js', import.meta.url), 'utf8'))
  .replace("import setup from './setup.sh';", `const setup = ${JSON.stringify(setup)};`);
const { default: worker } = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
for (const [path, method, status, body] of [
  ['/', 'GET', 200, 'curl -fsSL https://setup.toni.foo/setup.sh | sudo bash\n'],
  ['/setup.sh', 'GET', 200, setup],
  ['/setup.sh', 'HEAD', 200, ''],
  ['/secret', 'GET', 404, 'Not found\n'],
  ['/', 'POST', 405, 'Method not allowed\n'],
]) {
  const response = worker.fetch(new Request(`https://setup.toni.foo${path}`, { method }));
  assert.equal(response.status, status);
  assert.equal(await response.text(), body);
  if (status === 200) assert.equal(response.headers.get('Content-Type'), 'text/plain; charset=utf-8');
}
console.log('Worker tests passed: exact plain-text responses, HEAD, 404 and 405.');

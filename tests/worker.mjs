import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createServer, request as httpRequest } from 'node:http';
import { Miniflare, convertV4MiniflareOptions } from 'miniflare';

let forwarded = 0, upstreamStatus = 201, received;
const origin = createServer(async (request, response) => {
  forwarded++;
  assert.equal(request.url, '/upload');
  assert.equal(request.headers.authorization, 'Bearer 0007');
  if (upstreamStatus !== 201) {
    response.writeHead(upstreamStatus, { Location: '/never-follow' });
    response.end('Rejected');
    return;
  }
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  received = Buffer.concat(chunks);
  assert.equal(request.headers['content-length'], String(received.length));
  assert.equal(request.headers['transfer-encoding'], undefined);
  response.writeHead(201, { 'Content-Type': 'application/json' });
  response.end('{"id":"fixture","sha256":"test"}');
});
await new Promise(resolve => origin.listen(0, '127.0.0.1', resolve));
let source = await readFile(new URL('../site/worker.js', import.meta.url), 'utf8');
const assets = {};
for (const [name, file, path] of [['setup', 'setup.sh', '/setup.sh'], ['cleanup', 'cleanup.sh', '/cleanup.sh'], ['upload', 'school-upload.sh', '/school-upload']]) {
  const text = await readFile(new URL('../site/' + file, import.meta.url), 'utf8');
  assets[path] = text;
  source = source.replace(`import ${name} from './${file}';`, `const ${name} = ${JSON.stringify(text)};`);
}
source = source.replace('https://school-backup-origin.toni.foo/upload', `http://127.0.0.1:${origin.address().port}/upload`);
const mf = new Miniflare(convertV4MiniflareOptions({ modules: true, script: source, compatibilityDate: '2026-10-06' }));
const request = (path, options) => mf.dispatchFetch('https://setup.toni.foo' + path, options);
try {
  for (const [path, text] of Object.entries(assets)) {
    const response = await request(path);
    assert.equal(response.status, 200);
    assert.equal(await response.text(), text);
    assert.equal(response.headers.get('Cache-Control'), 'no-store');
    assert.equal((await request(path, { method: 'HEAD' })).status, 200);
  }
  const root = await (await request('/')).text();
  assert(root.startsWith('curl -fsSL https://setup.toni.foo/setup.sh | sudo bash\n'));
  assert(root.includes('# curl -fsSL https://setup.toni.foo/cleanup.sh | sudo bash'));
  assert.equal((await request('/secret')).status, 404);
  assert.equal((await request('/', { method: 'POST' })).status, 405);
  assert.equal((await request('/backup')).status, 405);
  assert.equal((await request('/backup', { method: 'POST', body: 'x' })).status, 401);
  const payload = Buffer.from([31, 139, 0, 1, 2, 3]);
  const headers = { Authorization: 'Bearer 0007', 'Content-Type': 'application/gzip', 'Content-Length': String(payload.length) };
  const runtimeURL = await mf.ready;
  const oversized = await new Promise((resolve, reject) => {
    const req = httpRequest(new URL('/backup', runtimeURL), { method: 'POST', headers: { ...headers, 'Content-Length': '83886081' } }, response => {
      response.resume();
      resolve(response.statusCode);
      req.destroy();
    });
    req.on('error', reject);
    req.flushHeaders();
  });
  assert.equal(oversized, 413);
  assert.equal((await request('/backup', { method: 'POST', headers: { ...headers, 'Content-Type': 'text/plain' }, body: payload })).status, 400);
  assert.equal(forwarded, 0);
  const response = await request('/backup', { method: 'POST', headers, body: payload });
  assert.equal(response.status, 201);
  assert.deepEqual(received, payload);
  assert.equal((await response.json()).id, 'fixture');
  for (const [status, expected] of [[401, 401], [429, 429], [507, 507], [302, 502]]) {
    upstreamStatus = status;
    assert.equal((await request('/backup', { method: 'POST', headers, body: payload })).status, expected);
  }
  assert.equal(forwarded, 5);
  console.log('Worker/workerd passed: scripts, guards, actual fixed-length HTTP relay, rejection and no redirect.');
} finally {
  await mf.dispose();
  await new Promise(resolve => origin.close(resolve));
}

import setup from './setup.sh';
import cleanup from './cleanup.sh';
import upload from './school-upload.sh';

const command = 'curl -fsSL https://setup.toni.foo/setup.sh | sudo bash\n\n# Cleanup (requires typing DELETE):\n# curl -fsSL https://setup.toni.foo/cleanup.sh | sudo bash\n';
const textHeaders = { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' };
const json = (status, error) => new Response(JSON.stringify({ error }), { status, headers: { ...textHeaders, 'Content-Type': 'application/json' } });

export default {
  async fetch(request, env, ctx) {
    const path = new URL(request.url).pathname;
    if (path === '/backup') {
      if (request.method !== 'POST') return json(405, 'Upload only.');
      const authorization = request.headers.get('Authorization') ?? '';
      if (!/^Bearer [0-9]{4}$/.test(authorization)) return json(401, 'Supply a current upload code.');
      const length = request.headers.get('Content-Length') ?? '';
      if (!/^[0-9]+$/.test(length) || Number(length) < 1 || Number(length) > 80 * 1024 * 1024) return json(413, 'Maximum archive size: 80 MiB.');
      if (request.headers.get('Content-Type') !== 'application/gzip' || request.headers.has('Content-Encoding') || !request.body) return json(400, 'Expected a gzip archive.');
      const controller = new AbortController();
      // Workers derives Content-Length from FixedLengthStream, not a supplied header.
      const stream = new FixedLengthStream(Number(length));
      const pumping = request.body.pipeTo(stream.writable, { signal: controller.signal });
      ctx.waitUntil(pumping.catch(() => {}));
      try {
        const response = await fetch('https://school-backup-origin.toni.foo/upload', {
          method: 'POST', body: stream.readable, redirect: 'manual', signal: controller.signal,
          headers: { Authorization: authorization, 'Content-Type': 'application/gzip' },
        });
        if (response.status !== 201) {
          controller.abort();
          const status = [400, 401, 413, 429, 503, 507].includes(response.status) ? response.status : 502;
          return json(status, status === 401 ? 'Code invalid, expired, locked or already used.' : `Upload rejected (${status}). Local files were not deleted.`);
        }
        await pumping;
        return new Response(response.body, { status: 201, headers: { ...textHeaders, 'Content-Type': 'application/json' } });
      } catch {
        controller.abort();
        return json(502, 'Upload interrupted. Local files were not deleted.');
      }
    }
    if (!['GET', 'HEAD'].includes(request.method)) return new Response('Method not allowed\n', { status: 405, headers: { Allow: 'GET, HEAD' } });
    const assets = { '/': command, '/setup.sh': setup, '/cleanup.sh': cleanup, '/school-upload': upload };
    const body = assets[path] ?? null;
    return new Response(request.method === 'HEAD' ? null : body ?? 'Not found\n', { status: body === null ? 404 : 200, headers: textHeaders });
  },
};

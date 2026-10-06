import setup from './setup.sh';

export default {
  fetch(request) {
    const path = new URL(request.url).pathname;
    const body = path === '/' ? 'curl -fsSL https://setup.toni.foo/setup.sh | sudo bash\n' : path === '/setup.sh' ? setup : null;
    if (!['GET', 'HEAD'].includes(request.method)) {
      return new Response('Method not allowed\n', { status: 405, headers: { Allow: 'GET, HEAD' } });
    }
    return new Response(request.method === 'HEAD' ? null : body ?? 'Not found\n', {
      status: body === null ? 404 : 200,
      headers: {
        'Content-Type': 'text/plain; charset=utf-8',
        'Cache-Control': 'no-store',
        'X-Content-Type-Options': 'nosniff',
      },
    });
  },
};

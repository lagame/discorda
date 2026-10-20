import { describe, expect, it } from 'vitest';
import { listenForLogin } from '../../src/main/auth/loopback';
import { createServer, request } from 'node:http';

describe('OAuth callback boundary', () => {
  it('uses the fallback port when the primary port is occupied', async () => {
    const occupied = createServer();
    await new Promise<void>(resolve => occupied.listen(0, '127.0.0.1', resolve));
    const address = occupied.address();
    if (!address || typeof address === 'string') throw new Error('Expected a TCP listener');
    try {
      const login = await listenForLogin(new AbortController().signal, address.port, 3000, 0);
      try {
        expect(new URL(login.redirectTo).port).not.toBe(String(address.port));
        expect((await fetch(login.redirectTo + '?code=fallback-code')).status).toBe(200);
        expect(await login.code).toBe('fallback-code');
      } finally { login.close(); }
    } finally { occupied.close(); }
  });
  it('reports when both callback ports are occupied', async () => {
    const primary = createServer();
    const fallback = createServer();
    await new Promise<void>(resolve => primary.listen(0, '127.0.0.1', resolve));
    await new Promise<void>(resolve => fallback.listen(0, '127.0.0.1', resolve));
    const primaryAddress = primary.address();
    const fallbackAddress = fallback.address();
    if (!primaryAddress || typeof primaryAddress === 'string' || !fallbackAddress || typeof fallbackAddress === 'string') throw new Error('Expected TCP listeners');
    try {
      await expect(listenForLogin(new AbortController().signal, primaryAddress.port, 3000, fallbackAddress.port))
        .rejects.toThrow('As portas locais de login estão ocupadas.');
    } finally { primary.close(); fallback.close(); }
  });
  it('rejects malformed request targets without crashing or consuming the pending login', async () => {
    const login = await listenForLogin(new AbortController().signal, 0, 3000);
    try {
      const origin = new URL(login.redirectTo);
      const status = await new Promise<number | undefined>((resolve, reject) => {
        const req = request({hostname: origin.hostname, port: origin.port, path: '//['}, response => {response.resume();resolve(response.statusCode);});
        req.on('error', reject); req.end();
      });
      expect(status).toBe(400);
      await fetch(login.redirectTo+'?code=valid-code');
      expect(await login.code).toBe('valid-code');
    } finally { login.close(); }
  });
  it('does not consume a login for wrong paths, POST requests or missing codes', async () => {
    const login = await listenForLogin(new AbortController().signal, 0, 3000);
    try {
      const wrong = new URL(login.redirectTo); wrong.pathname = '/redirect/wrong';
      expect((await fetch(wrong)).status).toBe(404);
      expect((await fetch(login.redirectTo, { method: 'POST' })).status).toBe(403);
      expect((await fetch(login.redirectTo)).status).toBe(400);
      const response = await fetch(login.redirectTo + '?code=test-code');
      expect(response.headers.get('cache-control')).toBe('no-store');
      expect(await login.code).toBe('test-code');
    } finally { login.close(); }
  });
  it('rejects duplicated codes and cross-origin requests', async () => {
    const login = await listenForLogin(new AbortController().signal, 0, 3000);
    try {
      expect((await fetch(login.redirectTo + '?code=a&code=b')).status).toBe(400);
      expect((await fetch(login.redirectTo + '?code=a', { headers: { Origin: 'https://evil.test' } })).status).toBe(403);
      await fetch(login.redirectTo + '?error=access_denied&error_description=untrusted');
      await expect(login.code).rejects.toThrow('O login não foi concluído.');
    } finally { login.close(); }
  });
  it('cancels and releases the callback listener', async () => {
    const controller = new AbortController();
    const login = await listenForLogin(controller.signal, 0, 3000);
    controller.abort();
    await expect(login.code).rejects.toThrow('Login cancelado.');
  });
  it('expires unfinished attempts', async () => {
    const login = await listenForLogin(new AbortController().signal, 0, 20);
    await expect(login.code).rejects.toThrow('O tempo para entrar terminou.');
  });
});

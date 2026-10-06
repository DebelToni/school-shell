import concurrent.futures
import gzip
import hashlib
import http.client
import json
import socket
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

from backup.server import BoundedServer, MAX_BYTES, PrivateHandler, Rejected, Store, UploadHandler


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.store = Store(Path(self.tmp.name) / 'state', Path(self.tmp.name) / 'archives')
        self.now = time.time()

    def test_single_use_and_leading_zeroes(self):
        with patch('backup.server.secrets.randbelow', return_value=7):
            code = self.store.mint()['code']
        self.assertEqual(code, '0007')
        self.store.claim(code, 100)
        with self.assertRaises(Rejected):
            self.store.claim(code, 100)

    def test_expiry(self):
        with patch('backup.server.time.time', return_value=self.now):
            code = self.store.mint()['code']
        with patch('backup.server.time.time', return_value=self.now + 15):
            with self.assertRaises(Rejected):
                self.store.claim(code, 100)

    def test_mint_cooldown_and_daily_limit_survive_restart(self):
        for offset in (0, 60, 120):
            with patch('backup.server.time.time', return_value=self.now + offset):
                self.store.mint()
                with self.assertRaises(Rejected):
                    self.store.mint()
        store = Store(self.store.state, self.store.archives)
        with patch('backup.server.time.time', return_value=self.now + 180):
            with self.assertRaises(Rejected):
                store.mint()

    def test_three_failed_guesses_lock_code(self):
        code = self.store.mint()['code']
        wrong = '1111' if code != '1111' else '2222'
        for _ in range(3):
            with self.assertRaises(Rejected):
                self.store.claim(wrong, 100)
        with self.assertRaises(Rejected):
            self.store.claim(code, 100)

    def test_global_attempt_cap(self):
        for _ in range(6):
            with self.assertRaises(Rejected):
                self.store.claim('0000', 100)
        with self.assertRaises(Rejected) as error:
            self.store.claim('0000', 100)
        self.assertEqual(error.exception.status, 429)

    def test_size_and_storage_limits(self):
        code = self.store.mint()['code']
        for size in (0, MAX_BYTES + 1):
            with self.assertRaises(Rejected):
                self.store.claim(code, size)
        with patch('backup.server.MAX_STORAGE', 100):
            with self.assertRaises(Rejected) as error:
                self.store.claim(code, 101)
            self.assertEqual(error.exception.status, 507)

    def test_concurrent_claim_only_one_success(self):
        code = self.store.mint()['code']
        def attempt():
            try:
                return self.store.claim(code, 100)
            except Rejected:
                return None
        with concurrent.futures.ThreadPoolExecutor(4) as pool:
            results = list(pool.map(lambda _: attempt(), range(4)))
        self.assertEqual(sum(x is not None for x in results), 1)

    def test_hourly_limit_and_reserved_storage(self):
        code = self.store.mint()['code']
        with self.store.connect() as db:
            for i in range(3):
                db.execute('INSERT INTO uploads VALUES (?,?,1,\'failed\',\'\')', (str(i), self.now))
        with self.assertRaises(Rejected) as error:
            self.store.claim(code, 10)
        self.assertEqual(error.exception.status, 429)
        with self.store.connect() as db:
            db.execute('DELETE FROM uploads')
            db.execute('INSERT INTO uploads VALUES (\'reserved\',?,40,\'receiving\',\'\')', (self.now,))
        (self.store.archives / 'existing.tar.gz').write_bytes(b'x' * 30)
        with patch('backup.server.MAX_STORAGE', 100):
            with self.assertRaises(Rejected) as error:
                self.store.claim(code, 40)
            self.assertEqual(error.exception.status, 507)
            self.store.finish('reserved', 'failed')
            self.assertIsNotNone(self.store.claim(code, 40))

    def test_interrupted_reservations_recovered(self):
        code = self.store.mint()['code']
        upload = self.store.claim(code, 100)
        part = self.store.archives / (upload + '.part')
        part.write_bytes(b'partial')
        self.store.recover()
        self.assertFalse(part.exists())
        with self.store.connect() as db:
            self.assertEqual(db.execute('SELECT status FROM uploads').fetchone()[0], 'failed')


class HttpTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.store = Store(Path(self.tmp.name) / 'state', Path(self.tmp.name) / 'archives')
        self.origin = 'https://phone.example.invalid'
        self.private = self.start(PrivateHandler)
        self.public = self.start(UploadHandler)

    def start(self, handler):
        server = BoundedServer(('127.0.0.1', 0), handler, self.store, self.origin)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return server

    def request(self, server, method, path, body=None, headers=None):
        conn = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=5)
        self.addCleanup(conn.close)
        conn.request(method, path, body, headers or {})
        response = conn.getresponse()
        return response.status, response.read()

    def mint(self):
        status, body = self.request(self.private, 'POST', '/api/code', b'{}', {
            'Host': 'phone.example.invalid', 'Origin': self.origin, 'Content-Type': 'application/json', 'Tailscale-User-Login': 'owner@example.invalid'})
        self.assertEqual(status, 200)
        return json.loads(body)['code']

    def test_private_mint_csrf_and_public_api_separation(self):
        status, _ = self.request(self.private, 'POST', '/api/code', b'{}', {
            'Host': 'phone.example.invalid', 'Origin': 'https://attacker.invalid', 'Content-Type': 'application/json', 'Tailscale-User-Login': 'owner@example.invalid'})
        self.assertEqual(status, 403)
        self.assertEqual(self.store.status()['remaining'], 3)
        for path in ('/api/code', '/api/status', '/some/archive.tar.gz'):
            self.assertEqual(self.request(self.public, 'GET', path)[0], 405)
            self.assertEqual(self.request(self.public, 'POST', path, b'{}')[0], 404)

    def test_private_prefixed_routes_and_readonly_health(self):
        status, body = self.request(self.private, 'GET', '/x/school-backup/', headers={'Host': 'phone.example.invalid', 'Tailscale-User-Login': 'owner@example.invalid'})
        self.assertEqual(status, 200)
        self.assertIn(b'Generate upload code', body)
        self.assertEqual(self.request(self.private, 'GET', '/health')[0], 200)
        self.assertEqual(self.store.status()['remaining'], 3)

    def test_owner_identity_required(self):
        for identity in ('', 'other@example.invalid'):
            headers = {'Origin': self.origin, 'Content-Type': 'application/json', 'Tailscale-User-Login': identity}
            self.assertEqual(self.request(self.private, 'GET', '/api/status', headers=headers)[0], 403)
            self.assertEqual(self.request(self.private, 'POST', '/api/code', b'{}', headers)[0], 403)
        self.assertEqual(self.store.status()['remaining'], 3)

    def test_chunked_or_encoded_upload_rejected(self):
        for extra in ({'Transfer-Encoding': 'chunked'}, {'Content-Encoding': 'gzip'}):
            self.assertEqual(self.request(self.public, 'POST', '/upload', b'xx', {'Content-Type': 'application/gzip'} | extra)[0], 400)

    def test_fragmented_magic_and_deadline(self):
        code = self.mint()
        payload = gzip.compress(b'fragmented')
        with socket.create_connection(('127.0.0.1', self.public.server_port), timeout=5) as conn:
            conn.sendall((f'POST /upload HTTP/1.0\r\nContent-Type: application/gzip\r\nContent-Length: {len(payload)}\r\nAuthorization: Bearer {code}\r\n\r\n').encode())
            conn.sendall(payload[:1])
            time.sleep(.03)
            conn.sendall(payload[1:])
            result = conn.recv(4096)
            self.assertIn(b'201', result.split(b'\r\n')[0])
        with patch('backup.server.time.time', return_value=time.time() + 61):
            code = self.store.mint()['code']
            with patch('backup.server.time.monotonic', side_effect=[0, 301]):
                status, _ = self.request(self.public, 'POST', '/upload', payload, {'Content-Type': 'application/gzip', 'Authorization': 'Bearer ' + code})
        self.assertEqual(status, 400)
        self.assertFalse(list(self.store.archives.glob('*.part')))

    def test_upload_opaque_archive_and_checksum(self):
        code = self.mint()
        payload = gzip.compress(b'opaque home archive fixture')
        status, body = self.request(self.public, 'POST', '/upload', payload, {
            'Content-Type': 'application/gzip', 'Authorization': 'Bearer ' + code})
        self.assertEqual(status, 201)
        receipt = json.loads(body)
        self.assertEqual(receipt['sha256'], hashlib.sha256(payload).hexdigest())
        saved = self.store.archives / (receipt['id'] + '.tar.gz')
        self.assertEqual(saved.read_bytes(), payload)
        self.assertEqual(saved.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.request(self.public, 'GET', '/upload/' + receipt['id'])[0], 405)

    def test_oversize_rejected_before_reading_body(self):
        self.assertEqual(self.request(self.public, 'POST', '/upload', b'', {
            'Content-Type': 'application/gzip', 'Content-Length': str(MAX_BYTES + 1)})[0], 413)

    def test_failed_body_not_kept_and_code_consumed(self):
        code = self.mint()
        headers = {'Content-Type': 'application/gzip', 'Authorization': 'Bearer ' + code}
        self.assertEqual(self.request(self.public, 'POST', '/upload', b'not gzip', headers)[0], 400)
        self.assertFalse(list(self.store.archives.iterdir()))
        self.assertEqual(self.request(self.public, 'POST', '/upload', gzip.compress(b'x'), headers)[0], 401)


if __name__ == '__main__':
    unittest.main()

"""Private code minting and bounded, upload-only opaque archive intake."""
from contextlib import contextmanager
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import socket
import sqlite3
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from zoneinfo import ZoneInfo

MAX_BYTES = 80 * 1024 * 1024
MAX_STORAGE = 20 * 1024 * 1024 * 1024
PANEL = Path(__file__).with_name('panel.html').read_bytes()


class Rejected(Exception):
    def __init__(self, status, message):
        self.status, self.message = status, message


class Store:
    def __init__(self, state, archives):
        self.state, self.archives = Path(state), Path(archives)
        self.state.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.archives.mkdir(parents=True, exist_ok=True, mode=0o700)
        key = self.state / 'code-hmac.key'
        if not key.exists():
            fd = os.open(key, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, 'wb') as output:
                output.write(secrets.token_bytes(32))
        self.key = key.read_bytes()
        self.db = self.state / 'state.sqlite3'
        with self.connect() as db:
            db.executescript('''
                CREATE TABLE IF NOT EXISTS code (
                    id INTEGER PRIMARY KEY CHECK(id=1), day TEXT, minted INTEGER,
                    last_mint REAL, digest TEXT, expires REAL, failures INTEGER, claimed INTEGER);
                INSERT OR IGNORE INTO code VALUES (1,'',0,0,'',0,0,1);
                CREATE TABLE IF NOT EXISTS attempts (minute INTEGER PRIMARY KEY, count INTEGER);
                CREATE TABLE IF NOT EXISTS uploads (
                    id TEXT PRIMARY KEY, created REAL, size INTEGER, status TEXT, sha256 TEXT);
            ''')

    @contextmanager
    def connect(self):
        db = sqlite3.connect(self.db, timeout=5)
        db.row_factory = sqlite3.Row
        try:
            with db:
                yield db
        finally:
            db.close()

    @staticmethod
    def day(now):
        import datetime
        return datetime.datetime.fromtimestamp(now, ZoneInfo('Europe/Sofia')).date().isoformat()

    def digest(self, code):
        return hmac.new(self.key, code.encode(), hashlib.sha256).hexdigest()

    def status(self):
        now = time.time()
        with self.connect() as db:
            row = db.execute('SELECT * FROM code WHERE id=1').fetchone()
        return {'remaining': 3 - (row['minted'] if row['day'] == self.day(now) else 0),
                'cooldown_s': max(0, int(row['last_mint'] + 60 - now + .999))}

    def mint(self):
        now = time.time()
        with self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            row = db.execute('SELECT * FROM code WHERE id=1').fetchone()
            count = row['minted'] if row['day'] == self.day(now) else 0
            if count >= 3 or now < row['last_mint'] + 60:
                raise Rejected(429, 'Code limit reached. Wait for the cooldown or the next day.')
            code = f'{secrets.randbelow(10000):04d}'
            db.execute('UPDATE code SET day=?,minted=?,last_mint=?,digest=?,expires=?,failures=0,claimed=0 WHERE id=1',
                       (self.day(now), count + 1, now, self.digest(code), now + 15))
        return {'code': code, 'expires_in': 15}

    def claim(self, code, size):
        now = time.time()
        if not 1 <= size <= MAX_BYTES:
            raise Rejected(413, 'Archive must be at most 80 MiB.')
        # Persist failures even when authentication is rejected.
        rejection = None
        upload_id = None
        with self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            minute = int(now // 60)
            db.execute('DELETE FROM attempts WHERE minute < ?', (minute - 2,))
            row = db.execute('SELECT count FROM attempts WHERE minute=?', (minute,)).fetchone()
            if row and row['count'] >= 6:
                rejection = Rejected(429, 'Try again later.')
            else:
                db.execute('INSERT INTO attempts VALUES (?,1) ON CONFLICT(minute) DO UPDATE SET count=count+1', (minute,))
                row = db.execute('SELECT * FROM code WHERE id=1').fetchone()
                active = not row['claimed'] and now < row['expires'] and row['failures'] < 3
                valid = bool(re.fullmatch(r'[0-9]{4}', code)) and hmac.compare_digest(self.digest(code), row['digest'])
                if not active or not valid:
                    if active:
                        db.execute('UPDATE code SET failures=failures+1 WHERE id=1')
                    rejection = Rejected(401, 'Invalid, expired or already used code.')
                elif db.execute('SELECT count(*) FROM uploads WHERE created > ?', (now - 3600,)).fetchone()[0] >= 3:
                    rejection = Rejected(429, 'Hourly upload limit reached.')
                else:
                    used = sum(p.stat().st_size for p in self.archives.glob('*.tar.gz'))
                    reserved = db.execute("SELECT coalesce(sum(size),0) FROM uploads WHERE status='receiving'").fetchone()[0]
                    if used + reserved + size > MAX_STORAGE:
                        rejection = Rejected(507, 'Backup storage is full. Contact the owner.')
                    else:
                        upload_id = time.strftime('%Y%m%dT%H%M%SZ', time.gmtime(now)) + '-' + secrets.token_hex(12)
                        db.execute('UPDATE code SET claimed=1 WHERE id=1')
                        db.execute('INSERT INTO uploads VALUES (?,?,?,\'receiving\',\'\')', (upload_id, now, size))
        if rejection:
            raise rejection
        return upload_id

    def finish(self, upload_id, status, digest=''):
        with self.connect() as db:
            db.execute('UPDATE uploads SET status=?,sha256=? WHERE id=?', (status, digest, upload_id))

    def recover(self):
        # Only startup may retire the interrupted writes from this service.
        with self.connect() as db:
            for row in db.execute("SELECT id FROM uploads WHERE status='receiving'"):
                part = self.archives / (row['id'] + '.part')
                part.unlink(missing_ok=True)
                completed = self.archives / (row['id'] + '.tar.gz')
                db.execute('UPDATE uploads SET status=? WHERE id=?', ('complete' if completed.exists() else 'failed', row['id']))


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.0'
    server_version = 'SchoolBackup'
    sys_version = ''

    def setup(self):
        super().setup()
        self.connection.settimeout(15)

    def reply(self, status, value, content_type='application/json'):
        body = value if isinstance(value, bytes) else json.dumps(value, separators=(',', ':')).encode()
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Referrer-Policy', 'no-referrer')
        self.send_header('X-Frame-Options', 'DENY')
        self.send_header('Content-Security-Policy', "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'")
        self.send_header('Connection', 'close')
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError, socket.timeout):
            pass

    def reject(self, error):
        self.reply(error.status, {'error': error.message})

    def log_message(self, *_):
        pass


class PrivateHandler(Handler):
    def route(self):
        return self.path.split('?', 1)[0].removeprefix('/x/school-backup') or '/'

    def authorized_origin(self, write=False):
        expected = self.server.private_origin
        return self.headers.get('Tailscale-User-Login') == self.server.private_login and (
            not write or (self.headers.get('Origin') == expected and
                          self.headers.get('Sec-Fetch-Site') != 'cross-site'))

    def do_GET(self):
        if self.route() == '/health':
            self.reply(200, {'status': 'ok'})
        elif not self.authorized_origin():
            self.reply(403, {'error': 'Use the private phone page.'})
        elif self.route() in {'/', '/api/status'}:
            if self.route() == '/':
                self.reply(200, PANEL, 'text/html; charset=utf-8')
            else:
                self.reply(200, self.server.store.status())
        else:
            self.reply(404, {'error': 'Not found.'})

    def do_POST(self):
        if self.route() != '/api/code':
            self.reply(404, {'error': 'Not found.'})
            return
        if not self.authorized_origin(write=True):
            self.reply(403, {'error': 'Use the private phone page.'})
            return
        if (self.headers.get('Transfer-Encoding') or self.headers.get('Content-Length') != '2' or
                self.headers.get_content_type() != 'application/json' or self.rfile.read(2) != b'{}'):
            self.reply(400, {'error': 'Invalid request.'})
            return
        try:
            self.reply(200, self.server.store.mint())
        except Rejected as error:
            self.reject(error)


class UploadHandler(Handler):
    def do_GET(self):
        self.reply(405, {'error': 'Upload only.'})

    def do_POST(self):
        if self.path != '/upload':
            self.reply(404, {'error': 'Not found.'})
            return
        if (self.headers.get('Transfer-Encoding') or self.headers.get('Content-Encoding') or
                self.headers.get_content_type() != 'application/gzip'):
            self.reply(400, {'error': 'Use a fixed-length gzip archive.'})
            return
        try:
            size = int(self.headers.get('Content-Length', '0'))
            code = self.headers.get('Authorization', '').removeprefix('Bearer ')
            upload_id = self.server.store.claim(code, size)
        except ValueError:
            self.reply(400, {'error': 'Invalid length.'})
            return
        except Rejected as error:
            self.reject(error)
            return
        part = self.server.store.archives / (upload_id + '.part')
        digest = hashlib.sha256()
        deadline = time.monotonic() + 300
        try:
            fd = os.open(part, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, 'wb') as output:
                left = size
                prefix = b''
                while left:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise TimeoutError()
                    self.connection.settimeout(min(15, remaining))
                    chunk = self.rfile.read1(min(65536, left))
                    if not chunk:
                        raise ValueError()
                    if len(prefix) < 2:
                        prefix = (prefix + chunk)[:2]
                        if len(prefix) == 2 and prefix != b'\x1f\x8b':
                            raise ValueError()
                    output.write(chunk)
                    digest.update(chunk)
                    left -= len(chunk)
                if prefix != b'\x1f\x8b':
                    raise ValueError()
                output.flush()
                os.fsync(output.fileno())
            os.replace(part, self.server.store.archives / (upload_id + '.tar.gz'))
            self.server.store.finish(upload_id, 'complete', digest.hexdigest())
            self.reply(201, {'id': upload_id, 'bytes': size, 'sha256': digest.hexdigest()})
        except (OSError, ValueError, TimeoutError):
            part.unlink(missing_ok=True)
            self.server.store.finish(upload_id, 'failed')
            self.reply(400, {'error': 'Upload interrupted or invalid. Your local files were not changed.'})


class BoundedServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, handler, store, private_origin, workers=8, private_login='owner@example.invalid'):
        super().__init__(address, handler)
        self.store, self.private_origin, self.private_login = store, private_origin, private_login
        self.slots = threading.BoundedSemaphore(workers)

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            try:
                request.sendall(b'HTTP/1.0 503 Busy\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
            except OSError:
                pass
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()


if __name__ == '__main__':
    os.umask(0o077)
    store = Store(os.environ['SCHOOL_BACKUP_STATE'], os.environ['SCHOOL_BACKUP_ARCHIVES'])
    store.recover()
    origin = os.environ['SCHOOL_PRIVATE_ORIGIN']
    login = os.environ['SCHOOL_PRIVATE_LOGIN']
    private = BoundedServer(('127.0.0.1', 39984), PrivateHandler, store, origin, workers=4, private_login=login)
    upload = BoundedServer(('127.0.0.1', 39985), UploadHandler, store, origin)
    threading.Thread(target=upload.serve_forever, daemon=True).start()
    private.serve_forever()

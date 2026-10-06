"""Install/import a local wheel as student in a home-resident virtualenv."""
from pathlib import Path
import ssl
import sqlite3
import subprocess
import sys
import zipfile

assert sys.version_info[:2] == (3, 12), sys.version
assert ssl.OPENSSL_VERSION and sqlite3.sqlite_version
subprocess.run(['pip', '--version'], check=True)
subprocess.run(['pip3', '--version'], check=True)
root = Path.home() / 'python-fixture'
root.mkdir()
wheel = root / 'school_fixture-1.0-py3-none-any.whl'
info = 'school_fixture-1.0.dist-info/'
files = {
    'school_fixture.py': 'VALUE = 42\n',
    info + 'METADATA': 'Metadata-Version: 2.1\nName: school-fixture\nVersion: 1.0\n',
    info + 'WHEEL': 'Wheel-Version: 1.0\nRoot-Is-Purelib: true\nTag: py3-none-any\n',
}
files[info + 'RECORD'] = ''.join(name + ',,\n' for name in files) + info + 'RECORD,,\n'
with zipfile.ZipFile(wheel, 'w') as archive:
    for name, content in files.items():
        archive.writestr(name, content)
venv = root / '.venv'
subprocess.run(['python3', '-m', 'venv', str(venv)], check=True)
subprocess.run([str(venv / 'bin/pip'), 'install', '--no-index', str(wheel)], check=True)
subprocess.run([str(venv / 'bin/python'), '-c', 'import school_fixture; assert school_fixture.VALUE == 42'], check=True)
print('Python 3.12, pip aliases, TLS/SQLite and non-root virtualenv package installation passed.')

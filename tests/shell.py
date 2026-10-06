"""Actual offline interactive zsh startup, including prompt and fzf bindings."""
import os
import pty
import select
import subprocess
import sys
import time

name = f'school-shell-tty-test-{os.getpid()}'
image = sys.argv[1] if len(sys.argv) > 1 else 'school-shell:v2.0.3'
pid, fd = pty.fork()
if pid == 0:
    os.execvp('docker', ['docker', 'run', '--rm', '-it', '--network', 'none', '--name', name, image, 'zsh', '-l'])
output = bytearray()
start = time.monotonic()
sent = False
try:
    while time.monotonic() < start + 25:
        if select.select([fd], [], [], .1)[0]:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            output.extend(chunk)
        if not sent and time.monotonic() > start + 2:
            os.write(fd, b'(( $+functions[fzf-history-widget] )) || exit 2; /opt/powerlevel10k/gitstatus/install -n -- /bin/true || exit 3; print SCHOOL_TTY_READY; exit\n')
            sent = True
    else:
        raise AssertionError('Interactive startup timed out')
    _, status = os.waitpid(pid, 0)
    assert os.waitstatus_to_exitcode(status) == 0, output.decode(errors='replace')
    assert b'SCHOOL_TTY_READY\r\n' in output
    for error in (b'no such file', b'failed to initialize', b'failed to install', b'configuration wizard'):
        assert error not in output, output.decode(errors='replace')
    print('Interactive offline zsh passed: full prompt, baked gitstatus, fzf bindings and no startup errors.')
finally:
    os.close(fd)
    subprocess.run(['docker', 'rm', '-f', name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

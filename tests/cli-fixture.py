"""Run destructive-script mocks only inside a disposable container with a PTY."""
import os
from pathlib import Path
import pty
import select
import time

scenario = os.environ['SCENARIO']
Path('/mock').mkdir()
Path('/mock-container').touch()
Path('/mock-volume').touch()
Path('/home/ordinary-wsl').mkdir()
Path('/home/ordinary-wsl/keep').write_text('ordinary work')
Path('/home/student/work.txt').write_text('saved school work')
for name in ('school', 'school-clean'):
    Path('/usr/local/bin/' + name).write_text('launcher fixture')
mock = Path('/mock/mock')
mock.write_text('''#!/bin/bash
set -euo pipefail
command=${0##*/}
printf '%s %s\\n' "$command" "$*" >> /calls
case $command in
 grep) if [[ $* == *microsoft* ]]; then [[ $SCENARIO != cleanup-wrong-host ]]; else exec /usr/bin/grep "$@"; fi ;;
 docker)
  case "$1 ${2:-}" in
   'container inspect') [[ -e /mock-container ]] ;;
   'inspect --format')
    if [[ $* == *Config.Labels* ]]; then
     if [[ $SCENARIO == cleanup-foreign ]]; then echo foreign; else echo v2; fi
    elif [[ $* == *Mounts* ]]; then
     if [[ $SCENARIO == cleanup-bad-mount ]]; then echo bind:foreign; else echo volume:school-home-0; fi
    fi ;;
   'volume inspect') [[ -e /mock-volume ]] ;;
   'rm -f') rm /mock-container ;;
   'volume rm') rm /mock-volume ;;
   'image ls') printf 'school-shell:v2.0.0\\nunrelated:v1\\n' ;;
   'exec -it') [[ $SCENARIO != cleanup-failed-backup ]] ;;
   'exec --user') cat > /dev/null ;;
  esac ;;
 curl)
  if [[ $SCENARIO == cleanup-* ]]; then printf '# uploader fixture' > "${@: -1}"
  else
   read -r header
   [[ $header == 'header = "Authorization: Bearer 0007"' ]]
   if [[ $SCENARIO == upload-failed ]]; then exit 22; fi
   args=("$@")
   for ((i=0;i<$#;i++)); do
    if [[ ${args[i]} == --data-binary ]]; then archive=${args[i+1]#@}; fi
   done
   digest=$(sha256sum "$archive"); digest=${digest%% *}
   [[ $SCENARIO != upload-bad-checksum ]] || digest=wrong
   printf '{"id":"fixture","sha256":"%s"}' "$digest" > "${@: -1}"
  fi ;;
 tar) if [[ $SCENARIO == upload-oversize ]]; then truncate -s 83886081 "$2"; else exec /usr/bin/tar "$@"; fi ;;
esac
''')
mock.chmod(0o755)
for command in ('grep', 'docker', 'curl', 'tar'):
    Path('/mock/' + command).symlink_to(mock)
env = os.environ | {'PATH': '/mock:' + os.environ['PATH'], 'HOME': '/home/student', 'SUDO_UID': '0'}
script = '/src/cleanup.sh' if scenario.startswith('cleanup-') else '/src/school-upload'
args = ['/usr/bin/bash', script]
if scenario == 'cleanup-no-backup':
    args.append('--no-backup')
pid, fd = pty.fork()
if pid == 0:
    os.execve(args[0], args, env)
output = bytearray()
answered = False
end = time.monotonic() + 20
try:
    while time.monotonic() < end:
        if select.select([fd], [], [], .1)[0]:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            output.extend(chunk)
        if not answered:
            if b'Type DELETE to continue:' in output:
                os.write(fd, b'NO\n' if scenario == 'cleanup-cancel' else b'DELETE\n')
                answered = True
            elif b'Four-digit code' in output:
                os.write(fd, b'0007\n')
                answered = True
    else:
        os.kill(pid, 9)
        raise AssertionError('CLI fixture timed out')
finally:
    os.close(fd)
_, status = os.waitpid(pid, 0)
code = os.waitstatus_to_exitcode(status)
calls = Path('/calls').read_text() if Path('/calls').exists() else ''
assert Path('/home/ordinary-wsl/keep').read_text() == 'ordinary work'
assert 'prune' not in calls and 'docker image rm unrelated' not in calls
if scenario == 'cleanup-no-backup':
    assert code == 0, output
    assert not Path('/mock-container').exists() and not Path('/mock-volume').exists()
    assert not Path('/usr/local/bin/school').exists()
    assert 'docker exec' not in calls
elif scenario.startswith('cleanup-'):
    assert code != 0, output
    assert Path('/mock-container').exists() and Path('/mock-volume').exists()
    assert Path('/usr/local/bin/school').exists()
    assert 'docker rm' not in calls and 'docker volume rm' not in calls
else:
    assert code == (0 if scenario == 'upload-success' else 1 if scenario in {'upload-oversize', 'upload-bad-checksum'} else 22), output
    assert b'0007' not in output and '0007' not in calls
    assert Path('/home/student/work.txt').read_text() == 'saved school work'
    if scenario == 'upload-oversize':
        assert not answered and 'curl ' not in calls
print('Passed:', scenario)

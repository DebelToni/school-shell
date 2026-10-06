#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
name="school-$(id -u)"
volume="school-home-$(id -u)"
# Never touch a real school-shell user's existing workspace.
if docker container inspect "$name" >/dev/null 2>&1 || docker volume inspect "$volume" >/dev/null 2>&1; then
    echo 'Launcher test requires an unused school container/volume for this UID.' >&2
    exit 1
fi
cleanup() {
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker volume rm "$volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT
bash "$root/school" bash -ec 'test "$(id -u)" = 1000; printf launcher > launcher.txt; tmux new-session -d -s launcher "sleep 60"'
bash "$root/school" bash -ec 'test "$(cat launcher.txt)" = launcher; tmux has-session -t launcher'
test "$(printf 'printf default-zsh\nexit\n' | bash "$root/school")" = default-zsh
test "$(bash "$root/school" printf '%s' 'argument with spaces')" = 'argument with spaces'
docker stop "$name" >/dev/null
bash "$root/school" bash -ec 'test "$(cat launcher.txt)" = launcher'
docker rm -f "$name" >/dev/null
bash "$root/school" bash -ec 'test "$(cat launcher.txt)" = launcher'
echo 'Launcher tests passed: default zsh, argument quoting, tmux continuity, restart and recreation.'

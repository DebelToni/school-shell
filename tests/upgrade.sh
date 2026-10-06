#!/usr/bin/env bash
set -euo pipefail
name="school-upgrade-test-$$"
volume="$name-home"
cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; docker volume rm "$volume" >/dev/null 2>&1 || true; }
trap cleanup EXIT
old=ghcr.io/debeltoni/school-shell:v1.0.1
docker image inspect "$old" >/dev/null 2>&1 || docker pull "$old"
docker run --rm --mount "type=volume,src=$volume,dst=/home/student" "$old" bash -ec '
  mkdir -p .config/nvim
  printf custom-zsh > .zshrc
  printf custom-tmux > .tmux.conf
  printf custom-nvim > .config/nvim/init.lua
  printf old-history > .zsh_history
  printf saved-work > work.cpp
'
docker run -d --init --name "$name" --mount "type=volume,src=$volume,dst=/home/student" "${1:-school-shell:v2.0.2}" >/dev/null
docker exec "$name" bash -ec '
  test "$(cat work.cpp)" = saved-work
  test "$(cat .zsh_history)" = old-history
  test "$(readlink .zshrc)" = /opt/my-vim-env/school/zshrc
  test "$(readlink .config/nvim)" = /opt/my-vim-env/nvim
  test "$(find .school-config-backups -name .zshrc -exec cat {} \;)" = custom-zsh
  test "$(find .school-config-backups -name .tmux.conf -exec cat {} \;)" = custom-tmux
  test "$(find .school-config-backups -name init.lua -exec cat {} \;)" = custom-nvim
  test "$(find .school-config-backups -mindepth 1 -maxdepth 1 -type d | wc -l)" = 1
  cmp .school-config-version /opt/school-release
'
docker stop "$name" >/dev/null
docker start "$name" >/dev/null
docker exec "$name" bash -ec 'test "$(find .school-config-backups -mindepth 1 -maxdepth 1 -type d | wc -l)" = 1; test "$(cat work.cpp)" = saved-work'
echo 'Upgrade passed: actual v1 home and custom dotfiles preserved, managed v2 profile installed, restart idempotent.'

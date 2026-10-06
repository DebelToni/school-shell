#!/usr/bin/env bash
set -euo pipefail
image=${1:-school-shell:v2.0.3}
root=$(cd "$(dirname "$0")/.." && pwd)
name="school-shell-test-$$"
volume="$name-home"
cleanup() {
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker volume rm "$volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker run -d --init --name "$name" --mount "type=volume,src=$volume,dst=/home/student" \
    --mount "type=bind,src=$root/tests,dst=/tests,readonly" "$image" >/dev/null
docker exec "$name" bash -ec '
    test "$(id -u)" = 1000
    test "$HOME" = /home/student
    nvim --headless -u NONE +q
    zsh -lc "exit 0"
    gdb --version >/dev/null
    cmake --version >/dev/null
    git --version >/dev/null
    rg --version >/dev/null
    sudo -n true
    python /tests/python.py
    printf "#include <stdio.h>\nint main(void){puts(\"C works\");}\n" > hello.c
    gcc -Wall -Wextra -Werror hello.c -o hello
    test "$(./hello)" = "C works"
    printf "#include <iostream>\nint main(){std::cout << 42;}\n" > hello.cpp
    g++ -std=c++20 -Wall -Wextra -Werror hello.cpp -o hello-cpp
    test "$(./hello-cpp)" = 42
    printf persistent > persistence.txt
    tmux new-session -d -s smoke "sleep 60"
    tmux has-session -t smoke
    tmux kill-server
'
docker rm -f "$name" >/dev/null
docker run -d --init --name "$name" --mount "type=volume,src=$volume,dst=/home/student" "$image" >/dev/null
docker exec "$name" bash -ec 'test "$(cat persistence.txt)" = persistent; ./hello; ./hello-cpp'
docker exec "$name" /home/student/python-fixture/.venv/bin/python -c 'import school_fixture; assert school_fixture.VALUE == 42'
echo 'Smoke tests passed: tools, C/C++, Python/pip, tmux, home and virtualenv persistence after container replacement.'

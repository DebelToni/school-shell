#!/usr/bin/env bash
# Installation is mocked inside disposable containers, never on the real host.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
for scenario in success fallback pull no-systemd wrong-os wrong-arch conflict external; do
    docker run --rm -e "SCENARIO=$scenario" --mount "type=bind,src=$root,dst=/src,readonly" ubuntu:24.04 bash /src/tests/bootstrap-fixture.sh
done
echo 'Bootstrap tests passed: success, rerun, registry/fallback paths and refusal guards.'

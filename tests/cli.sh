#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
for scenario in cleanup-wrong-host cleanup-docker-stopped cleanup-foreign cleanup-bad-mount cleanup-cancel cleanup-failed-backup cleanup-no-backup upload-success upload-failed upload-bad-checksum upload-oversize; do
    docker run --rm --user 0 --entrypoint python3 -e "SCENARIO=$scenario" \
        --mount "type=bind,src=$root,dst=/src,readonly" "${1:-school-shell:v2.0.1}" /src/tests/cli-fixture.py
done

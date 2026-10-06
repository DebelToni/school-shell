#!/usr/bin/env bash
set -euo pipefail
mkdir /mock
if [[ $SCENARIO != no-systemd ]]; then mkdir -p /run/systemd/system; fi
if [[ $SCENARIO == wrong-os ]]; then printf 'ID=ubuntu\nVERSION_ID=22.04\n' > /etc/os-release; fi
cat > /mock/mock <<'MOCK'
#!/bin/bash
set -euo pipefail
command=${0##*/}
printf '%s %s\n' "$command" "$*" >> /calls
case $command in
    dpkg) if [[ $SCENARIO == wrong-arch ]]; then echo riscv64; else echo arm64; fi ;;
    dpkg-query)
        if [[ ${@: -1} == docker-ce && $SCENARIO != external ]]; then echo installed
        elif [[ ${@: -1} == docker.io && $SCENARIO == conflict ]]; then echo installed
        else exit 1; fi ;;
    curl)
        dest=${@: -1}
        if [[ $* == *SHA256SUMS* ]]; then
            (cd "${dest%/*}"; sha256sum school-shell-arm64.tar.gz) > "$dest"
        else printf mock > "$dest"; fi ;;
    docker)
        if [[ $1 == image && $SCENARIO != success ]]; then exit 1; fi
        if [[ $1 == pull && $SCENARIO == fallback ]]; then exit 1; fi ;;
esac
MOCK
chmod +x /mock/mock
for command in apt-get curl dpkg dpkg-query systemctl docker usermod; do ln -s mock "/mock/$command"; done
export PATH="/mock:$PATH"
case $SCENARIO in
    success|pull|fallback)
        bash /src/site/setup.sh
        cmp /src/school /usr/local/bin/school
        test -x /usr/local/bin/school
        bash /src/site/setup.sh
        test "$(grep -c '^URIs:' /etc/apt/sources.list.d/docker.sources)" = 1
        grep -q '^apt-get install .*docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin$' /calls
        if [[ $SCENARIO == fallback ]]; then grep -q '^docker load -i ' /calls; fi
        if [[ $SCENARIO == pull ]]; then grep -q '^docker tag ' /calls; fi
        ;;
    *)
        if bash /src/site/setup.sh > /result 2>&1; then echo "Guard failed: $SCENARIO" >&2; exit 1; fi
        test ! -e /usr/local/bin/school
        test ! -e /etc/apt/sources.list.d/docker.sources
        if [[ -f /calls ]]; then ! grep -q '^apt-get ' /calls; fi
        ;;
esac
echo "Passed: $SCENARIO"

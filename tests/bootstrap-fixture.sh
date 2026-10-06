#!/usr/bin/env bash
set -euo pipefail
mkdir /mock
if [[ $SCENARIO != no-systemd ]]; then mkdir -p /run/systemd/system; fi
if [[ $SCENARIO == wrong-os ]]; then printf 'ID=ubuntu\nVERSION_ID=22.04\n' > /etc/os-release; fi
case $SCENARIO in
    upgrade|same-version|foreign|bad-mount|late-foreign)
        touch /mock-container /mock-installed
        printf 'URIs: https://download.docker.com/linux/ubuntu\n' > /etc/apt/sources.list.d/docker.sources ;;
esac
[[ $SCENARIO == late-foreign ]] || touch /mock-engine
cat > /mock/mock <<'MOCK'
#!/bin/bash
set -euo pipefail
command=${0##*/}
printf '%s %s\n' "$command" "$*" >> /calls
case $command in
    grep)
        if [[ $* == *microsoft* ]]; then [[ $SCENARIO != wrong-host ]]; else exec /usr/bin/grep "$@"; fi ;;
    dpkg) if [[ $SCENARIO == wrong-arch ]]; then echo riscv64; else echo arm64; fi ;;
    dpkg-query)
        if [[ ${@: -1} == docker-ce && -e /mock-installed ]]; then echo installed
        elif [[ ${@: -1} == docker.io && $SCENARIO == conflict ]]; then echo installed
        else exit 1; fi ;;
    curl)
        dest=${@: -1}
        if [[ $* == *SHA256SUMS* ]]; then
            (cd "${dest%/*}"; sha256sum school-shell-arm64.tar.gz) > "$dest"
        else printf mock > "$dest"; fi ;;
    apt-get)
        if [[ $* == *docker-ce-cli* ]]; then touch /mock-installed; ln -sf mock /mock/docker; fi ;;
    systemctl) touch /mock-engine ;;
    docker)
        case "$1 ${2:-}" in
            'container inspect') [[ -e /mock-container && -e /mock-engine ]] ;;
            'image inspect')
                if [[ $* == *'{{.Id}}'* ]]; then echo new-image
                elif [[ $SCENARIO == pull || $SCENARIO == fallback ]]; then exit 1; fi ;;
            'inspect --format')
                if [[ $* == *Config.Labels* ]]; then
                    if [[ $SCENARIO == foreign || $SCENARIO == late-foreign ]]; then echo foreign
                    elif [[ $SCENARIO == upgrade ]]; then echo v1
                    else echo v2; fi
                elif [[ $* == *Mounts* ]]; then
                    if [[ $SCENARIO == bad-mount ]]; then echo bind:foreign; else echo volume:school-home-0; fi
                elif [[ $* == *'{{.Image}}'* ]]; then
                    if [[ $SCENARIO == upgrade ]]; then echo old-image; else echo new-image; fi
                fi ;;
            'rm -f') rm -f /mock-container ;;
            *) if [[ $1 == pull && $SCENARIO == fallback ]]; then exit 1; fi ;;
        esac ;;
esac
MOCK
chmod +x /mock/mock
for command in apt-get curl dpkg dpkg-query systemctl usermod grep; do ln -s mock "/mock/$command"; done
if [[ -e /mock-installed || $SCENARIO == external ]]; then ln -s mock /mock/docker; fi
export PATH="/mock:$PATH"
case $SCENARIO in
    success|pull|fallback|upgrade|same-version)
        bash /src/site/setup.sh
        cmp /src/school /usr/local/bin/school
        cmp /src/cleanup.sh /usr/local/bin/school-clean
        test -x /usr/local/bin/school
        bash /src/site/setup.sh
        test "$(grep -c '^URIs:' /etc/apt/sources.list.d/docker.sources)" = 1
        if [[ $SCENARIO == upgrade || $SCENARIO == same-version ]]; then
            ! grep -q '^apt-get ' /calls
        else
            test "$(grep -c '^apt-get install .*docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin$' /calls)" = 1
        fi
        if [[ $SCENARIO == fallback ]]; then grep -q '^docker load -i ' /calls; fi
        if [[ $SCENARIO == pull ]]; then grep -q '^docker tag ' /calls; fi
        if [[ $SCENARIO == upgrade ]]; then test ! -e /mock-container; grep -q '^docker rm -f school-0$' /calls; fi
        if [[ $SCENARIO == same-version ]]; then test -e /mock-container; ! grep -q '^docker rm ' /calls; fi
        ! grep -q '^docker volume rm ' /calls
        ;;
    *)
        if bash /src/site/setup.sh > /result 2>&1; then echo "Guard failed: $SCENARIO" >&2; exit 1; fi
        test ! -e /usr/local/bin/school
        if [[ $SCENARIO == late-foreign ]]; then
            test -e /mock-container
            ! grep -q '^docker rm ' /calls
        fi
        if [[ -f /calls ]]; then ! grep -q '^apt-get ' /calls; fi
        ;;
esac
echo "Passed: $SCENARIO"

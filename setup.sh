#!/usr/bin/env bash
# Ubuntu 24.04 WSL2 bootstrap and in-place school environment upgrade.
set -euo pipefail
main() {
trap 'echo "Setup failed on line $LINENO. Fix the reported error and rerun setup." >&2' ERR
[[ $EUID == 0 ]] || { echo 'Run with sudo bash.' >&2; exit 1; }
. /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 24.04 ]] || { echo 'Requires Ubuntu 24.04.' >&2; exit 1; }
grep -qi microsoft /proc/sys/kernel/osrelease || { echo 'This installer is for WSL, not DGX.' >&2; exit 1; }
version=v2.0.0
uid=${SUDO_UID:-0}
name="school-$uid"
volume="school-home-$uid"
arch=$(dpkg --print-architecture)
[[ $arch == amd64 || $arch == arm64 ]] || { echo "Unsupported architecture: $arch" >&2; exit 1; }
[[ -d /run/systemd/system ]] || {
    echo 'Enable [boot] systemd=true in /etc/wsl.conf, run wsl --shutdown in Windows, then retry.' >&2; exit 1;
}
if command -v docker >/dev/null && docker container inspect "$name" >/dev/null 2>&1; then
    label=$(docker inspect --format '{{index .Config.Labels "school-shell"}}' "$name")
    mount=$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/home/student"}}{{.Type}}:{{.Name}}{{end}}{{end}}' "$name")
    [[ ($label == v1 || $label == v2) && $mount == "volume:$volume" ]] || {
        echo "Container $name has unexpected ownership or storage. Resolve it manually." >&2; exit 1;
    }
fi
conflicts=()
for pkg in docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc; do
    if [[ $(dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null || true) == installed ]]; then conflicts+=("$pkg"); fi
done
(( ${#conflicts[@]} == 0 )) || { echo "Remove conflicting packages explicitly: ${conflicts[*]}" >&2; exit 1; }
if command -v docker >/dev/null && ! dpkg-query -W docker-ce >/dev/null 2>&1; then
    echo 'Disable external Docker Desktop WSL integration before installing this engine.' >&2; exit 1
fi
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL --retry 3 https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: noble
Components: stable
Architectures: $arch
Signed-By: /etc/apt/keyrings/docker.asc
EOF
apt-get update
apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
docker info >/dev/null
image="school-shell:$version"
if ! docker image inspect "$image" >/dev/null 2>&1; then
    if docker pull "ghcr.io/debeltoni/school-shell:$version-$arch"; then
        docker tag "ghcr.io/debeltoni/school-shell:$version-$arch" "$image"
    else
        echo 'Registry unavailable. Using the checksum-verified public release.'
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        release=https://github.com/DebelToni/school-shell/releases/download/$version
        curl -fL --retry 3 "$release/school-shell-$arch.tar.gz" -o "$tmp/school-shell-$arch.tar.gz"
        curl -fL --retry 3 "$release/SHA256SUMS" -o "$tmp/SHA256SUMS"
        (cd "$tmp"; grep "  school-shell-$arch.tar.gz$" SHA256SUMS | sha256sum --check --strict -)
        docker load -i "$tmp/school-shell-$arch.tar.gz"
    fi
fi
# Validate the new image before discarding any existing container's writable layer.
docker run --rm "$image" bash -ec 'clangd --version >/dev/null; bash-language-server --version >/dev/null; lua-language-server --version >/dev/null; nvim --headless "+lua assert(vim.g.school_profile)" +qa'
if docker container inspect "$name" >/dev/null 2>&1; then
    current=$(docker inspect --format '{{.Image}}' "$name")
    desired=$(docker image inspect --format '{{.Id}}' "$image")
    if [[ $current != "$desired" ]]; then
        echo 'Upgrading: stopping sessions and replacing the container. Home volume is retained.'
        docker rm -f "$name" >/dev/null
    fi
fi
install -m 0755 /dev/stdin /usr/local/bin/school <<'SCHOOL_HELPER'
@@SCHOOL_HELPER@@
SCHOOL_HELPER
install -m 0755 /dev/stdin /usr/local/bin/school-clean <<'SCHOOL_CLEANUP'
@@SCHOOL_CLEANUP@@
SCHOOL_CLEANUP
if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then usermod -aG docker "$SUDO_USER"; fi
printf '\nReady: school\nUpload from inside: school-upload\nCleanup from WSL: school-clean\nDocker group membership grants root-equivalent WSL access.\n'
}
main

#!/usr/bin/env bash
# Ubuntu 24.04 WSL2 bootstrap. Docker installation follows docs.docker.com.
set -euo pipefail
main() {
trap 'echo "Setup failed on line $LINENO. Fix the reported error and rerun setup." >&2' ERR
[[ $EUID == 0 ]] || { echo 'Run this script with sudo bash.' >&2; exit 1; }
. /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 24.04 ]] || {
    echo 'V1 supports Ubuntu 24.04 only.' >&2; exit 1;
}
version=v1.0.1
arch=$(dpkg --print-architecture)
[[ $arch == amd64 || $arch == arm64 ]] || { echo "Unsupported architecture: $arch" >&2; exit 1; }
if [[ ! -d /run/systemd/system ]]; then
    echo 'Systemd must be enabled. In /etc/wsl.conf set [boot] systemd=true.' >&2
    echo 'Then run wsl --shutdown from Windows, reopen Ubuntu and rerun setup (WSL2 required).' >&2
    exit 1
fi
# Do not replace an existing Docker Desktop integration or distro engine silently.
conflicts=()
for pkg in docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc; do
    if [[ $(dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null || true) == installed ]]; then
        conflicts+=("$pkg")
    fi
done
if (( ${#conflicts[@]} )); then
    echo "Conflicting packages: ${conflicts[*]}. Remove them explicitly, then rerun." >&2
    exit 1
fi
if command -v docker >/dev/null && ! dpkg-query -W docker-ce >/dev/null 2>&1; then
    echo 'Existing external Docker CLI found. Disable Docker Desktop WSL integration before using this installer.' >&2
    exit 1
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
if ! docker image inspect school-shell:v1 >/dev/null 2>&1; then
    if docker pull "ghcr.io/debeltoni/school-shell:$version-$arch"; then
        docker tag "ghcr.io/debeltoni/school-shell:$version-$arch" school-shell:v1
    else
        echo 'Registry unavailable. Using the public, checksum-verified GitHub release.'
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        release=https://github.com/DebelToni/school-shell/releases/download/$version
        curl -fL --retry 3 "$release/school-shell-$arch.tar.gz" -o "$tmp/school-shell-$arch.tar.gz"
        curl -fL --retry 3 "$release/SHA256SUMS" -o "$tmp/SHA256SUMS"
        (cd "$tmp"; grep "  school-shell-$arch.tar.gz$" SHA256SUMS | sha256sum --check --strict -)
        docker load -i "$tmp/school-shell-$arch.tar.gz"
        docker tag "school-shell:$version" school-shell:v1
    fi
fi
docker run --rm school-shell:v1 sh -ec 'nvim --version >/dev/null; gcc --version >/dev/null; tmux -V'
install -m 0755 /dev/stdin /usr/local/bin/school <<'SCHOOL_HELPER'
@@SCHOOL_HELPER@@
SCHOOL_HELPER
if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
    usermod -aG docker "$SUDO_USER"
fi
printf '\nReady. Run: school\nOr: school bash\nHome persists on this PC in a Docker volume. Docker group membership grants root-equivalent access.\n'
}
main

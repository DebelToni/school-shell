#!/usr/bin/env bash
set -euo pipefail
main() {
if [[ $EUID != 0 ]]; then exec sudo bash "$0" "$@"; fi
if ! grep -qi microsoft /proc/sys/kernel/osrelease; then
    echo 'This destructive cleanup is for WSL only, never DGX.' >&2; exit 1
fi
[[ $# == 0 || ($# == 1 && $1 == --no-backup) ]] || { echo 'Usage: school-clean [--no-backup]' >&2; exit 1; }
uid=${SUDO_UID:-0}
name="school-$uid"
volume="school-home-$uid"
backup=true
[[ ${1:-} != --no-backup ]] || backup=false
if docker container inspect "$name" >/dev/null 2>&1; then
    label=$(docker inspect --format '{{index .Config.Labels "school-shell"}}' "$name")
    mount=$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/home/student"}}{{.Type}}:{{.Name}}{{end}}{{end}}' "$name")
    [[ ($label == v1 || $label == v2) && $mount == "volume:$volume" ]] || {
        echo "Refusing unexpected container ownership or storage: $name." >&2; exit 1;
    }
elif docker volume inspect "$volume" >/dev/null 2>&1; then
    label=$(docker volume inspect --format '{{index .Labels "school-shell"}}' "$volume")
    [[ $label == true ]] || { echo 'Restore the legacy workspace with school before cleaning its unlabelled home volume.' >&2; exit 1; }
fi
printf 'Delete this account\047s school container, home volume and launchers. Ubuntu and the normal WSL home remain.\n'
$backup || echo 'You explicitly chose deletion WITHOUT a backup.'
read -r -p 'Type DELETE to continue: ' confirm </dev/tty
[[ $confirm == DELETE ]] || { echo 'Cancelled.'; exit 1; }
if $backup; then
    if ! docker container inspect "$name" >/dev/null 2>&1; then
        echo 'No container to back up. Restore it with school, or explicitly use --no-backup.' >&2; exit 1
    fi
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    curl -fsSL https://setup.toni.foo/school-upload -o "$tmp/school-upload"
    docker start "$name" >/dev/null
    docker exec --user 0 -i "$name" sh -c 'cat > /tmp/school-upload-cleanup; chmod 0755 /tmp/school-upload-cleanup' < "$tmp/school-upload"
    docker exec -it "$name" bash /tmp/school-upload-cleanup </dev/tty
fi
if docker container inspect "$name" >/dev/null 2>&1; then docker rm -f "$name" >/dev/null; fi
if docker volume inspect "$volume" >/dev/null 2>&1; then docker volume rm "$volume" >/dev/null; fi
# Remove only our image references. Never prune unrelated Docker data.
while IFS= read -r image; do
    [[ -n $image ]] || continue
    docker image rm "$image" >/dev/null 2>&1 || true
done < <(docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -E '^(school-shell|ghcr\.io/debeltoni/school-shell):' || true)
rm -f /usr/local/bin/school /usr/local/bin/school-clean
printf '\033[3J\033[2J\033[HSchool workspace removed. DGX backups are retained. This is not forensic erasure or Windows cleanup.\n'
}
main "$@"

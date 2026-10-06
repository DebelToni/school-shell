# School shell v1

An Ubuntu 24.04 development container for Ubuntu 24.04 on WSL2. Install only on PCs where you are allowed to administer the WSL distribution.

## Install

Visit https://setup.toni.foo for the one-line installer:

```bash
curl -fsSL https://setup.toni.foo/setup.sh | sudo bash
```

Then enter from any WSL terminal:

```bash
school          # zsh
school bash     # bash
school nvim     # plain Neovim
school tmux     # tmux inside the container
```

V1 includes stock Ubuntu Neovim, zsh, tmux, GCC/G++, make, gdb, cmake, git, ripgrep, curl, SSH client, unzip and sudo. Zsh has only a small persistent-history configuration to skip its first-run wizard. No my-vim-env files, plugins, LSP setup, personal credentials or Windows key remapping. Ubuntu's packaged Neovim is deliberately used, not the latest upstream release.

## How it works

The installer uses Docker's [official Ubuntu APT repository](https://docs.docker.com/engine/install/ubuntu/) for Engine, CLI, containerd, Buildx and Compose. It enables Docker at WSL boot and adds the installing user to the Docker group. That group grants root-equivalent privileges in the WSL distribution; the launcher uses sudo as a fallback until a new login applies group membership.

It downloads a prebuilt native amd64 or arm64 image, never builds it on the school PC. GHCR is tried first; a SHA-256-verified public GitHub release archive is the fallback if the registry is inaccessible or the new package is still private. Neither path requires school-PC credentials. Installation time depends on the network, APT and disk; 2 to 5 minutes is a target, not a guarantee.

`school` creates one container (`school-<host UID>`) and named home volume (`school-home-<host UID>`) per WSL user. You work as `student`, UID 1000, in `/home/student`. The container stays running when you exit, preserving tmux sessions while WSL stays up, and starts with Docker after a WSL restart. Disk contents survive restart; running processes do not survive WSL shutdown.

Your entire container home, including projects, dotfiles and history, survives container replacement. Packages installed with the container's passwordless sudo live in its writable layer, so they survive reopening but not replacement. No Docker socket or Windows/host directory is mounted into the container, and no network ports are published.

Persistence is local to that PC's WSL distribution. It is not cross-PC sync or a backup. Push coursework to your own Git remote; do not leave personal tokens on shared PCs. Deleting the WSL distribution or this named volume deletes its local work.

## Prerequisites and reruns

Use WSL2 with systemd enabled, as on current Ubuntu 24.04 WSL installations. If disabled, preserve other `/etc/wsl.conf` settings and add:

```ini
[boot]
systemd=true
```

Run `wsl --shutdown` in Windows, reopen Ubuntu and retry. The installer stops before modifying the host if systemd is absent, the Ubuntu release/architecture is unsupported, or conflicting distro Docker packages or an external Docker Desktop CLI are found. It does not silently remove existing engines or data.

Rerunning setup reinstalls its managed Docker repository and launcher without deleting a container or volume. An already downloaded `school-shell:v1` image is reused. V1 release images are fixed snapshots; later package security updates require a new release.

## Build and verify

```bash
docker build -t school-shell:v1 .
uv run --no-project python publish-site.py
bash tests/smoke.sh
bash tests/bootstrap.sh
bash tests/launcher.sh  # requires no existing school workspace for your UID
node tests/worker.mjs
bash -n site/setup.sh school
```

Smoke tests compile and execute C and C++, check installed tools and a tmux session, and recreate the container while retaining its home volume. Bootstrap tests mock host installation commands in disposable Ubuntu containers, checking success, idempotence, and early refusal paths. They do not prove a real Windows/WSL Docker installation; that still needs a school-PC test.

## Publishing

Source: https://github.com/DebelToni/school-shell

Current image: `ghcr.io/debeltoni/school-shell:v1.0.1`, with native `v1.0.1-amd64` and `v1.0.1-arm64` tags. The installer tags the downloaded release locally as `school-shell:v1`. Tag pushes run native GitHub Actions builds and smoke tests before publishing both architectures and public image archives to the release. GHCR visibility must permit anonymous pulls. If a new package is private, the owner can switch it to public in its settings. The release fallback also supports login-free installation when the registry is unavailable.

`setup.sh` contains an embedded-helper placeholder. `publish-site.py` produces `site/setup.sh` for the Cloudflare Worker; do not run the unbundled template directly. Deploy from this directory with `wrangler deploy` after bundling, using the existing protected Cloudflare credential. The Worker serves only plain text at `/` and `/setup.sh`; it has no dependency on the personal website origin and changes no existing website route. Its config declares only `setup.toni.foo`.

Rollback the public endpoint by removing that Worker's custom domain and deleting the Worker, without touching other toni.foo routes. Do not delete school-PC volumes as part of a deployment rollback.

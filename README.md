# School shell v2

Pinned Ubuntu 24.04 development environment for Ubuntu 24.04 on WSL2. Install only where you are allowed to administer the WSL distribution.

## Install or upgrade

```bash
curl -fsSL https://setup.toni.foo/setup.sh | sudo bash
school
```

`school` opens zsh. Arguments run inside the same workspace, for example `school nvim`, `school tmux`, or `school bash`.

The installer downloads the native amd64 or arm64 `v2.0.2` image from public GHCR. A SHA-256-verified public GitHub release archive is the fallback. No school-PC credentials or local image build are required. Network, APT and disk speed determine installation time.

Rerun this installer for a new release. A changed image replaces the old container, stopping running processes/tmux sessions and discarding packages or changes outside home. The complete `/home/student` volume survives. Same-image reruns retain the container and its sessions. Managed `.zshrc`, `.tmux.conf`, `.config/nvim` and `my-vim-env` links are refreshed on a release change; replaced custom contents are retained under `~/.school-config-backups/`.

## Included profile

The school subset of [my-vim-env](https://github.com/DebelToni/Neovim) is pinned to `f3e3671af8f0e3a2aae8574f4eacc0dea5f18081`. Normal daily configuration remains unchanged without `SCHOOL_SHELL=1`.

- Neovim 0.12.5 with Catppuccin, Telescope, Oil, mini, gitsigns, lualine, Noice, OSC52, original navigation/mappings and tree-sitter.
- C/C++: GCC/G++, clang, clangd, clang-format, make, gdb and cmake.
- Bash: bash-language-server 5.8.1, ShellCheck and shfmt.
- Lua: Lua language server 3.19.1.
- Zsh: portable Powerlevel10k prompt, vi mode, persistent history, autosuggestions, syntax highlighting, fzf, zoxide, eza and bat.
- Tmux: Ctrl+A, top status, mouse/vi copy, OSC52, pane navigation and window picker.

Plugins and parsers are baked into `/opt` at pinned revisions. Editor startup does not install/update them. AI/Copilot/Pi, graphics, Markdown/math/LaTeX renderers, browser previews, SQL UI and unrelated language integrations are omitted. No personal credentials or Windows key remapping are included.

## Persistence and host requirements

Each WSL UID gets `school-<UID>` and `school-home-<UID>`. Inside, the user is `student` (UID 1000) with passwordless container sudo. The container stays running after exiting the shell and uses Docker's `unless-stopped` policy. Home files persist on that PC; processes do not survive WSL shutdown. There are no host/Windows bind mounts, Docker socket mounts or published container ports.

Docker Engine, CLI, containerd, Buildx and Compose use Docker's official Ubuntu APT repository. An existing official Engine installation is reused rather than upgraded/restarted by setup. The installer enables Docker and adds the WSL user to its group, which grants root-equivalent WSL access. The launcher uses sudo until a new login applies group membership.

The installer refuses non-WSL hosts, unsupported Ubuntu/architectures, missing systemd, conflicting distro Docker packages, external Docker Desktop integration and unexpected existing container storage. If needed, preserve other `/etc/wsl.conf` settings and add `[boot]` with `systemd=true`, then run `wsl --shutdown` in Windows and reopen Ubuntu.

## Upload a home backup

Inside the container:

```bash
school-upload
```

Save editor buffers and avoid changing files during the snapshot. The command prepares a tar/gzip of the saved home, including dotfiles/history, without following symlinks. It checks the compressed size before asking for a code. Then generate a code on the owner's private School backup phone page and enter it at the hidden prompt.

Policy:

- Four decimal digits, single use, claimed within 15 seconds. The body may finish afterward.
- One-minute generation cooldown and three codes per Europe/Sofia calendar day.
- At most three uploads per rolling hour; failed claimed uploads count.
- 80 MiB compressed per archive and 20 GiB total archive storage, including reservations.
- Three wrong guesses lock an active code; six public authentication attempts per minute globally.

The code is absent from argv, files, environment variables and shell history. A returned SHA-256 receipt must match the local archive. Failure leaves local work intact.

The public `/backup` endpoint is upload-only. It provides no archive listing, reading, downloading or remote command execution. Archives remain private, opaque files until the owner manually inspects/deletes them. They are never automatically extracted. The DGX disk is unencrypted; owner-only permissions are not at-rest encryption. Short codes can still be guessed or deliberately locked, so this is bounded write access, not immunity to guessing or denial of service.

## Remove the school workspace

From WSL, outside the container:

```bash
school-clean
```

This requires typing `DELETE` and successfully uploading a backup first. Explicitly skip that backup with `school-clean --no-backup`.

If the launcher is missing:

```bash
curl -fsSL https://setup.toni.foo/cleanup.sh | sudo bash
# Explicitly skip backup:
curl -fsSL https://setup.toni.foo/cleanup.sh | sudo bash -s -- --no-backup
```

Cleanup removes this UID's school container/home volume, managed image references when removable, and installed school launchers. It leaves Ubuntu, Docker, the normal WSL home, unrelated Docker data, Windows and DGX backups intact. It refuses unexpected ownership/storage and aborts deletion if backup fails. Restore an orphaned unlabelled v1 home with `school` before cleaning it.

This is not forensic erasure. Windows terminal logs, ordinary WSL history and recoverable deleted disk blocks may retain traces. Do not leave personal credentials on a shared machine.

## Build and verify

Use Node 22+ and Docker:

```bash
uv run --no-project python publish-site.py
npm ci --ignore-scripts
npm test
uv run --no-project python -W error::ResourceWarning -m unittest discover -s tests -p test_backup.py
bash tests/bootstrap.sh
docker build -t school-shell:v2.0.2 .
bash tests/smoke.sh
bash tests/launcher.sh
bash tests/upgrade.sh
bash tests/cli.sh
uv run --no-project python tests/shell.py
docker run --rm --mount "type=bind,src=$PWD/tests,dst=/tests,readonly" school-shell:v2.0.2 nvim --headless '+luafile /tests/editor.lua'
```

Launcher tests require no preexisting school workspace for the current host UID. Other container/volume tests use unique disposable names. Bootstrap and destructive cleanup tests mock host operations only inside disposable containers, with PTYs for confirmation/code prompts. Interactive zsh tests run offline in a real PTY, including fzf bindings and the baked gitstatus daemon. Workerd tests exercise real fixed-length HTTP forwarding. Editor tests open real C, C++, Bash and Lua projects and verify LSP definitions, completion, diagnostics and parsers. These tests do not prove a v2 Windows/WSL installation; the original v1 installer was separately confirmed on the school PC.

## Publishing and server boundaries

Source: https://github.com/DebelToni/school-shell. Image: `ghcr.io/debeltoni/school-shell:v2.0.2`, with native `-amd64` and `-arm64` tags. Tag CI builds/tests both architectures before publishing the multiarch image and public release archives. Later releases must consistently bump the image version in the Dockerfile, installer and launcher.

`setup.sh` is a template. `publish-site.py` embeds its helpers and creates the three Worker assets under `site/`. Deploy the Worker only after the release and backup origin are ready, using protected Cloudflare credentials. It serves scripts at `/setup.sh`, `/cleanup.sh` and `/school-upload`, and relays only `/backup` POST to the upload origin using a `FixedLengthStream`.

`backup/server.py` is a standard-library service with two loopback listeners: private code generation on 39984, upload-only intake on 39985. `deploy/school-backup.service` requires a project `.venv` and owner-only runtime environment containing `SCHOOL_BACKUP_STATE`, `SCHOOL_BACKUP_ARCHIVES`, `SCHOOL_PRIVATE_ORIGIN` and `SCHOOL_PRIVATE_LOGIN`. The private reverse proxy must supply trusted, spoof-stripped Tailscale owner identity headers. Minting also requires the exact private Origin. Never publish the actual private hostname/login in this repository.

The public tunnel hostname `school-backup-origin.toni.foo` must target only 39985, never the private interface. Preserve existing tunnel/Serve configuration when adding routes. Register response-only uptime probes; never mint codes or upload from monitoring. State and archives are retained across deployments.

Rollback the Worker to its previous version independently. To retire backup ingress, remove only its dedicated public hostname rule/DNS record and private mounted route, then disable only `school-backup.service`. Do not reset the shared tunnel/Serve configuration, delete school-PC volumes or erase retained archives during a deployment rollback.

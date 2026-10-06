FROM node:24.21.0-bookworm-slim AS bash-lsp
WORKDIR /build
COPY build/package*.json ./
RUN npm ci --omit=dev --no-audit --no-fund

FROM ubuntu:24.04 AS base
LABEL org.opencontainers.image.source="https://github.com/DebelToni/school-shell" \
      org.opencontainers.image.description="Pinned school development environment"
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    zsh tmux build-essential clang clangd clang-format gdb cmake git curl ca-certificates \
    openssh-client sudo less locales ripgrep unzip jq procps python3 \
    shellcheck shfmt fzf bat eza zoxide zsh-autosuggestions zsh-syntax-highlighting \
    && locale-gen en_US.UTF-8 && userdel ubuntu \
    && useradd -m -u 1000 -s /usr/bin/zsh student \
    && printf 'student ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/student \
    && chmod 0440 /etc/sudoers.d/student && rm -rf /var/lib/apt/lists/*
COPY --from=bash-lsp /usr/local/bin/node /usr/local/bin/node
COPY --from=bash-lsp /build/node_modules /opt/bash-lsp/node_modules
RUN ln -s /opt/bash-lsp/node_modules/bash-language-server/out/cli.js /usr/local/bin/bash-language-server
# Official release archives are pinned and SHA-256 verified on both architectures.
RUN arch=$(dpkg --print-architecture) && \
    if [ "$arch" = arm64 ]; then \
      nv=arm64; lua=arm64; ts=arm64; \
      nh=1aa5ca085249580ae0f91eb14f27ec0919773ff2d99a163d03f3d6c21ac29725; \
      lh=abd2572e8fc929dc838a81ffb8473c5bce0bf39bfe8edb4b120b3b623176ce83; \
      th=3a35a2dd961ad842384e982c75daf792c01d1a67e442fc3914d4de37bd8a59cb; \
    else \
      nv=x86_64; lua=x64; ts=x64; \
      nh=bce0f56eda1f1b1db6eee8f4133d7a38813ea07933837dd1777411ca384c6875; \
      lh=e9235d2d72ef55bc41cf8c99cda2ed64777682024b4bb81f5dea425060c5cbb8; \
      th=20a1f39ec1c45f2211492dcb8881c802b643b554bb196869a29ac3778277fa77; \
    fi && \
    curl -fL --retry 3 "https://github.com/neovim/neovim/releases/download/v0.12.5/nvim-linux-$nv.tar.gz" -o /tmp/nvim.tar.gz && \
    echo "$nh  /tmp/nvim.tar.gz" | sha256sum -c - && \
    mkdir /opt/neovim && tar -xzf /tmp/nvim.tar.gz -C /opt/neovim --strip-components=1 && \
    ln -s /opt/neovim/bin/nvim /usr/local/bin/nvim && \
    curl -fL --retry 3 "https://github.com/LuaLS/lua-language-server/releases/download/3.19.1/lua-language-server-3.19.1-linux-$lua.tar.gz" -o /tmp/lua.tar.gz && \
    echo "$lh  /tmp/lua.tar.gz" | sha256sum -c - && \
    mkdir /opt/lua-language-server && tar -xzf /tmp/lua.tar.gz -C /opt/lua-language-server && \
    ln -s /opt/lua-language-server/bin/lua-language-server /usr/local/bin/lua-language-server && \
    curl -fL --retry 3 "https://github.com/tree-sitter/tree-sitter/releases/download/v0.27.0/tree-sitter-linux-$ts.gz" -o /tmp/tree-sitter.gz && \
    echo "$th  /tmp/tree-sitter.gz" | sha256sum -c - && \
    gzip -dc /tmp/tree-sitter.gz > /usr/local/bin/tree-sitter && chmod 0755 /usr/local/bin/tree-sitter && \
    rm /tmp/nvim.tar.gz /tmp/lua.tar.gz /tmp/tree-sitter.gz
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 TERM=xterm-256color HOME=/home/student \
    SCHOOL_SHELL=1 MY_VIM_ENV=/opt/my-vim-env \
    SCHOOL_NVIM_PLUGINS=/opt/nvim-plugins SCHOOL_NVIM_PARSERS=/opt/nvim-parsers

FROM base AS editor-build
ARG MY_VIM_ENV_REV=f3e3671af8f0e3a2aae8574f4eacc0dea5f18081
RUN git init -q /opt/my-vim-env && \
    git -C /opt/my-vim-env fetch -q --depth 1 https://github.com/DebelToni/Neovim.git "$MY_VIM_ENV_REV" && \
    git -C /opt/my-vim-env checkout -q --detach FETCH_HEAD && \
    git init -q /opt/powerlevel10k && \
    git -C /opt/powerlevel10k fetch -q --depth 1 https://github.com/romkatv/powerlevel10k.git d05a1b00f9a61f9578bf9dc19b8451942dde8734 && \
    git -C /opt/powerlevel10k checkout -q --detach FETCH_HEAD
# Ubuntu's container excludes documentation, including fzf's runtime shell scripts.
RUN GITSTATUS_CACHE_DIR=/opt/powerlevel10k/gitstatus/usrbin /opt/powerlevel10k/gitstatus/install && \
    apt-get update && cd /tmp && apt-get download "fzf=$(dpkg-query -W -f='${Version}' fzf)" && \
    dpkg-deb -x fzf_*.deb /tmp/fzf-extracted && mkdir /opt/fzf-shell && \
    cp /tmp/fzf-extracted/usr/share/doc/fzf/examples/*.zsh /opt/fzf-shell/
COPY build/plugins.json build/plugins.sh build/parsers.lua /build/
RUN bash /build/plugins.sh && nvim --headless -u NONE -l /build/parsers.lua

FROM base
ARG MY_VIM_ENV_REV=f3e3671af8f0e3a2aae8574f4eacc0dea5f18081
LABEL school-shell="v2" school-shell.config-revision="$MY_VIM_ENV_REV"
COPY --from=editor-build /opt/my-vim-env/nvim /opt/my-vim-env/nvim
COPY --from=editor-build /opt/my-vim-env/school /opt/my-vim-env/school
COPY --from=editor-build /opt/my-vim-env/tmux/scripts /opt/my-vim-env/tmux/scripts
COPY --from=editor-build /opt/nvim-plugins /opt/nvim-plugins
COPY --from=editor-build /opt/nvim-parsers /opt/nvim-parsers
COPY --from=editor-build /opt/powerlevel10k /opt/powerlevel10k
COPY --from=editor-build /opt/fzf-shell /usr/share/doc/fzf/examples
COPY --chmod=0755 school-entrypoint school-upload /usr/local/bin/
RUN printf 'v2.0.2\n%s\n' "$MY_VIM_ENV_REV" > /opt/school-release
USER student
WORKDIR /home/student
ENTRYPOINT ["/usr/local/bin/school-entrypoint"]
CMD ["sleep", "infinity"]

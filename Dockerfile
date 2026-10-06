FROM ubuntu:24.04
LABEL org.opencontainers.image.source="https://github.com/DebelToni/school-shell" \
      org.opencontainers.image.description="Minimal Ubuntu school development shell"
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    neovim zsh tmux build-essential gdb cmake git curl ca-certificates \
    openssh-client sudo less locales ripgrep unzip \
    && locale-gen en_US.UTF-8 \
    && userdel ubuntu \
    && useradd -m -u 1000 -s /usr/bin/zsh student \
    && printf 'student ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/student \
    && chmod 0440 /etc/sudoers.d/student \
    && rm -rf /var/lib/apt/lists/*
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 TERM=xterm-256color
USER student
WORKDIR /home/student
CMD ["sleep", "infinity"]

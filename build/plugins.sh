#!/usr/bin/env bash
set -euo pipefail
mkdir -p /opt/nvim-plugins
jq -r 'to_entries[] | [.key, .value] | @tsv' /build/plugins.json |
while IFS=$'\t' read -r name repo; do
    commit=$(jq -r --arg name "$name" '.[$name].commit' /opt/my-vim-env/school/lazy-lock.json)
    git init -q "/opt/nvim-plugins/$name"
    git -C "/opt/nvim-plugins/$name" remote add origin "https://github.com/$repo.git"
    git -C "/opt/nvim-plugins/$name" fetch -q --depth 1 origin "$commit"
    git -C "/opt/nvim-plugins/$name" checkout -q --detach FETCH_HEAD
done

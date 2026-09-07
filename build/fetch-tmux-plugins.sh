#!/usr/bin/env bash
# Populate overlay/etc/skel/.tmux/plugins with TPM and the session plugins.
#
# These are third-party repositories, so they are fetched rather than vendored.
# Commits are pinned for reproducibility; bump them deliberately.
set -Eeuo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/overlay/etc/skel/.tmux/plugins"
install -d "$DIR"

fetch() {
    local name="$1" commit="$2" url="https://github.com/tmux-plugins/${1}.git"
    if [[ -d $DIR/$name/.git ]] && [[ $(git -C "$DIR/$name" rev-parse HEAD 2>/dev/null) == "$commit"* ]]; then
        echo "  $name already at $commit"; return
    fi
    rm -rf "${DIR:?}/$name"
    git clone --quiet "$url" "$DIR/$name"
    git -C "$DIR/$name" checkout --quiet "$commit"
    printf '  %-16s %s\n' "$name" "$(git -C "$DIR/$name" rev-parse --short HEAD)"
}

fetch tpm            e261deb
fetch tmux-resurrect cff343c
fetch tmux-continuum 0698e8f
echo "tmux plugins ready in $DIR"

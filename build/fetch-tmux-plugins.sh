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
    local short; short="$(git -C "$DIR/$name" rev-parse --short HEAD)"
    prune "$DIR/$name" "$short"
    printf '  %-16s %s\n' "$name" "$short"
}

# Everything here is copied into /etc/skel and then again into every account, so
# it is paid for per user. Upstream ships a full git repository, its test suite,
# its documentation and -- in tmux-resurrect -- a video/ directory of PNGs, none
# of which a running tmux ever reads. TPM only needs git to INSTALL a plugin, and
# all three are already installed, so the .git directories are dead weight too.
#
# The pinned commit is written to PINNED_COMMIT so the version is still knowable
# on the device after .git is gone.
prune() {
    local d="$1" commit="$2"
    printf '%s\n' "$commit" > "$d/PINNED_COMMIT"
    # scripts/ is left ENTIRELY alone. An earlier version of this also removed
    # scripts/handle_tmux_automatic_start/, reasoning that it is macOS-specific
    # and @continuum-boot is deliberately unset here. Both true, and it still
    # broke: continuum.tmux calls handle_tmux_automatic_start on every load, and
    # with the boot option off it takes the DISABLE branch into
    # handle_tmux_automatic_start/systemd_disable.sh. Unused-looking and unused
    # are different things.
    rm -rf "$d/.git" "$d/tests" "$d/docs" "$d/video" \
           "$d/.travis.yml" "$d/.gitattributes" "$d/.gitmodules" \
           "$d/CONTRIBUTING.md" "$d/CHANGELOG.md"
}

fetch tpm            e261deb
fetch tmux-resurrect cff343c
fetch tmux-continuum 0698e8f
echo "tmux plugins ready in $DIR"

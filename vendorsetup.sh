#!/bin/bash
#
# nabu: device specific source patches.
# Sourced by build/envsetup.sh, so keep it fast and idempotent.
# Keep it shell agnostic: envsetup.sh may be sourced from zsh.

nabu_top="${ANDROID_BUILD_TOP:-$(pwd)}"
nabu_patches="$nabu_top/device/xiaomi/nabu/patches"

nabu_apply_patch() {
    local repo="$nabu_top/$1"
    local patch="$nabu_patches/$2"

    if [ ! -d "$repo" ]; then
        echo "nabu: skipping $2: repo $repo not found"
        return 0
    fi

    if [ ! -f "$patch" ]; then
        echo "nabu: skipping $2: patch $patch not found"
        return 0
    fi

    if git -C "$repo" apply --reverse --check "$patch" >/dev/null 2>&1; then
        return 0    # already applied
    fi

    if git -C "$repo" apply --check "$patch" >/dev/null 2>&1; then
        git -C "$repo" apply "$patch" && echo "nabu: applied $2"
    else
        echo "nabu: WARNING: $2 does not apply to $1, fix it or resync"
    fi
}

nabu_apply_patch packages/apps/Evolver 0001-Evolver-PowerMenuActions-null-category.patch

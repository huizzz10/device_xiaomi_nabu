#!/bin/sh
#
# Apply the device specific source patches.
#
# Idempotent: already applied patches are skipped, and a patch that no longer
# applies only prints a warning so the build itself keeps going.
#
# Called from vendorsetup.sh and from device.mk ($(shell)), so keep it shell
# agnostic and fast.

nabu_top="${ANDROID_BUILD_TOP:-$(pwd)}"
nabu_patches="$nabu_top/device/xiaomi/nabu/patches"

nabu_apply_patch() {
    repo="$nabu_top/$1"
    patch="$nabu_patches/$2"

    if [ ! -d "$repo" ]; then
        echo "nabu: skipping $2: repo $repo not found" >&2
        return 0
    fi

    if [ ! -f "$patch" ]; then
        echo "nabu: skipping $2: patch $patch not found" >&2
        return 0
    fi

    if git -C "$repo" apply --reverse --check "$patch" >/dev/null 2>&1; then
        return 0    # already applied
    fi

    if git -C "$repo" apply --check "$patch" >/dev/null 2>&1; then
        git -C "$repo" apply "$patch" && echo "nabu: applied $2" >&2
    else
        echo "nabu: WARNING: $2 does not apply to $1, fix it or resync" >&2
    fi
}

nabu_apply_patch packages/apps/Evolver 0001-Evolver-PowerMenuActions-null-category.patch

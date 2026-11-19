#!/bin/sh
#
# Apply the device specific source patches.
#
# Safe to run from any shell, any working directory and any number of
# concurrent builds: already applied patches are skipped, a patch that no
# longer applies only prints a warning (the build keeps going), and losing a
# race against another build is not reported as a failure.
#
# Invoked by vendorsetup.sh (envsetup) and by device.mk ($(shell)) at build
# time, so keep it shell agnostic and fast.

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 0
nabu_dir=$(dirname "$script_dir")                  # .../device/xiaomi/nabu
tree_top=$(CDPATH= cd -- "$nabu_dir/../../.." && pwd) || tree_top=$(pwd)

nabu_top="${ANDROID_BUILD_TOP:-$tree_top}"
nabu_patches="$script_dir"

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
        if git -C "$repo" apply "$patch" 2>/dev/null; then
            echo "nabu: applied $2" >&2
        elif git -C "$repo" apply --reverse --check "$patch" >/dev/null 2>&1; then
            : # another build applied it first
        else
            echo "nabu: WARNING: failed to apply $2 to $1" >&2
        fi
    else
        echo "nabu: WARNING: $2 does not apply to $1, fix it or resync" >&2
    fi
}

nabu_apply_patch packages/apps/Evolver 0001-Evolver-PowerMenuActions-null-category.patch
nabu_apply_patch packages/apps/Settings 0002-Settings-maintainer-github-profile.patch
nabu_apply_patch packages/apps/Settings 0003-Settings-nabu-device-image.patch

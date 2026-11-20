#!/bin/sh
#
# Apply the device specific source patches.
#
# Safe to run from any shell, any working directory and any number of
# concurrent builds: already applied patches are skipped, and losing a
# race against another build is not reported as a failure.
#
# Anything else (missing repo, missing patch file, stale patch that no longer
# applies) is a hard failure: a patch that cannot be applied must break the
# build instead of silently shipping a tree without the change.  device.mk
# turns the exit status into a make error, vendorsetup.sh reports it during
# envsetup.
#
# Invoked by vendorsetup.sh (envsetup) and by device.mk ($(shell)) at build
# time, so keep it shell agnostic and fast.

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || {
    echo "nabu: ERROR: cannot resolve the patch directory" >&2
    exit 1
}
nabu_dir=$(dirname "$script_dir")                  # .../device/xiaomi/nabu
tree_top=$(CDPATH= cd -- "$nabu_dir/../../.." && pwd) || tree_top=$(pwd)

nabu_top="${ANDROID_BUILD_TOP:-$tree_top}"
nabu_patches="$script_dir"
nabu_failed=0

nabu_fail() {
    echo "nabu: ERROR: $*" >&2
    nabu_failed=1
}

nabu_apply_patch() {
    repo="$nabu_top/$1"
    patch="$nabu_patches/$2"

    if [ ! -d "$repo" ]; then
        nabu_fail "$2: repo $1 not found under $nabu_top, resync it"
        return 0
    fi

    if [ ! -f "$patch" ]; then
        nabu_fail "$2: patch file not found in $nabu_patches"
        return 0
    fi

    if git -C "$repo" apply --reverse --check "$patch" >/dev/null 2>&1; then
        return 0    # already applied
    fi

    if ! git -C "$repo" apply --check "$patch" >/dev/null 2>&1; then
        nabu_fail "$2 does not apply to $1, the patch is stale, rebase it on the current tree"
        return 0
    fi

    if git -C "$repo" apply "$patch" 2>/dev/null; then
        echo "nabu: applied $2" >&2
        return 0
    fi

    if git -C "$repo" apply --reverse --check "$patch" >/dev/null 2>&1; then
        return 0    # another build applied it first
    fi

    nabu_fail "$2 failed to apply to $1"
}

nabu_apply_patch packages/apps/Evolver 0001-Evolver-PowerMenuActions-null-category.patch
nabu_apply_patch packages/apps/Settings 0002-Settings-maintainer-github-profile.patch
nabu_apply_patch packages/apps/Settings 0003-Settings-nabu-device-image.patch
nabu_apply_patch packages/apps/Updater 0004-Updater-zh-rCN-strings.patch

if [ "$nabu_failed" -ne 0 ]; then
    echo "nabu: ERROR: device source patches did not apply cleanly, fix device/xiaomi/nabu/patches or resync the affected repos" >&2
    exit 1
fi

exit 0

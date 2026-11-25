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
# Every run ends with one summary line, so a build log answers "were all the
# patches applied?" without cross referencing the individual messages:
#
#   nabu: device source patches: 4 total, 1 applied now, 3 already applied
#   nabu: ERROR: device source patches: 4 total, 1 applied now, 2 already
#         applied, 1 FAILED: 0004-Updater-zh-rCN-strings.patch
#
# The per patch "nabu: applied <patch>" line is only printed for a patch this
# run actually changed, which is why a log that shows a single applied line
# means the other patches were already in the tree (the summary counts them).
#
# Options:
#   -q, --quiet   print the summary only when something was applied or failed
#   --status      report the state of every patch, change nothing (exit 0 only
#                 when all of them are already applied)
#
# Invoked by vendorsetup.sh (envsetup) and by device.mk ($(shell)) at build
# time, so keep it shell agnostic and fast.

usage() {
    cat <<'USAGE'
usage: apply.sh [-q|--quiet] [--status]

  -q, --quiet   only print the summary when a patch was applied or failed
  --status      report the state of every patch and change nothing
USAGE
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || {
    echo "nabu: ERROR: cannot resolve the patch directory" >&2
    exit 1
}
nabu_dir=$(dirname "$script_dir")                  # .../device/xiaomi/nabu
tree_top=$(CDPATH= cd -- "$nabu_dir/../../.." && pwd) || tree_top=$(pwd)

nabu_top="${ANDROID_BUILD_TOP:-$tree_top}"
nabu_patches="$script_dir"

nabu_failed=0
nabu_total=0
nabu_applied=0
nabu_skipped=0
nabu_failed_count=0
nabu_failed_patches=""
nabu_quiet=0
nabu_status_only=0

for nabu_arg in "$@"; do
    case "$nabu_arg" in
        -q|--quiet) nabu_quiet=1 ;;
        --status)   nabu_status_only=1 ;;
        -h|--help)  usage; exit 0 ;;
        *)          echo "nabu: ERROR: unknown option '$nabu_arg'" >&2
                    usage >&2
                    exit 2 ;;
    esac
done

# The patch list lives in one place so the apply and status modes cannot drift
# apart.  Order matters only for the log; patches target independent trees.
nabu_patch_list() {
    cat <<'LIST'
packages/apps/Evolver  0001-Evolver-PowerMenuActions-null-category.patch
packages/apps/Settings 0002-Settings-maintainer-github-profile.patch
packages/apps/Settings 0003-Settings-nabu-device-image.patch
packages/apps/Updater  0004-Updater-zh-rCN-strings.patch
packages/apps/Settings 0005-Settings-translatable-mock-location-summaries.patch
LIST
}

nabu_fail() {                       # $1 = patch, $2 = message
    echo "nabu: ERROR: $2" >&2
    nabu_failed=1
    nabu_failed_count=$((nabu_failed_count + 1))
    nabu_failed_patches="$nabu_failed_patches $1"
}

# applied  -> the tree already carries the change
# pending  -> it applies cleanly but is not in the tree yet
# stale    -> neither direction applies: the patch or the tree moved
# missing  -> repo or patch file is absent
nabu_patch_state() {                # $1 = repo, $2 = patch, sets nabu_state
    nabu_state_repo="$nabu_top/$1"
    nabu_state_patch="$nabu_patches/$2"

    if [ ! -d "$nabu_state_repo" ]; then
        nabu_state=missing-repo
    elif [ ! -f "$nabu_state_patch" ]; then
        nabu_state=missing-patch
    elif git -C "$nabu_state_repo" apply --reverse --check "$nabu_state_patch" >/dev/null 2>&1; then
        nabu_state=applied
    elif git -C "$nabu_state_repo" apply --check "$nabu_state_patch" >/dev/null 2>&1; then
        nabu_state=pending
    else
        nabu_state=stale
    fi
}

nabu_apply_patch() {                # $1 = repo, $2 = patch
    repo="$nabu_top/$1"
    patch="$nabu_patches/$2"

    if [ ! -d "$repo" ]; then
        nabu_fail "$2" "$2: repo $1 not found under $nabu_top, resync it"
        return 0
    fi

    if [ ! -f "$patch" ]; then
        nabu_fail "$2" "$2: patch file not found in $nabu_patches"
        return 0
    fi

    if git -C "$repo" apply --reverse --check "$patch" >/dev/null 2>&1; then
        nabu_skipped=$((nabu_skipped + 1))
        return 0    # already applied
    fi

    if ! git -C "$repo" apply --check "$patch" >/dev/null 2>&1; then
        nabu_fail "$2" "$2 does not apply to $1, the patch is stale, rebase it on the current tree"
        return 0
    fi

    if git -C "$repo" apply "$patch" 2>/dev/null; then
        nabu_applied=$((nabu_applied + 1))
        echo "nabu: applied $2" >&2
        return 0
    fi

    if git -C "$repo" apply --reverse --check "$patch" >/dev/null 2>&1; then
        nabu_skipped=$((nabu_skipped + 1))
        return 0    # another build applied it first
    fi

    nabu_fail "$2" "$2 failed to apply to $1"
}

nabu_summary() {
    if [ "$nabu_failed_count" -eq 0 ]; then
        [ "$nabu_quiet" -eq 1 ] && [ "$nabu_applied" -eq 0 ] && return 0
        echo "nabu: device source patches: $nabu_total total, $nabu_applied applied now, $nabu_skipped already applied" >&2
    else
        # shellcheck disable=SC2086  # patch names never contain spaces
        echo "nabu: ERROR: device source patches: $nabu_total total, $nabu_applied applied now, $nabu_skipped already applied, $nabu_failed_count FAILED:$nabu_failed_patches" >&2
    fi
}

# Iterate "repo patch" pairs as positional parameters: a pipe would run the
# loop in a subshell (losing the counters) and a command substitution would
# eat the trailing newline (losing the last pair).
set -- $(nabu_patch_list)

if [ "$nabu_status_only" -eq 1 ]; then
    nabu_bad=0
    nabu_ok=0
    while [ $# -ge 2 ]; do
        nabu_patch_state "$1" "$2"
        printf '  %-12s %-52s %s\n' "$nabu_state" "$2" "$1"
        if [ "$nabu_state" = applied ]; then
            nabu_ok=$((nabu_ok + 1))
        else
            nabu_bad=$((nabu_bad + 1))
        fi
        shift 2
    done
    echo "nabu: device source patches: $nabu_ok of $((nabu_ok + nabu_bad)) applied" >&2
    [ "$nabu_bad" -eq 0 ] || exit 1
    exit 0
fi

while [ $# -ge 2 ]; do
    nabu_total=$((nabu_total + 1))
    nabu_apply_patch "$1" "$2"
    shift 2
done

nabu_summary

if [ "$nabu_failed" -ne 0 ]; then
    echo "nabu: ERROR: device source patches did not apply cleanly, fix device/xiaomi/nabu/patches or resync the affected repos" >&2
    exit 1
fi

exit 0

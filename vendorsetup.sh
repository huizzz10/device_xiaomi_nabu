#!/bin/sh
#
# Sourced by build/envsetup.sh.  ANDROID_BUILD_TOP is exported by envsetup
# before vendorsetup files are sourced, so this works from any shell (zsh
# included).  device.mk runs the same script at build time as well.

nabu_top="${ANDROID_BUILD_TOP:-$(pwd)}"
if [ -x "$nabu_top/device/xiaomi/nabu/patches/apply.sh" ]; then
    if ! "$nabu_top/device/xiaomi/nabu/patches/apply.sh"; then
        echo "nabu: ERROR: device source patches failed to apply, fix device/xiaomi/nabu/patches or resync before building." >&2
        return 1 2>/dev/null || exit 1
    fi
fi

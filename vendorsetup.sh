#!/bin/sh
#
# Sourced by build/envsetup.sh.  ANDROID_BUILD_TOP is exported by envsetup
# before vendorsetup files are sourced, so this works from any shell (zsh
# included).  device.mk runs the same script at build time as well.

nabu_top="${ANDROID_BUILD_TOP:-$(pwd)}"
if [ -x "$nabu_top/device/xiaomi/nabu/patches/apply.sh" ]; then
    "$nabu_top/device/xiaomi/nabu/patches/apply.sh"
fi

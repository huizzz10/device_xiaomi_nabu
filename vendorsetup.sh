#!/bin/sh
#
# Sourced by build/envsetup.sh.  The same script is also invoked from
# device.mk at build time, so this only makes the patch available a bit
# earlier for interactive shells.

nabu_top="${ANDROID_BUILD_TOP:-$(pwd)}"
"$nabu_top/device/xiaomi/nabu/patches/apply.sh"

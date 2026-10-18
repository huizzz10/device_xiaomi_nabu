/*
 * Copyright (C) 2026 Neokoni <dulin081682@126.com>
 *
 * SPDX-License-Identifier: Apache-2.0
 */
package com.harshit.nabuextensions

import android.content.Context
import android.provider.Settings
import android.util.Log

/**
 * Cover flap policy: closing the flap must turn the screen off, as on any
 * other tablet, and there is no way to disable it.
 *
 * The kernel reports the flap as a regular SW_LID switch, so the framework
 * handles it through the global lid_behavior setting. The
 * config_lidControlsSleep overlay only seeds that setting when the settings
 * database is first created; pin it on every boot as well, which also
 * migrates devices that still carry a disabled value from the old cover
 * flap switch.
 */
object CoverFlapUtils {

    private val TAG = CoverFlapUtils::class.java.simpleName

    // WindowManagerPolicy.WindowManagerFuncs.LID_BEHAVIOR_SLEEP
    private const val LID_BEHAVIOR_SLEEP = 1

    /**
     * Force lid_behavior to sleep. Global settings live in device protected
     * storage, so this works from LOCKED_BOOT_COMPLETED.
     */
    fun enforceSleepOnLidClose(context: Context) {
        val resolver = context.contentResolver
        val current = Settings.Global.getInt(
            resolver,
            Settings.Global.LID_BEHAVIOR,
            LID_BEHAVIOR_SLEEP
        )
        if (current == LID_BEHAVIOR_SLEEP) {
            return
        }

        try {
            Settings.Global.putInt(
                resolver,
                Settings.Global.LID_BEHAVIOR,
                LID_BEHAVIOR_SLEEP
            )
            Log.i(TAG, "Lid behavior pinned to sleep ($current -> $LID_BEHAVIOR_SLEEP)")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to pin lid behavior to sleep", e)
        }
    }
}

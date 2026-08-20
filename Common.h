//  Copyright (c) 2021 udevs
//
//  This file is subject to the terms and conditions defined in
//  file 'LICENSE', which is part of this source code package.

#include <Foundation/Foundation.h>
#include <objc/runtime.h>
#include <roothide.h>

#define VEDETTE_IDENTIFIER @"com.udevs.vedette"
#define PREFS_PATH @"/var/mobile/Library/Preferences/com.udevs.vedette.plist"
#define PREFS_PATH_TMP @"/var/tmp/com.udevs.vedette.plist"

#define NOTIFY_PID_NN "com.udevs.vedette.notify-pid"
#define PREFS_CHANGED_NN @"com.udevs.vedette.prefschanged"
#define RESTORE_ALL_MONITORS_NN @"com.udevs.vedette.restore-all-monitors"

// One shared sampler is created only while at least one immediate target is alive.
#define VDT_IMMEDIATE_SAMPLE_INTERVAL_NSEC (250ull * NSEC_PER_MSEC)
#define VDT_IMMEDIATE_SAMPLE_LEEWAY_NSEC (25ull * NSEC_PER_MSEC)
#define VDT_IMMEDIATE_STARTUP_GRACE_NSEC (1500ull * NSEC_PER_MSEC)
#define VDT_IMMEDIATE_REQUIRED_VIOLATIONS 1
#define VDT_MAX_CPU_PERCENTAGE 800

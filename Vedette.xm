//  Copyright (c) 2021 udevs
//
//  This file is subject to the terms and conditions defined in
//  file 'LICENSE', which is part of this source code package.

#import "Common.h"
#import "VDTProcessManager.h"
#import "VDTShared.h"

#include <notify.h>

static int notifyPIDToken;

static void notify_new_pid(const char *notificationName, uint64_t pid){
    int token = 0;
    if (notify_register_check(notificationName, &token) != NOTIFY_STATUS_OK){
        return;
    }
    notify_set_state(token, pid);
    notify_post(notificationName);
    notify_cancel(token);
}

static void preferences_changed_callback(CFNotificationCenterRef center,
                                         void *observer,
                                         CFStringRef name,
                                         const void *object,
                                         CFDictionaryRef userInfo){
    @autoreleasepool {
        prefs = getPrefs();
        update_process_preferences(prefs);
    }
}

static void restore_monitors_callback(CFNotificationCenterRef center,
                                      void *observer,
                                      CFStringRef name,
                                      const void *object,
                                      CFDictionaryRef userInfo){
    restore_all_managed_processes();
    [[NSFileManager defaultManager] removeItemAtPath:PREFS_PATH_TMP error:nil];
}

%ctor {
    @autoreleasepool {
        NSProcessInfo *processInfo = [NSProcessInfo processInfo];
        NSString *executablePath = processInfo.arguments.firstObject;
        if (executablePath.length == 0){
            return;
        }

        NSString *processName = executablePath.lastPathComponent;
        if ([processName isEqualToString:@"runningboardd"]){
            prefs = getPrefs();
            update_process_preferences(prefs);

            notify_register_dispatch(
                NOTIFY_PID_NN,
                &notifyPIDToken,
                dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
                ^(int token){
                    uint64_t pid = 0;
                    if (notify_get_state(token, &pid) == NOTIFY_STATUS_OK && pid > 0 && pid <= INT32_MAX){
                        received_new_proc((pid_t)pid);
                    }
                }
            );
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                NULL,
                preferences_changed_callback,
                (CFStringRef)PREFS_CHANGED_NN,
                NULL,
                CFNotificationSuspensionBehaviorDeliverImmediately
            );
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                NULL,
                restore_monitors_callback,
                (CFStringRef)RESTORE_ALL_MONITORS_NN,
                NULL,
                CFNotificationSuspensionBehaviorDeliverImmediately
            );
            return;
        }

        BOOL currentProcessIsApplication =
            [executablePath containsString:@"/Application"] ||
            [executablePath containsString:@"/CoreServices"];
        NSString *currentProcessIdentifier = currentProcessIsApplication
            ? NSBundle.mainBundle.bundleIdentifier
            : processName;

        if (currentProcessIsApplication && [currentProcessIdentifier isEqualToString:@"com.apple.Preferences"]){
            return;
        }

        // Sandboxed apps cannot reliably read Vedette's preferences outside
        // their container. Announce this PID once at process startup and let
        // runningboardd, which owns the monitor, read and enforce the config.
        // Disabled targets are rejected there before any CPU timer is created.
        notify_new_pid(NOTIFY_PID_NN, (uint64_t)getpid());
    }
}

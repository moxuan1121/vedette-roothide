//  Copyright (c) 2021 udevs
//
//  This file is subject to the terms and conditions defined in
//  file 'LICENSE', which is part of this source code package.

#import "Common.h"
#import "VDTProcessManager.h"
#import "VDTShared.h"

#include <notify.h>

static int notifyPIDToken;
static BOOL currentProcessIsApplication;
static NSString *currentProcessIdentifier;

static void notify_new_pid(const char *notificationName, uint64_t pid){
    int token = 0;
    if (notify_register_check(notificationName, &token) != NOTIFY_STATUS_OK){
        return;
    }
    notify_set_state(token, pid);
    notify_post(notificationName);
    notify_cancel(token);
}

static BOOL master_enabled_in_preferences(NSDictionary *currentPrefs){
    id enabledValue = valueForKeyWithPrefs(@"enabled", currentPrefs);
    return enabledValue ? [enabledValue boolValue] : YES;
}

static void notify_current_process_if_enabled(void){
    if (currentProcessIdentifier.length == 0){
        return;
    }

    NSDictionary *currentPrefs = getPrefs();
    VDTConfigType type = currentProcessIsApplication ? VDTConfigTypeApp : VDTConfigTypeDaemon;
    BOOL processEnabled = [valueForProcessConfigKeyWithPrefs(
        currentProcessIdentifier, @"enabled", @NO, type, currentPrefs
    ) boolValue];
    if (master_enabled_in_preferences(currentPrefs) && processEnabled){
        notify_new_pid(NOTIFY_PID_NN, (uint64_t)getpid());
    }
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

static void self_preferences_changed_callback(CFNotificationCenterRef center,
                                              void *observer,
                                              CFStringRef name,
                                              const void *object,
                                              CFDictionaryRef userInfo){
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            notify_current_process_if_enabled();
        }
    });
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

        currentProcessIsApplication =
            [executablePath containsString:@"/Application"] ||
            [executablePath containsString:@"/CoreServices"];
        currentProcessIdentifier = currentProcessIsApplication
            ? NSBundle.mainBundle.bundleIdentifier
            : processName;

        if (currentProcessIsApplication && [currentProcessIdentifier isEqualToString:@"com.apple.Preferences"]){
            return;
        }

        // This observer does no CPU work. It only lets an already-running target
        // announce itself when the user enables it, avoiding a system-wide PID scan.
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            self_preferences_changed_callback,
            (CFStringRef)PREFS_CHANGED_NN,
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately
        );
        notify_current_process_if_enabled();
    }
}

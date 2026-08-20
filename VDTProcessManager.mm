//  Copyright (c) 2021 udevs
//
//  This file is subject to the terms and conditions defined in
//  file 'LICENSE', which is part of this source code package.

#import "VDTProcessManager.h"
#import "VDTShared.h"
#import "PrivateHeaders.h"

#include <errno.h>
#include <mach/mach_time.h>
#include <signal.h>
#include <sys/resource.h>
#include <unistd.h>

NSDictionary *prefs;

@interface VDTManagedProcess : NSObject
@property(nonatomic) pid_t pid;
@property(nonatomic) VDTConfigType type;
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *executablePath;
@property(nonatomic) uint64_t startTime;
@property(nonatomic) uint64_t previousCPUTime;
@property(nonatomic) uint64_t previousSampleTime;
@property(nonatomic) uint64_t monitoringStartTime;
@property(nonatomic) NSUInteger consecutiveViolations;
@property(nonatomic) NSUInteger percentage;
@end

@implementation VDTManagedProcess
@end

static dispatch_queue_t processQueue;
static dispatch_source_t immediateTimer;
static NSMutableDictionary<NSNumber *, VDTManagedProcess *> *managedProcesses;
static NSDictionary *managerPrefs;
static uint64_t startupGraceAbsoluteTicks;

static void initialize_process_manager(void){
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        processQueue = dispatch_queue_create("com.udevs.vedette.process-monitor", DISPATCH_QUEUE_SERIAL);
        managedProcesses = [NSMutableDictionary dictionary];
        mach_timebase_info_data_t timebaseInfo;
        mach_timebase_info(&timebaseInfo);
        startupGraceAbsoluteTicks =
            (VDT_IMMEDIATE_STARTUP_GRACE_NSEC * timebaseInfo.denom) / timebaseInfo.numer;
    });
}

static BOOL copy_process_rusage(pid_t pid, struct rusage_info_v2 *usage){
    if (pid <= 0 || usage == NULL){
        return NO;
    }
    memset(usage, 0, sizeof(*usage));
    return proc_pid_rusage(pid, RUSAGE_INFO_V2, (rusage_info_t *)usage) == 0;
}

static NSString *executable_path_from_pid(pid_t pid){
    char pathBuffer[PROC_PIDPATHINFO_MAXSIZE] = {0};
    int pathLength = proc_pidpath(pid, pathBuffer, sizeof(pathBuffer));
    if (pathLength <= 0){
        return nil;
    }
    return [NSString stringWithUTF8String:pathBuffer];
}

static NSString *name_from_pid(pid_t pid){
    char nameBuffer[256] = {0};
    if (proc_name(pid, nameBuffer, sizeof(nameBuffer)) <= 0){
        return nil;
    }
    return [NSString stringWithUTF8String:nameBuffer];
}

static NSString *application_bundle_path_from_executable_path(NSString *path){
    if (path.length == 0){
        return nil;
    }

    NSArray<NSString *> *components = path.pathComponents;
    NSUInteger appIndex = NSNotFound;
    for (NSUInteger idx = 0; idx < components.count; idx++){
        if ([components[idx].pathExtension.lowercaseString isEqualToString:@"app"]){
            appIndex = idx;
            break;
        }
    }
    if (appIndex == NSNotFound){
        return nil;
    }
    return [NSString pathWithComponents:[components subarrayWithRange:NSMakeRange(0, appIndex + 1)]];
}

static NSString *bundle_identifier_from_executable_path(NSString *path){
    NSString *bundlePath = application_bundle_path_from_executable_path(path);
    if (bundlePath.length == 0){
        return nil;
    }

    NSString *bundleIdentifier = [NSBundle bundleWithPath:bundlePath].bundleIdentifier;
    if (bundleIdentifier.length > 0){
        return bundleIdentifier;
    }

    LSApplicationProxy *proxy = [objc_getClass("LSApplicationProxy") applicationProxyForBundleURL:[NSURL fileURLWithPath:bundlePath]];
    return proxy.bundleIdentifier;
}

static VDTManagedProcess *process_identity_from_pid(pid_t pid){
    struct rusage_info_v2 usage;
    NSString *path = executable_path_from_pid(pid);
    if (path.length == 0 || !copy_process_rusage(pid, &usage)){
        return nil;
    }

    VDTManagedProcess *process = [VDTManagedProcess new];
    process.pid = pid;
    process.executablePath = path;
    process.startTime = usage.ri_proc_start_abstime;

    NSString *bundleIdentifier = bundle_identifier_from_executable_path(path);
    if (bundleIdentifier.length > 0){
        process.type = VDTConfigTypeApp;
        process.identifier = bundleIdentifier;
    }else{
        process.type = VDTConfigTypeDaemon;
        process.identifier = name_from_pid(pid);
    }

    if (process.identifier.length == 0){
        return nil;
    }
    return process;
}

static BOOL identity_matches_process(VDTManagedProcess *expected, struct rusage_info_v2 *usageOut){
    if (!expected || expected.pid <= 0){
        return NO;
    }

    struct rusage_info_v2 usage;
    if (!copy_process_rusage(expected.pid, &usage) || usage.ri_proc_start_abstime != expected.startTime){
        return NO;
    }

    NSString *path = executable_path_from_pid(expected.pid);
    if (path.length == 0 || ![path isEqualToString:expected.executablePath]){
        return NO;
    }

    NSString *currentIdentifier = expected.type == VDTConfigTypeApp
        ? bundle_identifier_from_executable_path(path)
        : name_from_pid(expected.pid);
    if (currentIdentifier.length == 0 || ![currentIdentifier isEqualToString:expected.identifier]){
        return NO;
    }

    if (usageOut){
        *usageOut = usage;
    }
    return YES;
}

static BOOL global_monitoring_enabled(void){
    id enabledValue = valueForKeyWithPrefs(@"enabled", managerPrefs);
    return enabledValue ? [enabledValue boolValue] : YES;
}

static BOOL process_config_enabled(VDTManagedProcess *process){
    return global_monitoring_enabled() &&
        [valueForProcessConfigKeyWithPrefs(process.identifier, @"enabled", @NO, process.type, managerPrefs) boolValue];
}

static NSUInteger configured_percentage(VDTManagedProcess *process){
    NSInteger percentage = [valueForProcessConfigKeyWithPrefs(
        process.identifier,
        @"percentage",
        @80,
        process.type,
        managerPrefs
    ) integerValue];
    return (NSUInteger)MAX(1, MIN(VDT_MAX_CPU_PERCENTAGE, percentage));
}

static NSUInteger immediate_process_count(void){
    return managedProcesses.count;
}

static void stop_immediate_timer_if_idle(void){
    if (immediateTimer && immediate_process_count() == 0){
        dispatch_source_cancel(immediateTimer);
        immediateTimer = nil;
    }
}

static void remove_managed_process(NSNumber *pidKey){
    [managedProcesses removeObjectForKey:pidKey];
    stop_immediate_timer_if_idle();
}

static BOOL immediate_policy_still_enabled(VDTManagedProcess *process){
    return process_config_enabled(process) &&
        !VDTIsProtectedProcessIdentifier(process.identifier) &&
        !VDTIsProtectedProcessIdentifier(process.executablePath.lastPathComponent);
}

static void sample_immediate_processes(void){
    uint64_t now = mach_absolute_time();
    NSArray<NSNumber *> *pidKeys = managedProcesses.allKeys.copy;

    for (NSNumber *pidKey in pidKeys){
        VDTManagedProcess *process = managedProcesses[pidKey];
        struct rusage_info_v2 usage;
        if (!copy_process_rusage(process.pid, &usage) ||
            usage.ri_proc_start_abstime != process.startTime ||
            !immediate_policy_still_enabled(process)){
            remove_managed_process(pidKey);
            continue;
        }

        uint64_t currentCPUTime = usage.ri_user_time + usage.ri_system_time;
        uint64_t elapsedAbsolute = now - process.previousSampleTime;
        uint64_t elapsedCPU = currentCPUTime >= process.previousCPUTime
            ? currentCPUTime - process.previousCPUTime
            : 0;

        process.previousCPUTime = currentCPUTime;
        process.previousSampleTime = now;

        // Ignore normal launch bursts, but keep advancing the CPU baseline so
        // the first post-grace sample contains only its own sampling window.
        if (now - process.monitoringStartTime < startupGraceAbsoluteTicks){
            process.consecutiveViolations = 0;
            continue;
        }

        // ri_user_time, ri_system_time, and mach_absolute_time are all Mach
        // absolute-time ticks. Dividing them directly keeps the units equal.
        double cpuPercentage = elapsedAbsolute > 0
            ? ((double)elapsedCPU * 100.0) / (double)elapsedAbsolute
            : 0.0;

        if (cpuPercentage >= (double)process.percentage){
            process.consecutiveViolations++;
        }else{
            process.consecutiveViolations = 0;
        }

        if (process.consecutiveViolations < VDT_IMMEDIATE_REQUIRED_VIOLATIONS){
            continue;
        }

        // Re-read identity immediately before SIGKILL. This rejects an exited
        // process, a reused PID, a changed config, and every protected target.
        if (!identity_matches_process(process, NULL) || !immediate_policy_still_enabled(process)){
            remove_managed_process(pidKey);
            continue;
        }

        if (kill(process.pid, SIGKILL) == 0 || errno == ESRCH){
            remove_managed_process(pidKey);
        }
    }
}

static void ensure_immediate_timer(void){
    if (immediateTimer || immediate_process_count() == 0){
        return;
    }

    immediateTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, processQueue);
    dispatch_source_set_timer(
        immediateTimer,
        dispatch_time(DISPATCH_TIME_NOW, VDT_IMMEDIATE_SAMPLE_INTERVAL_NSEC),
        VDT_IMMEDIATE_SAMPLE_INTERVAL_NSEC,
        VDT_IMMEDIATE_SAMPLE_LEEWAY_NSEC
    );
    dispatch_source_set_event_handler(immediateTimer, ^{
        @autoreleasepool {
            sample_immediate_processes();
        }
    });
    dispatch_resume(immediateTimer);
}

static void apply_configuration(VDTManagedProcess *process){
    if (!identity_matches_process(process, NULL) || !process_config_enabled(process)){
        remove_managed_process(@(process.pid));
        return;
    }

    if (VDTIsProtectedProcessIdentifier(process.identifier) ||
        VDTIsProtectedProcessIdentifier(process.executablePath.lastPathComponent)){
        remove_managed_process(@(process.pid));
        return;
    }

    struct rusage_info_v2 usage;
    if (!identity_matches_process(process, &usage)){
        remove_managed_process(@(process.pid));
        return;
    }
    process.percentage = configured_percentage(process);
    if (process.previousSampleTime == 0){
        uint64_t now = mach_absolute_time();
        process.previousCPUTime = usage.ri_user_time + usage.ri_system_time;
        process.previousSampleTime = now;
        process.monitoringStartTime = now;
        process.consecutiveViolations = 0;
    }
    ensure_immediate_timer();
}

void update_process_preferences(NSDictionary *newPrefs){
    initialize_process_manager();
    NSDictionary *prefsCopy = [newPrefs copy] ?: @{};
    dispatch_async(processQueue, ^{
        managerPrefs = prefsCopy;
        NSArray<NSNumber *> *pidKeys = managedProcesses.allKeys.copy;
        for (NSNumber *pidKey in pidKeys){
            VDTManagedProcess *process = managedProcesses[pidKey];
            if (!identity_matches_process(process, NULL)){
                remove_managed_process(pidKey);
                continue;
            }
            apply_configuration(process);
        }
        stop_immediate_timer_if_idle();
    });
}

void received_new_proc(pid_t pid){
    if (pid <= 0){
        return;
    }
    initialize_process_manager();
    NSDictionary *freshPrefs = getPrefs();
    dispatch_async(processQueue, ^{
        // Reading here closes the race between the preference-change callback
        // and an already-running process announcing that it was just enabled.
        managerPrefs = freshPrefs;
        VDTManagedProcess *process = process_identity_from_pid(pid);
        if (!process){
            return;
        }
        managedProcesses[@(pid)] = process;
        apply_configuration(process);
    });
}

void restore_all_managed_processes(void){
    initialize_process_manager();
    dispatch_async(processQueue, ^{
        [managedProcesses removeAllObjects];
        stop_immediate_timer_if_idle();
    });
}

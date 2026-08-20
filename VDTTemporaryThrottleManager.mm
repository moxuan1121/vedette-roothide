#import "VDTTemporaryThrottleManager.h"
#import "VDTExceptionBridge.h"
#import "VDTProcessManager.h"

#include <mach/mach_time.h>
#include <notify.h>
#include <sys/resource.h>

#define VDT_TEMP_SAMPLE_NSEC (1ull * NSEC_PER_SEC)
#define VDT_TEMP_RECOVERY_SAMPLES 3
#define VDT_TEMP_MAX_THROTTLE_NSEC (20ull * NSEC_PER_SEC)
#define VDT_TEMP_COOLDOWN_NSEC (5ull * NSEC_PER_SEC)

typedef NS_ENUM(NSUInteger, VDTTemporaryState) {
    VDTTemporaryStateMonitoring,
    VDTTemporaryStateThrottled,
    VDTTemporaryStateCooldown
};

@interface VDTTemporaryProcess : NSObject
@property(nonatomic) pid_t pid;
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic) VDTConfigType type;
@property(nonatomic, copy) NSString *path;
@property(nonatomic) uint64_t startTime;
@property(nonatomic) NSUInteger triggerCPU;
@property(nonatomic) NSUInteger interval;
@property(nonatomic) NSUInteger throttleLimit;
@property(nonatomic) NSUInteger recoveryCPU;
@property(nonatomic) VDTTemporaryState state;
@property(nonatomic) uint64_t throttledAt;
@property(nonatomic) uint64_t previousCPU;
@property(nonatomic) uint64_t previousSample;
@property(nonatomic) NSUInteger recoverySamples;
@property(nonatomic) int violationToken;
@property(nonatomic) int readyToken;
@property(nonatomic) BOOL bridgeReady;
@property(nonatomic) dispatch_source_t exitSource;
@end
@implementation VDTTemporaryProcess @end

static dispatch_queue_t temporaryQueue;
static NSMutableDictionary<NSNumber *, VDTTemporaryProcess *> *temporaryProcesses;
static dispatch_source_t sampleTimer;
static uint64_t maximumThrottleTicks;

static void initialize_temporary_manager(void){
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        temporaryQueue = dispatch_queue_create("com.udevs.vedette.temporary-throttle", DISPATCH_QUEUE_SERIAL);
        temporaryProcesses = [NSMutableDictionary dictionary];
        mach_timebase_info_data_t timebase = {};
        mach_timebase_info(&timebase);
        maximumThrottleTicks = (VDT_TEMP_MAX_THROTTLE_NSEC * timebase.denom) / timebase.numer;
    });
}

static BOOL read_identity(pid_t pid, NSString **pathOut, uint64_t *startOut, uint64_t *cpuOut){
    struct rusage_info_v2 usage = {};
    char pathBuffer[PROC_PIDPATHINFO_MAXSIZE] = {};
    if (pid <= 0 || proc_pid_rusage(pid, RUSAGE_INFO_V2, (rusage_info_t *)&usage) != 0 ||
        proc_pidpath(pid, pathBuffer, sizeof(pathBuffer)) <= 0){
        return NO;
    }
    if (pathOut) *pathOut = [NSString stringWithUTF8String:pathBuffer];
    if (startOut) *startOut = usage.ri_proc_start_abstime;
    if (cpuOut) *cpuOut = usage.ri_user_time + usage.ri_system_time;
    return YES;
}

static BOOL identity_matches(VDTTemporaryProcess *process, uint64_t *cpuOut){
    NSString *path = nil;
    uint64_t start = 0;
    if (!read_identity(process.pid, &path, &start, cpuOut)) return NO;
    return start == process.startTime && [path isEqualToString:process.path];
}

static NSString *violation_name(pid_t pid){
    return [NSString stringWithFormat:@"com.udevs.vedette.temp.violation.%d", pid];
}

static NSString *ready_name(pid_t pid){
    return [NSString stringWithFormat:@"com.udevs.vedette.temp.ready.%d", pid];
}

static NSUInteger throttled_process_count(void){
    NSUInteger count = 0;
    for (VDTTemporaryProcess *process in temporaryProcesses.allValues){
        if (process.state == VDTTemporaryStateThrottled) count++;
    }
    return count;
}

static void stop_timer_if_idle(void){
    if (sampleTimer && throttled_process_count() == 0){
        dispatch_source_cancel(sampleTimer);
        sampleTimer = nil;
    }
}

static void remove_process(VDTTemporaryProcess *process, BOOL restoreLimits){
    if (!process) return;
    BOOL validIdentity = identity_matches(process, NULL);
    if (validIdentity){
        if (restoreLimits && process.state == VDTTemporaryStateThrottled){
            proc_clear_cpulimits(process.pid);
        }
        proc_disable_cpumon(process.pid);
        VDTRequestTemporaryMonitorBridge(process.pid, NO);
    }
    if (process.violationToken > 0) notify_cancel(process.violationToken);
    if (process.readyToken > 0) notify_cancel(process.readyToken);
    if (process.exitSource) dispatch_source_cancel(process.exitSource);
    [temporaryProcesses removeObjectForKey:@(process.pid)];
    stop_timer_if_idle();
}

static void arm_monitor(VDTTemporaryProcess *process){
    if (!identity_matches(process, NULL)){
        remove_process(process, NO);
        return;
    }
    proc_disable_cpumon(process.pid);
    if (proc_set_cpumon_params(process.pid, (int)process.triggerCPU, (int)process.interval) == 0){
        if (proc_resume_cpumon(process.pid) == 0){
            process.state = VDTTemporaryStateMonitoring;
        }else{
            proc_disable_cpumon(process.pid);
            remove_process(process, NO);
        }
    }else{
        remove_process(process, NO);
    }
}

static void finish_throttle(VDTTemporaryProcess *process){
    if (!identity_matches(process, NULL)){
        remove_process(process, NO);
        return;
    }
    proc_clear_cpulimits(process.pid);
    process.state = VDTTemporaryStateCooldown;
    process.recoverySamples = 0;
    stop_timer_if_idle();
    pid_t pid = process.pid;
    uint64_t startTime = process.startTime;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, VDT_TEMP_COOLDOWN_NSEC), temporaryQueue, ^{
        VDTTemporaryProcess *current = temporaryProcesses[@(pid)];
        if (!current || current.startTime != startTime || current.state != VDTTemporaryStateCooldown){
            return;
        }
        arm_monitor(current);
    });
}

static void sample_throttled_processes(void){
    uint64_t now = mach_absolute_time();
    for (VDTTemporaryProcess *process in temporaryProcesses.allValues.copy){
        if (process.state != VDTTemporaryStateThrottled) continue;
        uint64_t cpu = 0;
        if (!identity_matches(process, &cpu)){
            remove_process(process, NO);
            continue;
        }
        uint64_t elapsedCPU = cpu >= process.previousCPU ? cpu - process.previousCPU : 0;
        uint64_t elapsedTime = now - process.previousSample;
        process.previousCPU = cpu;
        process.previousSample = now;
        double percentage = elapsedTime ? ((double)elapsedCPU * 100.0) / (double)elapsedTime : 0;
        process.recoverySamples = percentage < process.recoveryCPU ? process.recoverySamples + 1 : 0;
        if (process.recoverySamples >= VDT_TEMP_RECOVERY_SAMPLES ||
            now - process.throttledAt >= maximumThrottleTicks){
            finish_throttle(process);
        }
    }
}

static void ensure_sample_timer(void){
    if (sampleTimer || throttled_process_count() == 0) return;
    sampleTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, temporaryQueue);
    dispatch_source_set_timer(sampleTimer, dispatch_time(DISPATCH_TIME_NOW, VDT_TEMP_SAMPLE_NSEC),
        VDT_TEMP_SAMPLE_NSEC, 100ull * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(sampleTimer, ^{ sample_throttled_processes(); });
    dispatch_resume(sampleTimer);
}

static void handle_violation(pid_t pid){
    dispatch_sync(temporaryQueue, ^{
        VDTTemporaryProcess *process = temporaryProcesses[@(pid)];
        if (!process || process.state != VDTTemporaryStateMonitoring || !identity_matches(process, NULL)){
            if (process) remove_process(process, NO);
            return;
        }
        proc_disable_cpumon(pid);
        if (proc_setcpu_percentage(pid, PROC_SETCPU_ACTION_THROTTLE, (int)process.throttleLimit) != 0){
            arm_monitor(process);
            return;
        }
        uint64_t cpu = 0;
        if (!identity_matches(process, &cpu)){
            remove_process(process, NO);
            return;
        }
        process.state = VDTTemporaryStateThrottled;
        process.throttledAt = mach_absolute_time();
        process.previousSample = process.throttledAt;
        process.previousCPU = cpu;
        process.recoverySamples = 0;
        ensure_sample_timer();
    });
}

void VDTConfigureTemporaryThrottle(pid_t pid, NSString *identifier, VDTConfigType type,
    NSUInteger triggerCPU, NSUInteger interval, NSUInteger throttleLimit, NSUInteger recoveryCPU){
    initialize_temporary_manager();
    dispatch_async(temporaryQueue, ^{
        NSString *path = nil;
        uint64_t start = 0;
        if (!read_identity(pid, &path, &start, NULL)) return;
        VDTTemporaryProcess *old = temporaryProcesses[@(pid)];
        if (old && old.startTime != start) remove_process(old, NO);
        VDTTemporaryProcess *process = temporaryProcesses[@(pid)];
        if (!process){
            process = [VDTTemporaryProcess new];
            process.pid = pid;
            process.path = path;
            process.startTime = start;
            process.identifier = identifier;
            process.type = type;
            int violationToken = 0;
            notify_register_dispatch(violation_name(pid).UTF8String, &violationToken,
                dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(__unused int token) {
                    handle_violation(pid);
                });
            process.violationToken = violationToken;
            int readyToken = 0;
            notify_register_dispatch(ready_name(pid).UTF8String, &readyToken,
                dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(__unused int token) {
                    dispatch_async(temporaryQueue, ^{
                        VDTTemporaryProcess *current = temporaryProcesses[@(pid)];
                        if (!current || !identity_matches(current, NULL)) return;
                        current.bridgeReady = YES;
                        if (current.state == VDTTemporaryStateMonitoring) arm_monitor(current);
                    });
                });
            process.readyToken = readyToken;
            process.exitSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)pid,
                DISPATCH_PROC_EXIT, temporaryQueue);
            dispatch_source_set_event_handler(process.exitSource, ^{
                VDTTemporaryProcess *current = temporaryProcesses[@(pid)];
                if (current) remove_process(current, NO);
            });
            dispatch_resume(process.exitSource);
            temporaryProcesses[@(pid)] = process;
            // Remove a possible task-wide limit left by the original
            // permanent Throttle mode before arming the non-fatal monitor.
            proc_clear_cpulimits(pid);
            VDTRequestTemporaryMonitorBridge(pid, YES);
        }
        process.triggerCPU = MAX(1, MIN(100, triggerCPU));
        process.interval = MAX(1, interval);
        process.throttleLimit = MAX(1, MIN(99, throttleLimit));
        process.recoveryCPU = MIN(100, recoveryCPU);
        if (process.state == VDTTemporaryStateMonitoring && process.bridgeReady) arm_monitor(process);
        else if (process.state == VDTTemporaryStateThrottled){
            proc_setcpu_percentage(pid, PROC_SETCPU_ACTION_THROTTLE, (int)process.throttleLimit);
        }
    });
}

void VDTSynchronizeTemporaryThrottlePIDs(NSSet<NSNumber *> *activePIDs){
    initialize_temporary_manager();
    dispatch_sync(temporaryQueue, ^{
        for (NSNumber *pidKey in temporaryProcesses.allKeys.copy){
            if (![activePIDs containsObject:pidKey]) remove_process(temporaryProcesses[pidKey], YES);
        }
    });
}

void VDTRemoveTemporaryThrottlePID(pid_t pid){
    initialize_temporary_manager();
    dispatch_async(temporaryQueue, ^{
        remove_process(temporaryProcesses[@(pid)], YES);
    });
}

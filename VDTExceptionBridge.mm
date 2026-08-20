#import "VDTExceptionBridge.h"
#import "Common.h"

#include <mach/mach.h>
#include <notify.h>

// The MIG mach_exc header is not shipped by every patched iOS SDK, while
// libsystem_kernel still exports the generated server demultiplexer.
extern "C" boolean_t mach_exc_server(mach_msg_header_t *request, mach_msg_header_t *reply);

// exc_resource.h is private and is absent from some patched Theos SDKs.
// These values are stable XNU ABI fields encoded in EXC_RESOURCE code[0].
#define VDT_EXC_RESOURCE_TYPE(code) (((uint64_t)(code) >> 61) & 0x7ULL)
#define VDT_EXC_RESOURCE_FLAVOR(code) (((uint64_t)(code) >> 58) & 0x7ULL)
#define VDT_RESOURCE_TYPE_CPU 1
#define VDT_FLAVOR_CPU_MONITOR 1

static mach_port_t bridgePort = MACH_PORT_NULL;
static exception_mask_t savedMasks[EXC_TYPES_COUNT];
static mach_port_t savedPorts[EXC_TYPES_COUNT];
static exception_behavior_t savedBehaviors[EXC_TYPES_COUNT];
static thread_state_flavor_t savedFlavors[EXC_TYPES_COUNT];
static mach_msg_type_number_t savedCount = 0;
static BOOL bridgeInstalled = NO;

static NSString *bridge_notification(NSString *action, pid_t pid){
    return [NSString stringWithFormat:@"com.udevs.vedette.temp.%@.%d", action, pid];
}

static void restore_exception_bridge(void){
    if (!bridgeInstalled && savedCount == 0 && !MACH_PORT_VALID(bridgePort)){
        return;
    }
    task_set_exception_ports(mach_task_self(), EXC_MASK_RESOURCE, MACH_PORT_NULL,
        EXCEPTION_DEFAULT, THREAD_STATE_NONE);
    for (mach_msg_type_number_t idx = 0; idx < savedCount; idx++){
        task_set_exception_ports(
            mach_task_self(), savedMasks[idx] & EXC_MASK_RESOURCE, savedPorts[idx],
            savedBehaviors[idx], savedFlavors[idx]
        );
        if (MACH_PORT_VALID(savedPorts[idx])){
            mach_port_deallocate(mach_task_self(), savedPorts[idx]);
        }
    }
    savedCount = 0;
    bridgeInstalled = NO;
    if (MACH_PORT_VALID(bridgePort)){
        mach_port_destroy(mach_task_self(), bridgePort);
        bridgePort = MACH_PORT_NULL;
    }
}

static void install_exception_bridge(void){
    if (bridgeInstalled){
        notify_post(bridge_notification(@"ready", getpid()).UTF8String);
        return;
    }

    savedCount = EXC_TYPES_COUNT;
    kern_return_t kr = task_get_exception_ports(
        mach_task_self(), EXC_MASK_RESOURCE, savedMasks, &savedCount,
        savedPorts, savedBehaviors, savedFlavors
    );
    if (kr != KERN_SUCCESS){
        savedCount = 0;
        return;
    }
    kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &bridgePort);
    if (kr != KERN_SUCCESS){
        restore_exception_bridge();
        return;
    }
    kr = mach_port_insert_right(mach_task_self(), bridgePort, bridgePort, MACH_MSG_TYPE_MAKE_SEND);
    if (kr != KERN_SUCCESS){
        restore_exception_bridge();
        return;
    }
    kr = task_set_exception_ports(
        mach_task_self(), EXC_MASK_RESOURCE, bridgePort,
        EXCEPTION_DEFAULT | MACH_EXCEPTION_CODES, THREAD_STATE_NONE
    );
    if (kr != KERN_SUCCESS){
        restore_exception_bridge();
        return;
    }

    bridgeInstalled = YES;
    notify_post(bridge_notification(@"ready", getpid()).UTF8String);
    mach_port_t serverPort = bridgePort;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        mach_msg_server(mach_exc_server, 4096, serverPort, MACH_MSG_OPTION_NONE);
    });
}

void VDTPrepareTemporaryMonitorBridge(void){
    pid_t pid = getpid();
    NSString *enableName = bridge_notification(@"enable", pid);
    NSString *disableName = bridge_notification(@"disable", pid);
    int enableToken = 0;
    int disableToken = 0;
    notify_register_dispatch(enableName.UTF8String, &enableToken,
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(__unused int token) {
            install_exception_bridge();
        });
    notify_register_dispatch(disableName.UTF8String, &disableToken,
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(__unused int token) {
            restore_exception_bridge();
        });
}

void VDTRequestTemporaryMonitorBridge(pid_t pid, BOOL enabled){
    NSString *name = bridge_notification(enabled ? @"enable" : @"disable", pid);
    notify_post(name.UTF8String);
}

kern_return_t catch_mach_exception_raise(
    __unused mach_port_t exceptionPort,
    mach_port_t thread,
    mach_port_t task,
    exception_type_t exception,
    mach_exception_data_t code,
    mach_msg_type_number_t codeCount
){
    BOOL isCPUMonitor = exception == EXC_RESOURCE && codeCount >= 1 &&
        VDT_EXC_RESOURCE_TYPE(code[0]) == VDT_RESOURCE_TYPE_CPU &&
        VDT_EXC_RESOURCE_FLAVOR(code[0]) == VDT_FLAVOR_CPU_MONITOR;
    if (MACH_PORT_VALID(thread)) mach_port_deallocate(mach_task_self(), thread);
    if (MACH_PORT_VALID(task)) mach_port_deallocate(mach_task_self(), task);
    if (!isCPUMonitor){
        return KERN_FAILURE;
    }
    NSString *name = bridge_notification(@"violation", getpid());
    notify_post(name.UTF8String);
    return KERN_SUCCESS;
}

kern_return_t catch_mach_exception_raise_state(
    __unused mach_port_t exceptionPort, __unused exception_type_t exception,
    __unused const mach_exception_data_t code, __unused mach_msg_type_number_t codeCount,
    __unused int *flavor, __unused const thread_state_t oldState,
    __unused mach_msg_type_number_t oldStateCount, __unused thread_state_t newState,
    __unused mach_msg_type_number_t *newStateCount
){
    return KERN_FAILURE;
}

kern_return_t catch_mach_exception_raise_state_identity(
    __unused mach_port_t exceptionPort, mach_port_t thread, mach_port_t task,
    __unused exception_type_t exception, __unused mach_exception_data_t code,
    __unused mach_msg_type_number_t codeCount, __unused int *flavor,
    __unused thread_state_t oldState, __unused mach_msg_type_number_t oldStateCount,
    __unused thread_state_t newState, __unused mach_msg_type_number_t *newStateCount
){
    if (MACH_PORT_VALID(thread)) mach_port_deallocate(mach_task_self(), thread);
    if (MACH_PORT_VALID(task)) mach_port_deallocate(mach_task_self(), task);
    return KERN_FAILURE;
}

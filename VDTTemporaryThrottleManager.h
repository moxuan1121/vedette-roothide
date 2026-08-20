#import "VDTShared.h"

#ifdef __cplusplus
extern "C" {
#endif

void VDTConfigureTemporaryThrottle(
    pid_t pid, NSString *identifier, VDTConfigType type,
    NSUInteger triggerCPU, NSUInteger interval,
    NSUInteger throttleLimit, NSUInteger recoveryCPU
);
void VDTSynchronizeTemporaryThrottlePIDs(NSSet<NSNumber *> *activePIDs);
void VDTRemoveTemporaryThrottlePID(pid_t pid);

#ifdef __cplusplus
}
#endif

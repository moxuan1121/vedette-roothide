#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

void VDTPrepareTemporaryMonitorBridge(void);
void VDTRequestTemporaryMonitorBridge(pid_t pid, BOOL enabled);

#ifdef __cplusplus
}
#endif

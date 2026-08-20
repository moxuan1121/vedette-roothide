//  Copyright (c) 2021 udevs
//
//  This file is subject to the terms and conditions defined in
//  file 'LICENSE', which is part of this source code package.

#import "Common.h"

#include <libproc.h>
#include <libproc_internal.h>

extern NSDictionary *prefs;

#ifdef __cplusplus
extern "C" {
#endif

void monitor_pids(NSArray <NSNumber *> *pids, NSArray <NSNumber *> *percentages, NSArray <NSNumber *> *intervals);
void throttle_pids(NSArray <NSNumber *> *pids, NSArray <NSNumber *> *percentages);
void update_process_preferences(NSDictionary *newPrefs);
void received_new_proc(pid_t pid);
void restore_all_managed_processes(void);

#ifdef __cplusplus
}
#endif


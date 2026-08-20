//  Copyright (c) 2021 udevs
//
//  This file is subject to the terms and conditions defined in
//  file 'LICENSE', which is part of this source code package.

#import "Common.h"

#include <stdint.h>
#include <sys/resource.h>
#include <sys/types.h>

#ifndef PROC_PIDPATHINFO_MAXSIZE
#define PROC_PIDPATHINFO_MAXSIZE 4096
#endif

extern NSDictionary *prefs;

#ifdef __cplusplus
extern "C" {
#endif

// Recent public iOS SDKs omit libproc headers even though these libSystem
// entry points remain present on iOS 15. Keep only the declarations Vedette
// actually uses instead of vendoring the large private headers.
int proc_name(int pid, void *buffer, uint32_t buffersize);
int proc_pidpath(int pid, void *buffer, uint32_t buffersize);
int proc_pid_rusage(int pid, int flavor, rusage_info_t *buffer);
void update_process_preferences(NSDictionary *newPrefs);
void received_new_proc(pid_t pid);
void restore_all_managed_processes(void);

#ifdef __cplusplus
}
#endif


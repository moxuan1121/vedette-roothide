#ifndef LIBPROC_LIBPROC_H
#define LIBPROC_LIBPROC_H

#include <sys/cdefs.h>
#include <stdint.h>
#include <sys/types.h>
#include <sys/resource.h>

#define PROC_PIDPATHINFO_MAXSIZE 4096

__BEGIN_DECLS
int proc_pidpath(int pid, void *buffer, uint32_t buffersize);
int proc_pid_rusage(int pid, int flavor, rusage_info_t *buffer);
__END_DECLS

#endif

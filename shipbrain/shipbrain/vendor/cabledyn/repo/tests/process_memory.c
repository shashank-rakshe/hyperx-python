/* File: tests/process_memory.c
 * SPDX-License-Identifier: Apache-2.0
 * Process memory counter for the memory-growth gates (C and Fortran callers).
 * Returns the Windows private commit or the Linux resident set in MiB, or a
 * negative value where the platform exposes no counter.
 */
#include <stdio.h>
#include <string.h>

#if defined(_WIN32)
#include <windows.h>
#include <psapi.h>
#elif defined(__linux__)
#include <unistd.h>
#endif

double cd_test_process_memory_mib(void)
{
#if defined(_WIN32)
    PROCESS_MEMORY_COUNTERS_EX pmc;
    memset(&pmc, 0, sizeof pmc);
    if (!GetProcessMemoryInfo(GetCurrentProcess(), (PROCESS_MEMORY_COUNTERS *)&pmc, sizeof pmc)) return -1.0;
    return (double)pmc.PrivateUsage / 1048576.0;
#elif defined(__linux__)
    long pages_total = 0, pages_resident = 0;
    long page_size = sysconf(_SC_PAGESIZE);
    FILE *statm = fopen("/proc/self/statm", "r");
    int n_read;
    if (statm == NULL || page_size <= 0) {
        if (statm != NULL) fclose(statm);
        return -1.0;
    }
    n_read = fscanf(statm, "%ld %ld", &pages_total, &pages_resident);
    fclose(statm);
    if (n_read != 2) return -1.0;
    return (double)pages_resident * (double)page_size / 1048576.0;
#else
    return -1.0;
#endif
}

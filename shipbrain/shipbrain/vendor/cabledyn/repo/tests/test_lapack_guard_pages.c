/* File: tests/test_lapack_guard_pages.c
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
 *
 * The modal eigensolves (DSYGV, the dense reference; DSBGVX, the band reduction; DPBTRF and
 * DPBTRS, the banded Cholesky factor and solves of the shift-invert Lanczos stage; DSYEV, its
 * projected eigenproblem) called through CableDyn's LAPACK layer -- in Windows GNU builds the
 * run-time forwarders to openblas.dll -- with every argument array placed against a no-access
 * page, at its end and, in a second pass, at its start. Any read or write outside the arrays
 * the modal code passes faults at once and names the call. Sizes cover the test_modal cases and
 * more (n <= 96, half band widths 0..11), with the argument sizes CableDyn_Modal uses (WORK 7n
 * and IWORK 5n for DSBGVX, two right-hand sides for DPBTRS, the queried LWORK for DSYGV and
 * DSYEV). CTest runs it with OPENBLAS_CORETYPE=Haswell, the kernel selected on the hosts where
 * test_modal was seen to fault.
 */
#if !defined(_WIN32)
#define _DEFAULT_SOURCE
#define _DARWIN_C_SOURCE
#endif
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void dsygv_(const int *itype, const char *jobz, const char *uplo, const int *n, double *a, const int *lda,
            double *b, const int *ldb, double *w, double *work, const int *lwork, int *info, size_t jobz_len,
            size_t uplo_len);
void dsbgvx_(const char *jobz, const char *range, const char *uplo, const int *n, const int *ka, const int *kb,
             double *ab, const int *ldab, double *bb, const int *ldbb, double *q, const int *ldq, const double *vl,
             const double *vu, const int *il, const int *iu, const double *abstol, int *m, double *w, double *z,
             const int *ldz, double *work, int *iwork, int *ifail, int *info, size_t jobz_len, size_t range_len,
             size_t uplo_len);
void dsyev_(const char *jobz, const char *uplo, const int *n, double *a, const int *lda, double *w, double *work,
            const int *lwork, int *info, size_t jobz_len, size_t uplo_len);
void dpbtrf_(const char *uplo, const int *n, const int *kd, double *ab, const int *ldab, int *info, size_t uplo_len);
void dpbtrs_(const char *uplo, const int *n, const int *kd, const int *nrhs, const double *ab, const int *ldab,
             double *b, const int *ldb, int *info, size_t uplo_len);

static char where[96] = "start";

#if defined(_WIN32)
#include <windows.h>

static LONG WINAPI on_fault(EXCEPTION_POINTERS *ep)
{
    if (ep->ExceptionRecord->ExceptionCode == EXCEPTION_ACCESS_VIOLATION) {
        fprintf(stderr, "FAIL: an access outside the arrays during %s\n", where);
        fflush(stderr);
        ExitProcess(3);
    }
    return EXCEPTION_CONTINUE_SEARCH;
}

static void install_fault_report(void)
{
    AddVectoredExceptionHandler(1, on_fault);
}

static size_t page_size(void)
{
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    return si.dwPageSize;
}

static char *reserve(size_t bytes)
{
    return (char *)VirtualAlloc(NULL, bytes, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
}

static void no_access(char *at, size_t bytes)
{
    DWORD old;
    VirtualProtect(at, bytes, PAGE_NOACCESS, &old);
}
#else
#include <signal.h>
#include <sys/mman.h>
#include <unistd.h>

static void on_fault(int sig)
{
    static const char head[] = "FAIL: an access outside the arrays during ";
    ssize_t ignored = write(STDERR_FILENO, head, sizeof head - 1);
    ignored = write(STDERR_FILENO, where, strlen(where));
    ignored = write(STDERR_FILENO, "\n", 1);
    (void)ignored;
    (void)sig;
    _exit(3);
}

static void install_fault_report(void)
{
    signal(SIGSEGV, on_fault);
    signal(SIGBUS, on_fault);
}

static size_t page_size(void)
{
    return (size_t)sysconf(_SC_PAGESIZE);
}

static char *reserve(size_t bytes)
{
    void *p = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    return p == MAP_FAILED ? NULL : (char *)p;
}

static void no_access(char *at, size_t bytes)
{
    mprotect(at, bytes, PROT_NONE);
}
#endif

/* `bytes` usable bytes between two no-access pages: flush against the page after them
 * (front = 0) or the page before them (front = 1). Never freed: a few MB for the run. */
static void *guarded(size_t bytes, int front)
{
    size_t page = page_size();
    size_t span = (bytes + page - 1) / page * page;
    char *base = reserve(span + 2 * page);
    if (base == NULL) {
        fprintf(stderr, "FAIL: cannot reserve guarded memory\n");
        exit(2);
    }
    no_access(base, page);
    no_access(base + page + span, page);
    return front ? (void *)(base + page) : (void *)(base + page + span - bytes);
}

static double next_random(unsigned *state)
{
    *state = *state * 1664525u + 1013904223u;
    return (double)(*state >> 8) / 16777216.0;
}

int main(void)
{
    unsigned state = 2026u;
    int front, n, failures = 0;
    install_fault_report();
    for (front = 0; front <= 1; ++front) {
        for (n = 1; n <= 96; ++n) {
            int i, j, info = 0, itype = 1, lwork = -1, kd;
            double query = 0.0;
            double *a = guarded(sizeof(double) * (size_t)n * (size_t)n, front);
            double *b = guarded(sizeof(double) * (size_t)n * (size_t)n, front);
            double *w = guarded(sizeof(double) * (size_t)n, front);
            double *work;
            for (j = 0; j < n; ++j) {
                for (i = 0; i <= j; ++i) {
                    double v = next_random(&state) - 0.5;
                    a[i + j * n] = a[j + i * n] = v + (i == j ? 2.0 * n : 0.0);
                    b[i + j * n] = b[j + i * n] = i == j ? 1.0 + next_random(&state) : 0.01 * v;
                }
            }
            snprintf(where, sizeof where, "DSYGV workspace query, n = %d", n);
            dsygv_(&itype, "V", "U", &n, a, &n, b, &n, w, &query, &lwork, &info, 1, 1);
            lwork = (int)query;
            if (lwork < 3 * n) {
                lwork = 3 * n;
            }
            work = guarded(sizeof(double) * (size_t)lwork, front);
            snprintf(where, sizeof where, "DSYGV, n = %d, %s guard", n, front ? "front" : "end");
            dsygv_(&itype, "V", "U", &n, a, &n, b, &n, w, work, &lwork, &info, 1, 1);
            if (info != 0) {
                fprintf(stderr, "FAIL: DSYGV n = %d returned INFO = %d\n", n, info);
                ++failures;
            }
            for (j = 0; j < n; ++j) {
                for (i = 0; i <= j; ++i) {
                    a[i + j * n] = a[j + i * n] = next_random(&state) - 0.5;
                }
            }
            lwork = -1;
            snprintf(where, sizeof where, "DSYEV workspace query, n = %d", n);
            dsyev_("V", "U", &n, a, &n, w, &query, &lwork, &info, 1, 1);
            lwork = (int)query;
            if (lwork < 3 * n) {
                lwork = 3 * n;
            }
            work = guarded(sizeof(double) * (size_t)lwork, front);
            snprintf(where, sizeof where, "DSYEV, n = %d, %s guard", n, front ? "front" : "end");
            dsyev_("V", "U", &n, a, &n, w, work, &lwork, &info, 1, 1);
            if (info != 0) {
                fprintf(stderr, "FAIL: DSYEV n = %d returned INFO = %d\n", n, info);
                ++failures;
            }
            for (kd = 0; kd <= 11 && kd < n; ++kd) {
                int ld = kd + 1, il = 1, iu = n < 6 ? n : 6, m = 0, one = 1;
                double vl = 0.0, vu = 0.0, tol = 4.4501477170144028e-308, q = 0.0, z = 0.0;
                double *ab = guarded(sizeof(double) * (size_t)ld * (size_t)n, front);
                double *bb = guarded(sizeof(double) * (size_t)ld * (size_t)n, front);
                double *ww = guarded(sizeof(double) * (size_t)n, front);
                double *bwork = guarded(sizeof(double) * 7 * (size_t)n, front);
                int *iwork = guarded(sizeof(int) * 5 * (size_t)n, front);
                int *ifail = guarded(sizeof(int) * (size_t)n, front);
                for (j = 0; j < n; ++j) {
                    for (i = j - kd > 0 ? j - kd : 0; i <= j; ++i) {
                        ab[(kd + i - j) + j * ld] = i == j ? 2.0 * n : next_random(&state) - 0.5;
                        bb[(kd + i - j) + j * ld] = i == j ? 1.0 + next_random(&state) : 0.0;
                    }
                }
                snprintf(where, sizeof where, "DSBGVX, n = %d, kd = %d, %s guard", n, kd,
                         front ? "front" : "end");
                dsbgvx_("N", "I", "U", &n, &kd, &kd, ab, &ld, bb, &ld, &q, &one, &vl, &vu, &il, &iu, &tol, &m,
                        ww, &z, &one, bwork, iwork, ifail, &info, 1, 1, 1);
                if (info != 0 || m != iu) {
                    fprintf(stderr, "FAIL: DSBGVX n = %d kd = %d returned INFO = %d, M = %d\n", n, kd, info, m);
                    ++failures;
                }
                {
                    int two = 2;
                    double *fk = guarded(sizeof(double) * (size_t)ld * (size_t)n, front);
                    double *rhs = guarded(sizeof(double) * 2 * (size_t)n, front);
                    for (j = 0; j < n; ++j) {
                        for (i = j - kd > 0 ? j - kd : 0; i <= j; ++i) {
                            fk[(kd + i - j) + j * ld] = i == j ? 2.0 * n + kd : next_random(&state) - 0.5;
                        }
                        rhs[j] = next_random(&state);
                        rhs[j + n] = next_random(&state);
                    }
                    snprintf(where, sizeof where, "DPBTRF, n = %d, kd = %d, %s guard", n, kd,
                             front ? "front" : "end");
                    dpbtrf_("U", &n, &kd, fk, &ld, &info, 1);
                    if (info != 0) {
                        fprintf(stderr, "FAIL: DPBTRF n = %d kd = %d returned INFO = %d\n", n, kd, info);
                        ++failures;
                        continue;
                    }
                    snprintf(where, sizeof where, "DPBTRS, n = %d, kd = %d, %s guard", n, kd,
                             front ? "front" : "end");
                    dpbtrs_("U", &n, &kd, &two, fk, &ld, rhs, &n, &info, 1);
                    if (info != 0) {
                        fprintf(stderr, "FAIL: DPBTRS n = %d kd = %d returned INFO = %d\n", n, kd, info);
                        ++failures;
                    }
                }
            }
        }
    }
    if (failures != 0) {
        return 1;
    }
    printf("PASS: DSYGV, DSYEV, DSBGVX, DPBTRF and DPBTRS stay inside the arrays the modal code passes "
           "(n <= 96)\n");
    return 0;
}

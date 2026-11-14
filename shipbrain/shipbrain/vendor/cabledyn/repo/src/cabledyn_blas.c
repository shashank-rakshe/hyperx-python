/* File: src/cabledyn_blas.c
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
 *
 * BLAS thread-count policy and, on Windows GNU builds, run-time loading of OpenBLAS.
 *
 * Every linear system CableDyn solves is a small banded one, so a threaded BLAS
 * gains nothing and costs memory. A threaded OpenBLAS starts one worker per logical
 * CPU while its DLL loads, and on Windows each worker commits a work buffer of about
 * 128 MB at once: loading openblas.dll on a 32-CPU machine commits about 4 GB. The
 * pool is sized from OPENBLAS_NUM_THREADS during that load and cannot be shrunk
 * afterwards (openblas_set_num_threads only changes how many workers a call uses).
 * Windows also maps delay-load imports in the background shortly after a process
 * starts, so a delay-load import library does not postpone the load either.
 *
 * With CABLEDYN_BLAS_RUNTIME_LOAD (Windows GNU builds that stage openblas.dll, set by
 * CMakeLists.txt) this file therefore defines the nine LAPACK entry points CableDyn
 * calls (dgbsv, dgbsvx, dgbtrf, dgbtrs, dpbtrf, dpbtrs, dsbgvx, dsyev, dsygv). Nothing imports
 * openblas.dll; the first call loads the openblas.dll that sits next to the CableDyn module, with
 * OPENBLAS_NUM_THREADS set to the policy value for the duration of the load (only
 * when the user has not set that variable), and forwards to it. This covers the
 * shared C-ABI library and every executable linking cabledyn_core, including the
 * standalone driver. Model initialisation (the C API Init calls, the driver, the
 * OpenFAST aggregate) triggers the load through cabledyn_blas_runtime_status, so a
 * missing BLAS runtime fails there with a message naming the library, the locations
 * tried and the load error, instead of at the first solve. A LAPACK routine that the
 * Fortran sources call but this file does not define is imported from openblas.dll
 * at load time instead, with a pool sized from OMP_NUM_THREADS or the CPU count; the
 * blas_runtime_imports test fails when any CableDyn binary imports openblas.dll.
 *
 * Without CABLEDYN_BLAS_RUNTIME_LOAD, CableDyn_Create calls openblas_set_num_threads
 * when CMake found it in the linked back end (CABLEDYN_HAVE_OPENBLAS_SET_NUM_THREADS);
 * elsewhere (reference LAPACK/BLAS, including the IFX-built reference LAPACK of the
 * static release) the policy is a no-op.
 *
 * The environment variable CABLEDYN_BLAS_THREADS selects the policy:
 *   unset or empty      one BLAS thread (the default);
 *   a positive integer  that many BLAS threads;
 *   0 or "default"      leave OpenBLAS untouched (it then follows
 *                       OPENBLAS_NUM_THREADS, or OMP_NUM_THREADS, or the CPU count).
 */
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#include <windows.h>
#else
#include <pthread.h>
#endif

/* Applies the policy once per process (thread-safe, idempotent); returns 0 on
 * success and 1 when the run-time loaded OpenBLAS could not be loaded. */
int cabledyn_blas_threads_once(void);
/* Applies the policy if needed; returns the BLAS thread count it set, or 0 when
 * it left the BLAS library untouched (no OpenBLAS, or the opt-out was given). */
int cabledyn_blas_threads_applied(void);
/* Applies the policy once and reports whether the LAPACK runtime is usable: returns 0
 * when it is, 1 when the run-time load failed, in which case msg (msg_len bytes,
 * always null-terminated) receives "<requester>: <reason>", the reason naming the
 * library, each location tried and the Windows load error. Called at model
 * initialisation (CD_Blas_Runtime_Check in CableDyn_Linalg) so the failure is
 * reported there, not as a solver failure. */
int cabledyn_blas_runtime_status(const char *requester, char *msg, int msg_len);

/* INFO returned by every forwarded LAPACK routine when the run-time loaded OpenBLAS
 * is unavailable; CD_BLAS_UNAVAILABLE_INFO in CableDyn_Linalg. LAPACK itself returns
 * INFO in -(number of arguments)..n, so this value cannot be mistaken for its own. */
#define CABLEDYN_BLAS_UNAVAILABLE_INFO (-1000)

static int cabledyn_blas_threads_set = 0;
static int cabledyn_blas_load_failed = 0;

/* Parse CABLEDYN_BLAS_THREADS: returns the requested thread count, or 0 to opt out. */
static int cabledyn_blas_threads_requested(void)
{
    const char *text = getenv("CABLEDYN_BLAS_THREADS");
    char *end = NULL;
    long value;

    if (text == NULL || text[0] == '\0') {
        return 1;
    }
    if (strcmp(text, "default") == 0) {
        return 0;
    }
    value = strtol(text, &end, 10);
    if (end == text || *end != '\0' || value < 0 || value > 4096) {
        /* Malformed values keep the safe default rather than a large thread team. */
        return 1;
    }
    return (int)value;
}

#if defined(_WIN32) && defined(CABLEDYN_BLAS_RUNTIME_LOAD)

typedef void(__cdecl *cabledyn_set_threads_fn)(int);
typedef void(__cdecl *cabledyn_dgbsv_fn)(const int *, const int *, const int *, const int *, double *,
                                         const int *, int *, double *, const int *, int *);
typedef void(__cdecl *cabledyn_dgbtrf_fn)(const int *, const int *, const int *, const int *, double *,
                                          const int *, int *, int *);
typedef void(__cdecl *cabledyn_dgbtrs_fn)(const char *, const int *, const int *, const int *, const int *,
                                          const double *, const int *, const int *, double *, const int *,
                                          int *, size_t);
typedef void(__cdecl *cabledyn_dgbsvx_fn)(const char *, const char *, const int *, const int *, const int *,
                                          const int *, double *, const int *, double *, const int *, int *,
                                          char *, double *, double *, double *, const int *, double *,
                                          const int *, double *, double *, double *, double *, int *, int *,
                                          size_t, size_t, size_t);
typedef void(__cdecl *cabledyn_dpbtrf_fn)(const char *, const int *, const int *, double *, const int *, int *,
                                          size_t);
typedef void(__cdecl *cabledyn_dpbtrs_fn)(const char *, const int *, const int *, const int *, const double *,
                                          const int *, double *, const int *, int *, size_t);
typedef void(__cdecl *cabledyn_dsyev_fn)(const char *, const char *, const int *, double *, const int *,
                                         double *, double *, const int *, int *, size_t, size_t);
typedef void(__cdecl *cabledyn_dsbgvx_fn)(const char *, const char *, const char *, const int *, const int *,
                                          const int *, double *, const int *, double *, const int *, double *,
                                          const int *, const double *, const double *, const int *, const int *,
                                          const double *, int *, double *, double *, const int *, double *, int *,
                                          int *, int *, size_t, size_t, size_t);
typedef void(__cdecl *cabledyn_dsygv_fn)(const int *, const char *, const char *, const int *, double *,
                                         const int *, double *, const int *, double *, double *, const int *,
                                         int *, size_t, size_t);

static cabledyn_dgbsv_fn cabledyn_real_dgbsv = NULL;
static cabledyn_dgbtrf_fn cabledyn_real_dgbtrf = NULL;
static cabledyn_dgbtrs_fn cabledyn_real_dgbtrs = NULL;
static cabledyn_dgbsvx_fn cabledyn_real_dgbsvx = NULL;
static cabledyn_dpbtrf_fn cabledyn_real_dpbtrf = NULL;
static cabledyn_dpbtrs_fn cabledyn_real_dpbtrs = NULL;
static cabledyn_dsyev_fn cabledyn_real_dsyev = NULL;
static cabledyn_dsbgvx_fn cabledyn_real_dsbgvx = NULL;
static cabledyn_dsygv_fn cabledyn_real_dsygv = NULL;

/* Why the run-time load failed, written once by the load (under the once guard) and
 * read only after it: the library, each location tried, and the Windows error. */
static char cabledyn_blas_reason[1536];

/* Appends text to a bounded, null-terminated buffer, truncating. Written by hand, as
 * the decimal conversion below: the OpenBLAS import library also exports C runtime
 * formatting functions, and calling one would import openblas.dll at load time. */
static void cabledyn_append(char *dst, size_t cap, const char *src)
{
    size_t n = strlen(dst);
    while (*src != '\0' && n + 1 < cap) {
        dst[n++] = *src++;
    }
    dst[n] = '\0';
}

static void cabledyn_append_uint(char *dst, size_t cap, unsigned long value)
{
    char digits[24];
    int pos = (int)sizeof digits - 1;
    digits[pos] = '\0';
    do {
        digits[--pos] = (char)('0' + value % 10);
        value /= 10;
    } while (value > 0 && pos > 0);
    cabledyn_append(dst, cap, &digits[pos]);
}

static void cabledyn_append_wide(char *dst, size_t cap, const wchar_t *src)
{
    char text[3 * MAX_PATH + 64];
    if (WideCharToMultiByte(CP_UTF8, 0, src, -1, text, (int)sizeof text, NULL, NULL) <= 0) {
        cabledyn_append(dst, cap, "(unprintable path)");
        return;
    }
    cabledyn_append(dst, cap, text);
}

/* Appends "error <code> (<system text>)". */
static void cabledyn_append_error(char *dst, size_t cap, DWORD code)
{
    char text[256];
    DWORD len = FormatMessageA(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, NULL, code,
                               MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT), text, (DWORD)sizeof text, NULL);
    while (len > 0 && (text[len - 1] == '\r' || text[len - 1] == '\n' || text[len - 1] == ' ' ||
                       text[len - 1] == '.')) {
        text[--len] = '\0';
    }
    cabledyn_append(dst, cap, "error ");
    cabledyn_append_uint(dst, cap, (unsigned long)code);
    if (len > 0) {
        cabledyn_append(dst, cap, " (");
        cabledyn_append(dst, cap, text);
        cabledyn_append(dst, cap, ")");
    }
}

/* Converts a GetProcAddress result to a typed function pointer without a cast
 * between incompatible function types. */
static void cabledyn_resolve(HMODULE mod, const char *name, void *slot, size_t size)
{
    FARPROC proc = GetProcAddress(mod, name);
    wchar_t path[MAX_PATH + 1];
    DWORD len;

    if (proc == NULL) {
        if (!cabledyn_blas_load_failed) {
            cabledyn_blas_reason[0] = '\0';
            cabledyn_append(cabledyn_blas_reason, sizeof cabledyn_blas_reason, "openblas.dll loaded from ");
            len = GetModuleFileNameW(mod, path, MAX_PATH);
            path[len < MAX_PATH ? len : MAX_PATH] = L'\0';
            cabledyn_append_wide(cabledyn_blas_reason, sizeof cabledyn_blas_reason, len > 0 ? path : L"?");
            cabledyn_append(cabledyn_blas_reason, sizeof cabledyn_blas_reason, " does not export ");
            cabledyn_append(cabledyn_blas_reason, sizeof cabledyn_blas_reason, name);
            cabledyn_append(cabledyn_blas_reason, sizeof cabledyn_blas_reason,
                            "; it is not a compatible OpenBLAS build");
        }
        cabledyn_blas_load_failed = 1;
        return;
    }
    memcpy(slot, &proc, size);
}

/* Loads the openblas.dll next to the module holding this code (the CableDyn DLL or
 * executable), falling back to the standard search order. On failure, records in
 * cabledyn_blas_reason each location tried and why it failed. */
static HMODULE cabledyn_load_openblas(void)
{
    char *why = cabledyn_blas_reason;
    const size_t cap = sizeof cabledyn_blas_reason;
    HMODULE self = NULL;
    HMODULE blas = NULL;
    wchar_t module[MAX_PATH + 1];
    wchar_t path[MAX_PATH + 16];
    DWORD len = 0, code;
    wchar_t *slash;

    why[0] = '\0';
    module[0] = L'\0';
    cabledyn_append(why, cap, "the LAPACK runtime openblas.dll could not be loaded: ");
    if (GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           (LPCWSTR)(const void *)&cabledyn_blas_threads_set, &self)) {
        len = GetModuleFileNameW(self, module, MAX_PATH);
    }
    if (len > 0 && len < MAX_PATH) {
        module[len] = L'\0';
        wcscpy(path, module);
        slash = wcsrchr(path, L'\\');
        if (slash != NULL) {
            wcscpy(slash + 1, L"openblas.dll");
            cabledyn_append(why, cap, "tried ");
            cabledyn_append_wide(why, cap, path);
            if (GetFileAttributesW(path) == INVALID_FILE_ATTRIBUTES) {
                cabledyn_append(why, cap, " (next to ");
                cabledyn_append_wide(why, cap, module);
                cabledyn_append(why, cap, "): not found; ");
            } else {
                blas = LoadLibraryExW(path, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
                if (blas == NULL) {
                    code = GetLastError();
                    cabledyn_append(why, cap, ": exists but LoadLibrary failed with ");
                    cabledyn_append_error(why, cap, code);
                    cabledyn_append(why, cap, "; ");
                }
            }
        }
    } else {
        module[0] = L'\0';
        cabledyn_append(why, cap, "the CableDyn module path is unknown; ");
    }
    if (blas == NULL) {
        blas = LoadLibraryW(L"openblas.dll");
        if (blas == NULL) {
            code = GetLastError();
            cabledyn_append(why, cap, "then the standard DLL search order (application directory, "
                                      "system directories, PATH): LoadLibrary failed with ");
            cabledyn_append_error(why, cap, code);
            cabledyn_append(why, cap, ". Place openblas.dll");
            if (module[0] != L'\0') {
                cabledyn_append(why, cap, " next to ");
                cabledyn_append_wide(why, cap, module);
            }
            cabledyn_append(why, cap, " or on PATH");
        }
    }
    if (blas != NULL) {
        why[0] = '\0';
    }
    return blas;
}

static void cabledyn_blas_threads_apply(void)
{
    int requested = cabledyn_blas_threads_requested();
    /* An explicit user setting of OPENBLAS_NUM_THREADS is left as it is. */
    int set_env = requested > 0 && getenv("OPENBLAS_NUM_THREADS") == NULL;
    char count[16];
    HMODULE blas;
    cabledyn_set_threads_fn set_threads = NULL;

    if (set_env) {
        /* Decimal digits of 1..4096 by hand: the OpenBLAS import library also exports
         * snprintf, and calling it would import openblas.dll at load time. */
        int value = requested, pos = (int)sizeof count - 1;
        count[pos] = '\0';
        do {
            count[--pos] = (char)('0' + value % 10);
            value /= 10;
        } while (value > 0 && pos > 0);
        _putenv_s("OPENBLAS_NUM_THREADS", &count[pos]);
    }
    blas = cabledyn_load_openblas();
    if (set_env) {
        _putenv_s("OPENBLAS_NUM_THREADS", "");
    }
    if (blas == NULL) {
        cabledyn_blas_load_failed = 1;
        return;
    }
    cabledyn_resolve(blas, "dgbsv_", &cabledyn_real_dgbsv, sizeof cabledyn_real_dgbsv);
    cabledyn_resolve(blas, "dgbtrf_", &cabledyn_real_dgbtrf, sizeof cabledyn_real_dgbtrf);
    cabledyn_resolve(blas, "dgbtrs_", &cabledyn_real_dgbtrs, sizeof cabledyn_real_dgbtrs);
    cabledyn_resolve(blas, "dgbsvx_", &cabledyn_real_dgbsvx, sizeof cabledyn_real_dgbsvx);
    cabledyn_resolve(blas, "dpbtrf_", &cabledyn_real_dpbtrf, sizeof cabledyn_real_dpbtrf);
    cabledyn_resolve(blas, "dpbtrs_", &cabledyn_real_dpbtrs, sizeof cabledyn_real_dpbtrs);
    cabledyn_resolve(blas, "dsbgvx_", &cabledyn_real_dsbgvx, sizeof cabledyn_real_dsbgvx);
    cabledyn_resolve(blas, "dsyev_", &cabledyn_real_dsyev, sizeof cabledyn_real_dsyev);
    cabledyn_resolve(blas, "dsygv_", &cabledyn_real_dsygv, sizeof cabledyn_real_dsygv);
    cabledyn_resolve(blas, "openblas_set_num_threads", &set_threads, sizeof set_threads);
    if (cabledyn_blas_load_failed) {
        return;
    }
    if (requested > 0) {
        /* Another component may have loaded this DLL first with a larger pool; limit
         * how many workers each call uses. */
        set_threads(requested);
        cabledyn_blas_threads_set = requested;
    }
}

/* Writes "<requester>: <reason>" (null-terminated, truncated to msg_len). */
static void cabledyn_blas_describe(const char *requester, char *msg, int msg_len)
{
    size_t cap = (size_t)msg_len;
    msg[0] = '\0';
    cabledyn_append(msg, cap, (requester != NULL && requester[0] != '\0') ? requester : "CableDyn");
    cabledyn_append(msg, cap, ": ");
    cabledyn_append(msg, cap, cabledyn_blas_reason[0] != '\0' ? cabledyn_blas_reason
                                                               : "the LAPACK runtime openblas.dll could not be loaded");
}

#elif defined(CABLEDYN_HAVE_OPENBLAS_SET_NUM_THREADS)

void openblas_set_num_threads(int num_threads);

static void cabledyn_blas_threads_apply(void)
{
    int requested = cabledyn_blas_threads_requested();

    if (requested > 0) {
        openblas_set_num_threads(requested);
        cabledyn_blas_threads_set = requested;
    }
}

#else

static void cabledyn_blas_threads_apply(void)
{
    (void)cabledyn_blas_threads_requested();
}

#endif

#if defined(_WIN32)
static INIT_ONCE cabledyn_blas_once = INIT_ONCE_STATIC_INIT;

static BOOL CALLBACK cabledyn_blas_once_cb(PINIT_ONCE once, PVOID param, PVOID *context)
{
    (void)once;
    (void)param;
    (void)context;
    cabledyn_blas_threads_apply();
    return TRUE;
}

int cabledyn_blas_threads_once(void)
{
    InitOnceExecuteOnce(&cabledyn_blas_once, cabledyn_blas_once_cb, NULL, NULL);
    return cabledyn_blas_load_failed;
}
#else
static pthread_once_t cabledyn_blas_once = PTHREAD_ONCE_INIT;

int cabledyn_blas_threads_once(void)
{
    (void)pthread_once(&cabledyn_blas_once, cabledyn_blas_threads_apply);
    return cabledyn_blas_load_failed;
}
#endif

int cabledyn_blas_threads_applied(void)
{
    (void)cabledyn_blas_threads_once();
    return cabledyn_blas_threads_set;
}

int cabledyn_blas_runtime_status(const char *requester, char *msg, int msg_len)
{
    int failed = cabledyn_blas_threads_once();

    if (msg != NULL && msg_len > 0) {
        msg[0] = '\0';
#if defined(_WIN32) && defined(CABLEDYN_BLAS_RUNTIME_LOAD)
        if (failed) {
            cabledyn_blas_describe(requester, msg, msg_len);
        }
#else
        (void)requester;
#endif
    }
    return failed;
}

#if defined(_WIN32) && defined(CABLEDYN_BLAS_RUNTIME_LOAD)
/* LAPACK entry points with the gfortran calling convention (hidden CHARACTER lengths
 * last). When OpenBLAS cannot be loaded, INFO is CABLEDYN_BLAS_UNAVAILABLE_INFO, which
 * the Fortran callers map to the load diagnostic, so the solver fails closed with the
 * real cause instead of the process faulting. */

void dgbsv_(const int *n, const int *kl, const int *ku, const int *nrhs, double *ab, const int *ldab, int *ipiv,
            double *b, const int *ldb, int *info);
void dgbtrf_(const int *m, const int *n, const int *kl, const int *ku, double *ab, const int *ldab, int *ipiv,
             int *info);
void dgbtrs_(const char *trans, const int *n, const int *kl, const int *ku, const int *nrhs, const double *ab,
             const int *ldab, const int *ipiv, double *b, const int *ldb, int *info, size_t trans_len);
void dgbsvx_(const char *fact, const char *trans, const int *n, const int *kl, const int *ku, const int *nrhs,
             double *ab, const int *ldab, double *afb, const int *ldafb, int *ipiv, char *equed, double *r,
             double *c, double *b, const int *ldb, double *x, const int *ldx, double *rcond, double *ferr,
             double *berr, double *work, int *iwork, int *info, size_t fact_len, size_t trans_len,
             size_t equed_len);
void dpbtrf_(const char *uplo, const int *n, const int *kd, double *ab, const int *ldab, int *info,
             size_t uplo_len);
void dpbtrs_(const char *uplo, const int *n, const int *kd, const int *nrhs, const double *ab, const int *ldab,
             double *b, const int *ldb, int *info, size_t uplo_len);
void dsbgvx_(const char *jobz, const char *range, const char *uplo, const int *n, const int *ka, const int *kb,
             double *ab, const int *ldab, double *bb, const int *ldbb, double *q, const int *ldq, const double *vl,
             const double *vu, const int *il, const int *iu, const double *abstol, int *m, double *w, double *z,
             const int *ldz, double *work, int *iwork, int *ifail, int *info, size_t jobz_len, size_t range_len,
             size_t uplo_len);
void dsyev_(const char *jobz, const char *uplo, const int *n, double *a, const int *lda, double *w, double *work,
            const int *lwork, int *info, size_t jobz_len, size_t uplo_len);
void dsygv_(const int *itype, const char *jobz, const char *uplo, const int *n, double *a, const int *lda,
            double *b, const int *ldb, double *w, double *work, const int *lwork, int *info, size_t jobz_len,
            size_t uplo_len);

void dgbsv_(const int *n, const int *kl, const int *ku, const int *nrhs, double *ab, const int *ldab, int *ipiv,
            double *b, const int *ldb, int *info)
{
    if (cabledyn_blas_threads_once() != 0) {
        *info = CABLEDYN_BLAS_UNAVAILABLE_INFO;
        return;
    }
    cabledyn_real_dgbsv(n, kl, ku, nrhs, ab, ldab, ipiv, b, ldb, info);
}

void dgbtrf_(const int *m, const int *n, const int *kl, const int *ku, double *ab, const int *ldab, int *ipiv,
             int *info)
{
    if (cabledyn_blas_threads_once() != 0) {
        *info = CABLEDYN_BLAS_UNAVAILABLE_INFO;
        return;
    }
    cabledyn_real_dgbtrf(m, n, kl, ku, ab, ldab, ipiv, info);
}

void dgbtrs_(const char *trans, const int *n, const int *kl, const int *ku, const int *nrhs, const double *ab,
             const int *ldab, const int *ipiv, double *b, const int *ldb, int *info, size_t trans_len)
{
    if (cabledyn_blas_threads_once() != 0) {
        *info = CABLEDYN_BLAS_UNAVAILABLE_INFO;
        return;
    }
    cabledyn_real_dgbtrs(trans, n, kl, ku, nrhs, ab, ldab, ipiv, b, ldb, info, trans_len);
}

void dgbsvx_(const char *fact, const char *trans, const int *n, const int *kl, const int *ku, const int *nrhs,
             double *ab, const int *ldab, double *afb, const int *ldafb, int *ipiv, char *equed, double *r,
             double *c, double *b, const int *ldb, double *x, const int *ldx, double *rcond, double *ferr,
             double *berr, double *work, int *iwork, int *info, size_t fact_len, size_t trans_len,
             size_t equed_len)
{
    if (cabledyn_blas_threads_once() != 0) {
        *info = CABLEDYN_BLAS_UNAVAILABLE_INFO;
        return;
    }
    cabledyn_real_dgbsvx(fact, trans, n, kl, ku, nrhs, ab, ldab, afb, ldafb, ipiv, equed, r, c, b, ldb, x, ldx,
                         rcond, ferr, berr, work, iwork, info, fact_len, trans_len, equed_len);
}

void dpbtrf_(const char *uplo, const int *n, const int *kd, double *ab, const int *ldab, int *info,
             size_t uplo_len)
{
    if (cabledyn_blas_threads_once() != 0) {
        *info = CABLEDYN_BLAS_UNAVAILABLE_INFO;
        return;
    }
    cabledyn_real_dpbtrf(uplo, n, kd, ab, ldab, info, uplo_len);
}

void dpbtrs_(const char *uplo, const int *n, const int *kd, const int *nrhs, const double *ab, const int *ldab,
             double *b, const int *ldb, int *info, size_t uplo_len)
{
    if (cabledyn_blas_threads_once() != 0) {
        *info = CABLEDYN_BLAS_UNAVAILABLE_INFO;
        return;
    }
    cabledyn_real_dpbtrs(uplo, n, kd, nrhs, ab, ldab, b, ldb, info, uplo_len);
}

void dsbgvx_(const char *jobz, const char *range, const char *uplo, const int *n, const int *ka, const int *kb,
             double *ab, const int *ldab, double *bb, const int *ldbb, double *q, const int *ldq, const double *vl,
             const double *vu, const int *il, const int *iu, const double *abstol, int *m, double *w, double *z,
             const int *ldz, double *work, int *iwork, int *ifail, int *info, size_t jobz_len, size_t range_len,
             size_t uplo_len)
{
    if (cabledyn_blas_threads_once() != 0) {
        *info = CABLEDYN_BLAS_UNAVAILABLE_INFO;
        return;
    }
    cabledyn_real_dsbgvx(jobz, range, uplo, n, ka, kb, ab, ldab, bb, ldbb, q, ldq, vl, vu, il, iu, abstol, m, w, z,
                         ldz, work, iwork, ifail, info, jobz_len, range_len, uplo_len);
}

void dsyev_(const char *jobz, const char *uplo, const int *n, double *a, const int *lda, double *w, double *work,
            const int *lwork, int *info, size_t jobz_len, size_t uplo_len)
{
    if (cabledyn_blas_threads_once() != 0) {
        *info = CABLEDYN_BLAS_UNAVAILABLE_INFO;
        return;
    }
    cabledyn_real_dsyev(jobz, uplo, n, a, lda, w, work, lwork, info, jobz_len, uplo_len);
}

void dsygv_(const int *itype, const char *jobz, const char *uplo, const int *n, double *a, const int *lda,
            double *b, const int *ldb, double *w, double *work, const int *lwork, int *info, size_t jobz_len,
            size_t uplo_len)
{
    if (cabledyn_blas_threads_once() != 0) {
        *info = CABLEDYN_BLAS_UNAVAILABLE_INFO;
        return;
    }
    cabledyn_real_dsygv(itype, jobz, uplo, n, a, lda, b, ldb, w, work, lwork, info, jobz_len, uplo_len);
}
#endif

/* File: src/cabledyn_cpu_guard.c
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
 *
 * Start-up check of the processor for builds that target x86-64-v3 (CABLEDYN_TARGET_AVX2).
 *
 * Such a build lets the Fortran compiler and its vector maths use AVX2, FMA, BMI1/BMI2, LZCNT,
 * MOVBE and F16C anywhere, so on an older processor it would stop at its first such
 * instruction with an illegal-instruction fault and no explanation. This file is compiled without those
 * instructions; when CABLEDYN_REQUIRE_X86_64_V3 is defined it registers a load-time
 * initializer (a CRT initializer with MSVC-style toolchains, a constructor with GNU-style
 * ones) that runs before any Fortran code of the executable or shared library. On a
 * processor (or operating system) without the x86-64-v3 features it writes which are
 * missing to standard error and ends the process with status 3.
 *
 * The message is written with the operating system's own calls and no C library string or
 * stdio function: in the Windows GNU build those names can resolve to the same exports of
 * openblas.dll, which would then be imported at load time (CABLEDYN_BLAS_RUNTIME_LOAD loads
 * it on first use instead).
 *
 * CABLEDYN_CPU_GUARD_SIMULATE, when set to a non-empty value in an armed build, is reported
 * as a missing feature, so the release gates and the tests can exercise the stop on any
 * processor.
 */

/* Writes the missing x86-64-v3 features, space-separated, to buf (empty when none is
 * missing or the target is not x86-64) and returns their number. */
int cabledyn_cpu_missing_features(char *buf, int len);
/* 1 when this build carries the start-up check, 0 otherwise. */
int cabledyn_cpu_guard_armed(void);

/* Appends text (and a separating space when buf is not empty) if it fits with the
 * terminator; returns 1 when it did. */
static int append(char *buf, int len, const char *text, int separate) {
  int used = 0, n = 0, i;
  if (!buf || len <= 0) return 0;
  while (used < len && buf[used]) ++used;
  while (text[n]) ++n;
  if (separate && used > 0) {
    if (used + 1 + n + 1 > len) return 0;
    buf[used++] = ' ';
  } else if (used + n + 1 > len) {
    return 0;
  }
  for (i = 0; i < n; ++i) buf[used + i] = text[i];
  buf[used + n] = '\0';
  return 1;
}

#if defined(_M_X64) || defined(__x86_64__)
#if defined(_MSC_VER)
#include <intrin.h>
static void cpuid_count(unsigned leaf, unsigned sub, unsigned r[4]) {
  int v[4];
  __cpuidex(v, (int)leaf, (int)sub);
  r[0] = (unsigned)v[0]; r[1] = (unsigned)v[1]; r[2] = (unsigned)v[2]; r[3] = (unsigned)v[3];
}
static unsigned long long read_xcr0(void) { return _xgetbv(0); }
#else
#include <cpuid.h>
static void cpuid_count(unsigned leaf, unsigned sub, unsigned r[4]) {
  __cpuid_count(leaf, sub, r[0], r[1], r[2], r[3]);
}
static unsigned long long read_xcr0(void) {
  unsigned lo, hi;
  __asm__ volatile("xgetbv" : "=a"(lo), "=d"(hi) : "c"(0));
  return ((unsigned long long)hi << 32) | lo;
}
#endif

static void note(char *buf, int len, int *count, const char *name) {
  ++*count;
  append(buf, len, name, 1);
}

int cabledyn_cpu_missing_features(char *buf, int len) {
  unsigned r0[4], r1[4], r7[4] = {0, 0, 0, 0}, rx[4] = {0, 0, 0, 0};
  int count = 0, os_avx = 0;
  if (buf && len > 0) buf[0] = '\0';
  cpuid_count(0, 0, r0);
  cpuid_count(1, 0, r1);
  if (r0[0] >= 7) cpuid_count(7, 0, r7);
  cpuid_count(0x80000000u, 0, rx);
  if (rx[0] >= 0x80000001u) cpuid_count(0x80000001u, 0, rx);
  else rx[2] = 0;
  /* AVX state enabled by the operating system: OSXSAVE, then XMM and YMM in XCR0 */
  if (r1[2] & (1u << 27)) os_avx = (read_xcr0() & 6u) == 6u;
  if (!(r1[2] & (1u << 28))) note(buf, len, &count, "AVX");
  if (!(r7[1] & (1u << 5))) note(buf, len, &count, "AVX2");
  if (!(r1[2] & (1u << 12))) note(buf, len, &count, "FMA");
  if (!(r7[1] & (1u << 3))) note(buf, len, &count, "BMI1");
  if (!(r7[1] & (1u << 8))) note(buf, len, &count, "BMI2");
  if (!(rx[2] & (1u << 5))) note(buf, len, &count, "LZCNT");
  if (!(r1[2] & (1u << 22))) note(buf, len, &count, "MOVBE");
  if (!(r1[2] & (1u << 29))) note(buf, len, &count, "F16C");
  if (!os_avx) note(buf, len, &count, "OS-AVX-state");
  return count;
}
#else
int cabledyn_cpu_missing_features(char *buf, int len) {
  if (buf && len > 0) buf[0] = '\0';
  return 0;
}
#endif

#if defined(CABLEDYN_REQUIRE_X86_64_V3)
int cabledyn_cpu_guard_armed(void) { return 1; }

#if defined(_WIN32)
#include <windows.h>
static int simulated_missing(char *buf, int len) {
  DWORD n = GetEnvironmentVariableA("CABLEDYN_CPU_GUARD_SIMULATE", buf, (DWORD)len);
  return n > 0 && n < (DWORD)len;
}
static void stop(const char *text, int n) {
  DWORD written = 0;
  HANDLE err = GetStdHandle(STD_ERROR_HANDLE);
  if (err != NULL && err != INVALID_HANDLE_VALUE) WriteFile(err, text, (DWORD)n, &written, NULL);
  ExitProcess(3);
}
#else
#include <stdlib.h>
#include <unistd.h>
static int simulated_missing(char *buf, int len) {
  const char *value = getenv("CABLEDYN_CPU_GUARD_SIMULATE");
  if (!value || !value[0]) return 0;
  buf[0] = '\0';
  return append(buf, len, value, 0);
}
static void stop(const char *text, int n) {
  ssize_t ignored = write(STDERR_FILENO, text, (size_t)n);
  (void)ignored;
  _exit(3);
}
#endif

static void cabledyn_cpu_guard_check(void) {
  char missing[128], message[512];
  int n = 0;
  if (!simulated_missing(missing, (int)sizeof missing) &&
      cabledyn_cpu_missing_features(missing, (int)sizeof missing) == 0)
    return;
  message[0] = '\0';
  append(message, (int)sizeof message,
         "CableDyn: this build needs an x86-64 processor with AVX2 (x86-64-v3: Intel Haswell "
         "or AMD Excavator and newer). This computer lacks: ", 0);
  append(message, (int)sizeof message, missing, 0);
  append(message, (int)sizeof message,
         ".\nCableDyn: build CableDyn from source without CABLEDYN_TARGET_AVX2 to run here.\n", 0);
  while (message[n]) ++n;
  stop(message, n);
}

#if defined(_MSC_VER)
/* A CRT initializer: runs during C run-time start-up of the executable or DLL, before
 * main and before any Fortran code. The object is linked wherever cabledyn_cpu_guard_armed
 * is referenced (the driver, the OpenFAST module, the shared library). */
#pragma section(".CRT$XCU", read)
__declspec(allocate(".CRT$XCU")) void (*cabledyn_cpu_guard_init)(void) = cabledyn_cpu_guard_check;
#else
__attribute__((constructor)) static void cabledyn_cpu_guard_ctor(void) { cabledyn_cpu_guard_check(); }
#endif
#else
int cabledyn_cpu_guard_armed(void) { return 0; }
#endif

/* File: src/cabledyn_path.c
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
 *
 * File-name services for the Fortran I/O layer.
 *
 * The Fortran runtime opens files through the narrow (byte-string) C library. On
 * Windows those calls interpret a name in the active ANSI code page, and the command
 * line reaches the program already converted to that code page with "best fit"
 * substitution: "café" can arrive as "cafe", so a run silently reads or writes a
 * different file, and characters outside the code page arrive as '?'. This unit
 * keeps every name in UTF-8 inside the program and converts it to a spelling the
 * narrow runtime opens exactly:
 *
 *   cabledyn_path_arg_count / cabledyn_path_arg
 *       the command-line arguments as UTF-8, taken from the wide command line;
 *   cabledyn_path_native
 *       a UTF-8 name (or, when the bytes are not valid UTF-8, a name already in
 *       the ANSI code page) converted to a name the narrow runtime opens exactly:
 *       the name itself when the code page represents it without substitution and
 *       it fits MAX_PATH, else the 8.3 short name of the existing file or of its
 *       existing parent directory, else an extended-length "\\?\" name; reserved
 *       device names (CON, NUL, COM1, ...) are refused because opening them reads
 *       the console or discards output;
 *   cabledyn_path_lock
 *       an exclusive lock file for an output root, released by the operating
 *       system when the process ends, however it ends;
 *   cabledyn_path_probe
 *       whether the system opens a runtime spelling for reading or for writing, asked
 *       before the Fortran OPEN so that an OPEN that would fail is never attempted
 *       (see CD_Path_Openable in src/CableDyn_PathIO.f90).
 *
 * On other systems names are UTF-8 byte strings that the runtime opens unchanged,
 * so the conversion is the identity and the lock uses an advisory flock().
 */
/* flock() is outside strict C11; request the platform declarations. */
#define _DEFAULT_SOURCE
#define _DARWIN_C_SOURCE
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

/* Status codes shared with src/CableDyn_PathIO.f90. */
#define CD_PATH_ERR_GENERAL (-1)
#define CD_PATH_ERR_DEVICE (-2)
#define CD_PATH_ERR_UNREPRESENTABLE (-3)
#define CD_PATH_ERR_TOO_LONG (-4)
#define CD_PATH_ERR_BUFFER (-5)

#define CD_LOCK_ACQUIRED 0
#define CD_LOCK_HELD 1
#define CD_LOCK_FAILED 2

int cabledyn_path_arg_count(void);
int cabledyn_path_arg(int index, char *buf, int buflen);
int cabledyn_path_native(const char *in, int in_len, int for_output, int reserve, char *out, int outlen);
int cabledyn_path_is_device(const char *in, int in_len);
int cabledyn_path_lock(const char *in, int in_len);
int cabledyn_path_probe(const char *in, int in_len, int for_output);

/* The name s[0..n) as a NUL-terminated copy (malloc), or NULL. */
static char *terminated(const char *s, int n) {
  char *t;
  if (s == NULL || n <= 0) return NULL;
  t = (char *)malloc((size_t)n + 1);
  if (t == NULL) return NULL;
  memcpy(t, s, (size_t)n);
  t[n] = '\0';
  return t;
}

/* Copies n bytes and a terminating NUL when they fit; returns n or CD_PATH_ERR_BUFFER. */
static int copy_out(const char *src, int n, char *out, int outlen) {
  if (n < 0 || n + 1 > outlen) return CD_PATH_ERR_BUFFER;
  memcpy(out, src, (size_t)n);
  out[n] = '\0';
  return n;
}

/* True when the component c[0..n) names a reserved Windows device. Windows ignores
 * everything from the first '.' or ':' and trailing spaces when it matches these
 * names, and reserves them in every directory. The superscript digits 1-3 (U+00B9,
 * U+00B2, U+00B3, two UTF-8 bytes each) are reserved like the ASCII digits. */
static int is_device_component(const char *c, int n) {
  static const char *const names[] = {"CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"};
  char stem[16];
  int len = 0, i;
  for (i = 0; i < n && c[i] != '.' && c[i] != ':'; ++i) {
    if (len >= (int)sizeof(stem) - 1) return 0;
    stem[len++] = c[i];
  }
  while (len > 0 && stem[len - 1] == ' ') --len;
  stem[len] = '\0';
  for (i = 0; i < len; ++i) {
    if (stem[i] >= 'a' && stem[i] <= 'z') stem[i] = (char)(stem[i] - 'a' + 'A');
  }
  for (i = 0; i < (int)(sizeof(names) / sizeof(names[0])); ++i) {
    if (strcmp(stem, names[i]) == 0) return 1;
  }
  if ((len == 4 || len == 5) && (strncmp(stem, "COM", 3) == 0 || strncmp(stem, "LPT", 3) == 0)) {
    const unsigned char d0 = (unsigned char)stem[3];
    if (len == 4 && d0 >= '1' && d0 <= '9') return 1;
    if (len == 5 && d0 == 0xC2) {
      const unsigned char d1 = (unsigned char)stem[4];
      if (d1 == 0xB9 || d1 == 0xB2 || d1 == 0xB3) return 1;
    }
  }
  return 0;
}

/* 1 when any component of the UTF-8 or ANSI name s[0..n) is a reserved Windows
 * device, or the name uses the \\.\ device namespace; always 0 off Windows. */
int cabledyn_path_is_device(const char *s, int n) {
#if defined(_WIN32)
  int start = 0, i;
  if (s == NULL || n <= 0) return 0;
  if (n >= 4 && (s[0] == '\\' || s[0] == '/') && (s[1] == '\\' || s[1] == '/') && s[2] == '.' &&
      (s[3] == '\\' || s[3] == '/'))
    return 1;
  for (i = 0; i <= n; ++i) {
    if (i == n || s[i] == '/' || s[i] == '\\') {
      if (i > start && is_device_component(s + start, i - start)) return 1;
      start = i + 1;
    }
  }
  return 0;
#else
  (void)s;
  (void)n;
  return 0;
#endif
}

#if defined(_WIN32)
#include <windows.h>
#include <shellapi.h>
#if defined(_MSC_VER)
#pragma comment(lib, "shell32.lib")
#endif

#define CD_MAX_PATH_CHARS (MAX_PATH - 1)

/* The command line as wide arguments, parsed once; argv[0] is the program. */
static LPWSTR *wide_argv(int *argc) {
  static LPWSTR *argv = NULL;
  static int count = -1;
  if (count < 0) {
    int n = 0;
    LPWSTR *parsed = CommandLineToArgvW(GetCommandLineW(), &n);
    if (parsed == NULL) return NULL;
    argv = parsed;
    count = n;
  }
  *argc = count;
  return argv;
}

int cabledyn_path_arg_count(void) {
  int argc = 0;
  if (wide_argv(&argc) == NULL || argc < 1) return -1;
  return argc - 1;
}

int cabledyn_path_arg(int index, char *buf, int buflen) {
  int argc = 0, need;
  LPWSTR *argv = wide_argv(&argc);
  if (argv == NULL || index < 1 || index >= argc) return CD_PATH_ERR_GENERAL;
  need = WideCharToMultiByte(CP_UTF8, 0, argv[index], -1, NULL, 0, NULL, NULL);
  if (need <= 0) return CD_PATH_ERR_GENERAL;
  if (need > buflen) return need - 1; /* length without the NUL; buffer left untouched */
  if (WideCharToMultiByte(CP_UTF8, 0, argv[index], -1, buf, buflen, NULL, NULL) != need)
    return CD_PATH_ERR_GENERAL;
  return need - 1;
}

/* Heap-allocated wide copy of the n-byte name: UTF-8 when valid, else the ANSI
 * code page (a name that already arrived in the narrow encoding). */
static wchar_t *to_wide(const char *s, int n) {
  UINT cp = CP_UTF8;
  DWORD flags = MB_ERR_INVALID_CHARS;
  int wn = MultiByteToWideChar(cp, flags, s, n, NULL, 0);
  wchar_t *w;
  if (wn <= 0) {
    cp = CP_ACP;
    flags = 0;
    wn = MultiByteToWideChar(cp, flags, s, n, NULL, 0);
    if (wn <= 0) return NULL;
  }
  w = (wchar_t *)malloc(((size_t)wn + 1) * sizeof(wchar_t));
  if (w == NULL) return NULL;
  if (MultiByteToWideChar(cp, flags, s, n, w, wn) != wn) {
    free(w);
    return NULL;
  }
  w[wn] = L'\0';
  return w;
}

/* The wide name in the ANSI code page when every character converts exactly (no
 * default character, no best-fit substitution, and a lossless round trip).
 * Returns the byte length written, CD_PATH_ERR_UNREPRESENTABLE, or
 * CD_PATH_ERR_BUFFER. */
static int to_ansi_exact(const wchar_t *w, char *out, int outlen) {
  const UINT acp = GetACP();
  BOOL used_default = FALSE;
  const BOOL utf8_acp = (acp == CP_UTF8);
  const DWORD flags = utf8_acp ? 0 : WC_NO_BEST_FIT_CHARS;
  int n = WideCharToMultiByte(CP_ACP, flags, w, -1, NULL, 0, NULL, utf8_acp ? NULL : &used_default);
  char *tmp;
  wchar_t *back;
  int wn, ok;
  if (n <= 0 || used_default) return CD_PATH_ERR_UNREPRESENTABLE;
  tmp = (char *)malloc((size_t)n);
  if (tmp == NULL) return CD_PATH_ERR_GENERAL;
  if (WideCharToMultiByte(CP_ACP, flags, w, -1, tmp, n, NULL, utf8_acp ? NULL : &used_default) != n ||
      used_default) {
    free(tmp);
    return CD_PATH_ERR_UNREPRESENTABLE;
  }
  wn = MultiByteToWideChar(CP_ACP, 0, tmp, -1, NULL, 0);
  back = wn > 0 ? (wchar_t *)malloc((size_t)wn * sizeof(wchar_t)) : NULL;
  ok = back != NULL && MultiByteToWideChar(CP_ACP, 0, tmp, -1, back, wn) == wn && wcscmp(back, w) == 0;
  free(back);
  if (!ok) {
    free(tmp);
    return CD_PATH_ERR_UNREPRESENTABLE;
  }
  n = copy_out(tmp, n - 1, out, outlen);
  free(tmp);
  return n;
}

/* GetFullPathNameW / GetShortPathNameW into a fresh heap buffer (NULL on failure). */
static wchar_t *full_path(const wchar_t *w) {
  DWORD n = GetFullPathNameW(w, 0, NULL, NULL);
  wchar_t *buf;
  if (n == 0) return NULL;
  buf = (wchar_t *)malloc((size_t)n * sizeof(wchar_t));
  if (buf == NULL) return NULL;
  if (GetFullPathNameW(w, n, buf, NULL) == 0) {
    free(buf);
    return NULL;
  }
  return buf;
}

/* a + b as a fresh wide string (NULL on allocation failure). */
static wchar_t *concat(const wchar_t *a, const wchar_t *b) {
  const size_t na = wcslen(a), nb = wcslen(b);
  wchar_t *r = (wchar_t *)malloc((na + nb + 1) * sizeof(wchar_t));
  if (r == NULL) return NULL;
  memcpy(r, a, na * sizeof(wchar_t));
  memcpy(r + na, b, (nb + 1) * sizeof(wchar_t));
  return r;
}

/* True when the wide string converts exactly to the ANSI code page. */
static int ansi_exact(const wchar_t *w) {
  const size_t cap = 4 * wcslen(w) + 4;
  char *scratch = (char *)malloc(cap);
  int ok;
  if (scratch == NULL) return 0;
  ok = to_ansi_exact(w, scratch, (int)cap) >= 0;
  free(scratch);
  return ok;
}

/* Length of the root of a full path: "X:\" or "\\server\share\" (0 if neither). */
static size_t root_length(const wchar_t *full) {
  size_t i, seps = 0;
  if (full[0] != L'\0' && full[1] == L':' && full[2] == L'\\') return 3;
  if (full[0] != L'\\' || full[1] != L'\\') return 0;
  for (i = 2; full[i] != L'\0'; ++i) {
    if (full[i] == L'\\' && ++seps == 2) return i + 1;
  }
  return 0;
}

/* The spelling of a full path in which every component the ANSI code page cannot
 * represent is replaced by its 8.3 short name, found component by component
 * (GetShortPathNameW keeps a long component it deems a legal 8.3 name even when the
 * code page lacks one of its characters). For a name to be created (for_output) the
 * last component is kept as written. NULL when a component has no usable short name. */
static wchar_t *short_spelling(const wchar_t *full, int for_output) {
  const size_t n = wcslen(full), root = root_length(full);
  wchar_t *longp, *outp, *comp;
  size_t i, start, lo = root, so = root;
  WIN32_FIND_DATAW fd;
  HANDLE h;
  if (root == 0) return NULL;
  longp = (wchar_t *)malloc((n + 1) * sizeof(wchar_t));
  /* a short name (at most 12 characters) can be longer than the component it replaces */
  outp = (wchar_t *)malloc((13 * n + 1) * sizeof(wchar_t));
  comp = (wchar_t *)malloc((n + 1) * sizeof(wchar_t));
  if (longp == NULL || outp == NULL || comp == NULL) goto fail;
  memcpy(longp, full, root * sizeof(wchar_t));
  memcpy(outp, full, root * sizeof(wchar_t));
  for (start = root; start < n; start = i + 1) {
    const wchar_t *use = comp;
    size_t len;
    for (i = start; i < n && full[i] != L'\\'; ++i) {
    }
    len = i - start;
    memcpy(comp, full + start, len * sizeof(wchar_t));
    comp[len] = L'\0';
    memcpy(longp + lo, comp, (len + 1) * sizeof(wchar_t));
    lo += len;
    if (len > 0 && !ansi_exact(comp) && !(for_output && i >= n)) {
      h = FindFirstFileW(longp, &fd);
      if (h == INVALID_HANDLE_VALUE) goto fail;
      FindClose(h);
      if (fd.cAlternateFileName[0] == L'\0' || !ansi_exact(fd.cAlternateFileName)) goto fail;
      use = fd.cAlternateFileName;
    }
    len = wcslen(use);
    memcpy(outp + so, use, len * sizeof(wchar_t));
    so += len;
    if (i < n) {
      longp[lo++] = L'\\';
      outp[so++] = L'\\';
    }
  }
  outp[so] = L'\0';
  free(longp);
  free(comp);
  return outp;
fail:
  free(longp);
  free(outp);
  free(comp);
  return NULL;
}

/* The extended-length "\\?\" form of a full path (UNC paths use "\\?\UNC\"). */
static wchar_t *extended_path(const wchar_t *full) {
  if (wcsncmp(full, L"\\\\?\\", 4) == 0) return concat(L"", full);
  if (wcsncmp(full, L"\\\\", 2) == 0) return concat(L"\\\\?\\UNC\\", full + 2);
  return concat(L"\\\\?\\", full);
}

int cabledyn_path_native(const char *in, int in_len, int for_output, int reserve, char *out, int outlen) {
  wchar_t *w = NULL, *full = NULL, *alt = NULL, *ext = NULL;
  int rc, representable = 0;
  if (in_len <= 0) return copy_out("", 0, out, outlen);
  if (cabledyn_path_is_device(in, in_len)) return CD_PATH_ERR_DEVICE;
  w = to_wide(in, in_len);
  if (w == NULL) return CD_PATH_ERR_GENERAL;
  full = full_path(w);
  if (full == NULL) {
    free(w);
    return CD_PATH_ERR_GENERAL;
  }
  /* 1. the caller's spelling, when it converts exactly and the full name fits */
  rc = to_ansi_exact(w, out, outlen);
  if (rc >= 0) representable = 1;
  if (rc >= 0 && (int)wcslen(full) + reserve <= CD_MAX_PATH_CHARS) goto done;
  if (rc == CD_PATH_ERR_BUFFER) goto done;
  /* 2. the 8.3 short spelling of the existing file or parent directory */
  alt = short_spelling(full, for_output);
  if (alt != NULL) {
    rc = to_ansi_exact(alt, out, outlen);
    if (rc >= 0) representable = 1;
    if (rc >= 0 && (int)wcslen(alt) + reserve <= CD_MAX_PATH_CHARS) goto done;
    if (rc == CD_PATH_ERR_BUFFER) goto done;
  }
  /* 3. an extended-length name, which lifts MAX_PATH for the Win32 file calls */
  ext = extended_path(alt != NULL && representable ? alt : full);
  if (ext != NULL) {
    rc = to_ansi_exact(ext, out, outlen);
    if (rc >= 0 || rc == CD_PATH_ERR_BUFFER) goto done;
  }
  rc = representable ? CD_PATH_ERR_TOO_LONG : CD_PATH_ERR_UNREPRESENTABLE;
done:
  free(ext);
  free(alt);
  free(full);
  free(w);
  return rc;
}

int cabledyn_path_lock(const char *in, int in_len) {
  static HANDLE held = INVALID_HANDLE_VALUE;
  wchar_t *w, *full, *ext;
  HANDLE h;
  DWORD err;
  int attempt;
  if (held != INVALID_HANDLE_VALUE) return CD_LOCK_FAILED;
  w = to_wide(in, in_len);
  if (w == NULL) return CD_LOCK_FAILED;
  full = full_path(w);
  free(w);
  if (full == NULL) return CD_LOCK_FAILED;
  ext = extended_path(full);
  free(full);
  if (ext == NULL) return CD_LOCK_FAILED;
  /* No sharing: a second run's open fails with a sharing violation for as long as
   * this handle lives. FILE_FLAG_DELETE_ON_CLOSE removes the file when the handle
   * closes, which the system does at process exit even after a kill, so a lock is
   * never left behind. A just-closed lock can briefly deny access while its
   * deletion completes; retry that case. */
  for (attempt = 0; attempt < 50; ++attempt) {
    h = CreateFileW(ext, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_ALWAYS,
                    FILE_ATTRIBUTE_TEMPORARY | FILE_ATTRIBUTE_HIDDEN | FILE_FLAG_DELETE_ON_CLOSE, NULL);
    if (h != INVALID_HANDLE_VALUE) {
      free(ext);
      held = h;
      return CD_LOCK_ACQUIRED;
    }
    err = GetLastError();
    if (err == ERROR_SHARING_VIOLATION || err == ERROR_LOCK_VIOLATION) {
      free(ext);
      return CD_LOCK_HELD;
    }
    if (err != ERROR_ACCESS_DENIED) break;
    Sleep(20);
  }
  free(ext);
  return CD_LOCK_FAILED;
}

/* 0 when the system opens the runtime spelling in[0..in_len) (the narrow name the Fortran
 * OPEN is given) for reading an existing file, or for writing (for_output; a missing file
 * is created, an existing one left as it is), else 1. The ANSI entry point reads the name
 * as the runtime's own calls do. A directory is refused: without backup semantics it does
 * not open. The handle is closed at once. */
int cabledyn_path_probe(const char *in, int in_len, int for_output) {
  char *name = terminated(in, in_len);
  HANDLE h;
  if (name == NULL) return 1;
  h = CreateFileA(name, for_output ? GENERIC_WRITE : GENERIC_READ,
                  FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
                  for_output ? OPEN_ALWAYS : OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
  free(name);
  if (h == INVALID_HANDLE_VALUE) return 1;
  CloseHandle(h);
  return 0;
}

#else /* !_WIN32 */

#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

int cabledyn_path_arg_count(void) { return -1; }

int cabledyn_path_arg(int index, char *buf, int buflen) {
  (void)index;
  (void)buf;
  (void)buflen;
  return CD_PATH_ERR_GENERAL;
}

int cabledyn_path_native(const char *in, int in_len, int for_output, int reserve, char *out, int outlen) {
  (void)for_output;
  (void)reserve;
  if (in_len < 0) return CD_PATH_ERR_GENERAL;
  return copy_out(in, in_len, out, outlen);
}

/* 0 when the system opens in[0..in_len) for reading an existing regular file (not a
 * directory), or for writing (for_output; a missing file is created, an existing one left
 * as it is), else 1. */
int cabledyn_path_probe(const char *in, int in_len, int for_output) {
  char *name = terminated(in, in_len);
  struct stat st;
  int fd, ok;
  if (name == NULL) return 1;
  fd = open(name, for_output ? (O_WRONLY | O_CREAT) : O_RDONLY, 0666);
  free(name);
  if (fd < 0) return 1;
  ok = fstat(fd, &st) == 0 && !S_ISDIR(st.st_mode);
  close(fd);
  return ok ? 0 : 1;
}

static char *lock_name = NULL;
static int lock_fd = -1;

/* Removes the lock file of a normally ending run; the flock itself ends with the
 * process, so a lock file left by a killed run is taken over by the next run. */
static void release_lock(void) {
  if (lock_fd >= 0) {
    if (lock_name != NULL) unlink(lock_name);
    close(lock_fd);
    lock_fd = -1;
  }
  free(lock_name);
  lock_name = NULL;
}

int cabledyn_path_lock(const char *in, int in_len) {
  int fd, attempt;
  struct stat held, named;
  if (lock_fd >= 0 || in_len <= 0) return CD_LOCK_FAILED;
  lock_name = (char *)malloc((size_t)in_len + 1);
  if (lock_name == NULL) return CD_LOCK_FAILED;
  memcpy(lock_name, in, (size_t)in_len);
  lock_name[in_len] = '\0';
  /* A run that ends removes its lock file before closing it. A run that opened the
   * old file just before that removal can still lock the removed file, while a later
   * run creates and locks a new one. The lock therefore counts only when the locked
   * file is still the one the path names; otherwise the attempt starts again. */
  for (attempt = 0; attempt < 8; ++attempt) {
    fd = open(lock_name, O_RDWR | O_CREAT, 0666);
    if (fd < 0) break;
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
      close(fd);
      free(lock_name);
      lock_name = NULL;
      return CD_LOCK_HELD;
    }
    if (fstat(fd, &held) == 0 && stat(lock_name, &named) == 0 && held.st_dev == named.st_dev &&
        held.st_ino == named.st_ino) {
      lock_fd = fd;
      atexit(release_lock);
      return CD_LOCK_ACQUIRED;
    }
    close(fd);
  }
  free(lock_name);
  lock_name = NULL;
  return CD_LOCK_FAILED;
}

#endif

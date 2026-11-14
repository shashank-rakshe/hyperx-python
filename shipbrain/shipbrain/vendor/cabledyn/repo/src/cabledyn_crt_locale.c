/* File: src/cabledyn_crt_locale.c
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
 *
 * Guard against a use-after-free in the MinGW-w64 build of libgfortran.
 *
 * On targets without uselocale() (MinGW-w64 with the UCRT), libgfortran brackets
 * every I/O statement with
 *     old = setlocale(LC_NUMERIC, NULL);  setlocale(LC_NUMERIC, "C");
 *     ... transfer ...
 *     setlocale(LC_NUMERIC, old);
 * The UCRT frees the string returned by a narrow setlocale() call on the next
 * setlocale() call for that category, so the restore reads freed heap memory. It
 * usually still holds a readable (if stale) string, but when the allocator has
 * released that page the restore faults inside setlocale() -- an intermittent
 * SIGSEGV at an arbitrary WRITE, most often the last one of a run.
 *
 * cabledyn_crt_locale_guard() redirects the setlocale import of the module that
 * hosts libgfortran (libgfortran-5.dll, or this module when libgfortran is linked
 * statically) to a wrapper that returns query results from a static per-category
 * copy. That copy stays valid until the next query of the same category, and
 * libgfortran issues its query and its restore under one lock, so the restore
 * always reads live memory. Set calls pass through unchanged. Other toolchains
 * compile the guard to a no-op.
 */
/* Installs the guard once (idempotent, thread-safe). */
void cabledyn_crt_locale_guard(void);
/* Installs the guard if needed; returns the number of import slots it redirected. */
int cabledyn_crt_locale_guard_slots(void);

#if defined(__MINGW32__)
#include <windows.h>
#include <locale.h>
#include <string.h>

typedef char *(__cdecl *cabledyn_setlocale_fn)(int, const char *);

/* The UCRT setlocale that the redirected import slots called before the guard. */
static cabledyn_setlocale_fn cabledyn_real_setlocale = NULL;
/* Stable copies of the latest query result per category (LC_ALL .. LC_MAX). */
static char cabledyn_locale_name[LC_MAX + 1][512];
static INIT_ONCE cabledyn_guard_once = INIT_ONCE_STATIC_INIT;
static int cabledyn_guard_slots = 0;

static char *__cdecl cabledyn_stable_setlocale(int category, const char *locale)
{
    char *name = cabledyn_real_setlocale(category, locale);
    size_t len;

    if (locale != NULL || name == NULL || category < LC_MIN || category > LC_MAX) {
        return name;
    }
    len = strlen(name);
    if (len >= sizeof cabledyn_locale_name[0]) {
        return name;
    }
    memcpy(cabledyn_locale_name[category], name, len + 1);
    return cabledyn_locale_name[category];
}

/* Redirect every by-name setlocale import slot of `mod`; returns the slots patched. */
static int cabledyn_patch_setlocale_imports(HMODULE mod)
{
    BYTE *base = (BYTE *)mod;
    IMAGE_DOS_HEADER *dos;
    IMAGE_NT_HEADERS *nt;
    IMAGE_DATA_DIRECTORY dir;
    IMAGE_IMPORT_DESCRIPTOR *imp;
    int patched = 0;

    if (mod == NULL) {
        return 0;
    }
    dos = (IMAGE_DOS_HEADER *)base;
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) {
        return 0;
    }
    nt = (IMAGE_NT_HEADERS *)(base + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE) {
        return 0;
    }
    dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    if (dir.VirtualAddress == 0) {
        return 0;
    }
    for (imp = (IMAGE_IMPORT_DESCRIPTOR *)(base + dir.VirtualAddress); imp->Name != 0; ++imp) {
        IMAGE_THUNK_DATA *names;
        IMAGE_THUNK_DATA *slots;

        if (imp->OriginalFirstThunk == 0) {
            continue;
        }
        names = (IMAGE_THUNK_DATA *)(base + imp->OriginalFirstThunk);
        slots = (IMAGE_THUNK_DATA *)(base + imp->FirstThunk);
        for (; names->u1.AddressOfData != 0; ++names, ++slots) {
            IMAGE_IMPORT_BY_NAME *by_name;
            cabledyn_setlocale_fn target;
            DWORD protect;

            if (IMAGE_SNAP_BY_ORDINAL(names->u1.Ordinal)) {
                continue;
            }
            by_name = (IMAGE_IMPORT_BY_NAME *)(base + names->u1.AddressOfData);
            if (strcmp((const char *)by_name->Name, "setlocale") != 0) {
                continue;
            }
            target = (cabledyn_setlocale_fn)slots->u1.Function;
            if (target == cabledyn_stable_setlocale) {
                continue;
            }
            /* One wrapper forwards to one CRT; leave a slot bound to another CRT alone. */
            if (cabledyn_real_setlocale == NULL) {
                cabledyn_real_setlocale = target;
            } else if (target != cabledyn_real_setlocale) {
                continue;
            }
            if (!VirtualProtect(&slots->u1.Function, sizeof slots->u1.Function, PAGE_READWRITE, &protect)) {
                continue;
            }
            slots->u1.Function = (ULONG_PTR)cabledyn_stable_setlocale;
            VirtualProtect(&slots->u1.Function, sizeof slots->u1.Function, protect, &protect);
            ++patched;
        }
    }
    return patched;
}

static BOOL CALLBACK cabledyn_install_guard(PINIT_ONCE once, PVOID param, PVOID *context)
{
    HMODULE self = NULL;
    HMODULE gfortran = GetModuleHandleW(L"libgfortran-5.dll");

    (void)once;
    (void)param;
    (void)context;
    cabledyn_guard_slots = cabledyn_patch_setlocale_imports(gfortran);
    if (GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           (LPCWSTR)(const void *)&cabledyn_guard_slots, &self) &&
        self != gfortran) {
        cabledyn_guard_slots += cabledyn_patch_setlocale_imports(self);
    }
    return TRUE;
}

void cabledyn_crt_locale_guard(void)
{
    InitOnceExecuteOnce(&cabledyn_guard_once, cabledyn_install_guard, NULL, NULL);
}

int cabledyn_crt_locale_guard_slots(void)
{
    cabledyn_crt_locale_guard();
    return cabledyn_guard_slots;
}

/* Installs the guard when the image that carries this object loads, before main()
 * and so before the first Fortran I/O statement. The shared library links the object
 * directly; CMake adds --undefined=cabledyn_crt_locale_guard to every consumer of the
 * static core so the archive member is always linked. A consumer outside CMake passes
 * that flag itself or calls cabledyn_crt_locale_guard(); repeat calls are no-ops. */
__attribute__((constructor)) static void cabledyn_crt_locale_guard_at_load(void)
{
    cabledyn_crt_locale_guard();
}

#else

void cabledyn_crt_locale_guard(void)
{
}

int cabledyn_crt_locale_guard_slots(void)
{
    return 0;
}

#endif

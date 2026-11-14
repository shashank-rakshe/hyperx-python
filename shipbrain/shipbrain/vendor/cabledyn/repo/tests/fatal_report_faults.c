/* File: tests/fatal_report_faults.c
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) 2026 Jae Hoon Seo, SMI Lab, Inha University
 *
 * Faults that tests/test_fatal_report.f90 provokes to check the abnormal-end report.
 */
#define _DEFAULT_SOURCE
#define _DARWIN_C_SOURCE
#include <signal.h>

void fatal_report_test_null_write(void);
int fatal_report_test_raise_term(void);
int fatal_report_test_fault_context(void);
int fatal_report_test_dispositions(void);
int fatal_report_test_altstack(void);
int fatal_report_test_sent_faults(void);
int fatal_report_test_handlers_unchanged(int phase);

static volatile int *volatile fatal_report_null_target = 0;

/* A write through a null pointer: an access violation / SIGSEGV. */
void fatal_report_test_null_write(void)
{
    *fatal_report_null_target = 1;
}

/* SIGTERM to this process; returns 0 where the report does not handle it (Windows). */
int fatal_report_test_raise_term(void)
{
#if defined(_WIN32)
    return 0;
#else
    raise(SIGTERM);
    return 1;
#endif
}

#if defined(_WIN32)
/* The fault-context check is POSIX-only: returns -1 (skipped). */
int fatal_report_test_fault_context(void)
{
    return -1;
}

/* The disposition check is POSIX-only: returns -1 (skipped). */
int fatal_report_test_dispositions(void)
{
    return -1;
}

/* The alternate-stack check is POSIX-only: returns -1 (skipped). */
int fatal_report_test_altstack(void)
{
    return -1;
}

/* The sent-fault check is POSIX-only: returns -1 (skipped). */
int fatal_report_test_sent_faults(void)
{
    return -1;
}

#include <stdio.h>
#include <windows.h>

/* The unhandled-exception filter a host process set is kept by every library call when the
 * driver has not installed the report. phase 0 records, phase 1 compares. */
static LPTOP_LEVEL_EXCEPTION_FILTER filter_before = NULL;

int fatal_report_test_handlers_unchanged(int phase)
{
    LPTOP_LEVEL_EXCEPTION_FILTER now = SetUnhandledExceptionFilter(NULL);
    SetUnhandledExceptionFilter(now);
    if (phase == 0) {
        filter_before = now;
        return 0;
    }
    if (now != filter_before) {
        fprintf(stderr, "FAIL: host: the unhandled-exception filter changed\n");
        return 1;
    }
    return 0;
}
#else
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

void cabledyn_fatal_report_install(void);
void cabledyn_fatal_report_time(double simulated_time);

#define FAULT_ADDRESS ((uintptr_t)16)

typedef struct {
    int sig;
    int code;
    uintptr_t addr;
} fault_record;

static int fault_pipe = -1;
/* Read through a volatile, so the compiler cannot treat the store as a known-invalid one. */
static volatile uintptr_t fault_address = FAULT_ADDRESS;

/* A handler installed before the report, as a runtime's would be: it records the siginfo it
 * receives, restores the default action and returns, so the fault re-executes and ends the
 * process. */
static void prior_handler(int sig, siginfo_t *info, void *context)
{
    fault_record record;
    ssize_t ignored;
    (void)context;
    record.sig = sig;
    record.code = info != NULL ? info->si_code : -99;
    record.addr = info != NULL ? (uintptr_t)info->si_addr : 0;
    ignored = write(fault_pipe, &record, sizeof record);
    (void)ignored;
    signal(sig, SIG_DFL);
}

static void read_all(int fd, char *buffer, size_t size)
{
    size_t used = 0;
    ssize_t got;
    while (used + 1 < size && (got = read(fd, buffer + used, size - 1 - used)) > 0) {
        used += (size_t)got;
    }
    buffer[used] = '\0';
}

static int count(const char *text, const char *what)
{
    int n = 0;
    const char *at = text;
    while ((at = strstr(at, what)) != NULL) {
        ++n;
        at += strlen(what);
    }
    return n;
}

/* A child process with a three-argument SIGSEGV/SIGBUS handler installs the report and writes
 * to address 16. The previous handler must receive the hardware fault's own siginfo (a
 * positive si_code and si_addr 16, not a re-sent signal), the child must end by that signal,
 * and the report must be written once. Returns 0 when all hold, 1 otherwise. */
int fatal_report_test_fault_context(void)
{
    int records[2], errors[2], status = 0, ok;
    pid_t child;
    fault_record record;
    ssize_t got;
    char text[8192];
    struct sigaction action;

    if (pipe(records) != 0 || pipe(errors) != 0) {
        fprintf(stderr, "FAIL: fault context: pipe() failed\n");
        return 1;
    }
    fflush(NULL);
    child = fork();
    if (child < 0) {
        fprintf(stderr, "FAIL: fault context: fork() failed\n");
        return 1;
    }
    if (child == 0) {
        close(records[0]);
        close(errors[0]);
        dup2(errors[1], STDERR_FILENO);
        fault_pipe = records[1];
        memset(&action, 0, sizeof action);
        action.sa_sigaction = prior_handler;
        sigemptyset(&action.sa_mask);
        action.sa_flags = SA_SIGINFO;
        sigaction(SIGSEGV, &action, NULL);
        sigaction(SIGBUS, &action, NULL);
        cabledyn_fatal_report_install();
        cabledyn_fatal_report_time(7534.6);
        *(volatile int *)fault_address = 1;
        _exit(3);
    }
    close(records[1]);
    close(errors[1]);
    read_all(errors[0], text, sizeof text);
    got = read(records[0], &record, sizeof record);
    waitpid(child, &status, 0);
    fprintf(stderr, "%s", text);
    if (got != (ssize_t)sizeof record) {
        fprintf(stderr, "FAIL: fault context: the previous handler was not called\n");
        return 1;
    }
    fprintf(stderr,
            "fault context: previous handler got signal %d, si_code %d, si_addr %#lx; child "
            "ended %s %d\n",
            record.sig, record.code, (unsigned long)record.addr,
            WIFSIGNALED(status) ? "by signal" : "with status",
            WIFSIGNALED(status) ? WTERMSIG(status) : WEXITSTATUS(status));
    ok = (record.sig == SIGSEGV || record.sig == SIGBUS) && record.code > 0 &&
         record.addr == FAULT_ADDRESS && WIFSIGNALED(status) && WTERMSIG(status) == record.sig &&
         count(text, "CableDyn_driver: fatal error:") == 1 && count(text, "t = 7534.600 s") == 1;
    if (!ok) {
        fprintf(stderr, "FAIL: fault context: the fault did not keep its own context\n");
        return 1;
    }
    return 0;
}

/* SIGTERM handler of the "handler" case: a real one-argument function. */
static void prior_term_handler(int sig)
{
    static const char text[] = "prior SIGTERM handler ran\n";
    ssize_t ignored = write(STDERR_FILENO, text, sizeof text - 1);
    (void)ignored;
    (void)sig;
    _exit(7);
}

/* SIGTERM handler of the SA_RESETHAND case: notes the call and returns. */
static void resethand_term_handler(int sig)
{
    static const char text[] = "reset-on-delivery handler ran\n";
    ssize_t ignored = write(STDERR_FILENO, text, sizeof text - 1);
    (void)ignored;
    (void)sig;
}

/* SIGTERM handler of the sa_mask case: SIGUSR1 (its sa_mask) and SIGTERM itself (no
 * SA_NODEFER) must be blocked while it runs. */
static void masked_term_handler(int sig)
{
    static const char ok_text[] = "masked handler: mask as saved\n";
    static const char bad_text[] = "masked handler: mask NOT as saved\n";
    sigset_t now;
    ssize_t ignored;
    int ok;
    (void)sig;
    sigemptyset(&now);
    sigprocmask(SIG_BLOCK, NULL, &now);
    ok = sigismember(&now, SIGUSR1) == 1 && sigismember(&now, SIGTERM) == 1;
    ignored = ok ? write(STDERR_FILENO, ok_text, sizeof ok_text - 1)
                 : write(STDERR_FILENO, bad_text, sizeof bad_text - 1);
    (void)ignored;
    _exit(5);
}

/* Run one child that sets SIGTERM to `setup`, installs the report and sends itself SIGTERM.
 * setup 0: SIG_IGN with SA_SIGINFO; 1: SIG_IGN; 2: SIG_DFL; 3: a one-argument handler;
 * 4: a handler with SA_RESETHAND (then a second SIGTERM); 5: a handler with sa_mask SIGUSR1. */
static int disposition_case(int setup, const char *name)
{
    int errors[2], status = 0, ok, reports, ran, reset_ran;
    pid_t child;
    char text[4096];
    struct sigaction action;

    if (pipe(errors) != 0) {
        fprintf(stderr, "FAIL: dispositions: pipe() failed\n");
        return 1;
    }
    fflush(NULL);
    child = fork();
    if (child < 0) {
        fprintf(stderr, "FAIL: dispositions: fork() failed\n");
        return 1;
    }
    if (child == 0) {
        close(errors[0]);
        dup2(errors[1], STDERR_FILENO);
        memset(&action, 0, sizeof action);
        sigemptyset(&action.sa_mask);
        if (setup == 0) {
            action.sa_handler = SIG_IGN; /* the sentinel, stored with SA_SIGINFO set */
            action.sa_flags = SA_SIGINFO;
        } else if (setup == 1) {
            action.sa_handler = SIG_IGN;
        } else if (setup == 2) {
            action.sa_handler = SIG_DFL;
        } else if (setup == 3) {
            action.sa_handler = prior_term_handler;
        } else if (setup == 4) {
            action.sa_handler = resethand_term_handler;
            action.sa_flags = SA_RESETHAND;
        } else {
            action.sa_handler = masked_term_handler;
            sigaddset(&action.sa_mask, SIGUSR1);
        }
        sigaction(SIGTERM, &action, NULL);
        cabledyn_fatal_report_install();
        cabledyn_fatal_report_time(7534.6);
        kill(getpid(), SIGTERM);
        if (setup == 4) {
            /* The first SIGTERM reset the disposition: this one takes the default action. */
            kill(getpid(), SIGTERM);
        }
        /* Still running: an ignored SIGTERM must leave the process alone. */
        _exit(0);
    }
    close(errors[1]);
    read_all(errors[0], text, sizeof text);
    waitpid(child, &status, 0);
    reports = count(text, "CableDyn_driver: stopped by a termination request");
    ran = count(text, "prior SIGTERM handler ran");
    reset_ran = count(text, "reset-on-delivery handler ran");
    if (setup <= 1) {
        ok = WIFEXITED(status) && WEXITSTATUS(status) == 0 && reports == 0;
    } else if (setup == 2) {
        ok = WIFSIGNALED(status) && WTERMSIG(status) == SIGTERM && reports == 1;
    } else if (setup == 3) {
        ok = WIFEXITED(status) && WEXITSTATUS(status) == 7 && reports == 1 && ran == 1;
    } else if (setup == 4) {
        ok = WIFSIGNALED(status) && WTERMSIG(status) == SIGTERM && reports == 1 && reset_ran == 1;
    } else {
        ok = WIFEXITED(status) && WEXITSTATUS(status) == 5 && reports == 1 &&
             count(text, "masked handler: mask as saved") == 1;
    }
    fprintf(stderr, "dispositions: %s: child ended %s %d, %d report(s)%s\n", name,
            WIFSIGNALED(status) ? "by signal" : "with status",
            WIFSIGNALED(status) ? WTERMSIG(status) : WEXITSTATUS(status), reports,
            ok ? "" : " -- unexpected");
    if (!ok) {
        fprintf(stderr, "%s", text);
    }
    return ok ? 0 : 1;
}

/* An ignored SIGTERM (with or without SA_SIGINFO) stays ignored and is never reported or
 * called; a default one is reported and ends the process by SIGTERM; a previous handler is
 * reported and then runs under its own flags and mask (SA_RESETHAND resets it, its sa_mask
 * and SIGTERM itself are blocked while it runs). Returns 0 when all hold, 1 otherwise. */
int fatal_report_test_dispositions(void)
{
    int failures = 0;
    failures += disposition_case(0, "SIG_IGN with SA_SIGINFO");
    failures += disposition_case(1, "SIG_IGN");
    failures += disposition_case(2, "SIG_DFL");
    failures += disposition_case(3, "a one-argument handler");
    failures += disposition_case(4, "a handler with SA_RESETHAND");
    failures += disposition_case(5, "a handler with an sa_mask");
    if (failures != 0) {
        fprintf(stderr, "FAIL: dispositions: %d case(s) wrong\n", failures);
        return 1;
    }
    return 0;
}

#include <pthread.h>

void cabledyn_fatal_thread_init(void);
size_t cabledyn_fatal_altstack_size(void);

static int altstack_ok(const char *who, size_t need, void **base)
{
    stack_t current;
    if (sigaltstack(NULL, &current) != 0 || (current.ss_flags & SS_DISABLE) != 0) {
        fprintf(stderr, "FAIL: altstack: %s has no alternate signal stack\n", who);
        return 0;
    }
    if (current.ss_size < need) {
        fprintf(stderr, "FAIL: altstack: %s stack is %lu bytes, below %lu\n", who,
                (unsigned long)current.ss_size, (unsigned long)need);
        return 0;
    }
    if (base != NULL) {
        *base = current.ss_sp;
    }
    return 1;
}

static void *prepared_worker(void *arg)
{
    void *first = NULL, *second = NULL;
    int *ok = (int *)arg;
    cabledyn_fatal_thread_init();
    *ok = altstack_ok("a prepared worker", cabledyn_fatal_altstack_size(), &first);
    cabledyn_fatal_thread_init(); /* once per thread: no second stack */
    *ok = *ok && altstack_ok("a prepared worker", cabledyn_fatal_altstack_size(), &second) &&
          first == second;
    return NULL;
}

static void *plain_worker(void *arg)
{
    stack_t current;
    int *ok = (int *)arg;
    *ok = sigaltstack(NULL, &current) == 0 && (current.ss_flags & SS_DISABLE) != 0;
    return NULL;
}

/* After the report is installed, the main thread and every worker that calls
 * cabledyn_fatal_thread_init have an alternate signal stack of at least 64 KiB and at least the
 * system's SIGSTKSZ / _SC_SIGSTKSZ; a worker that does not call it gets none. */
int fatal_report_test_altstack(void)
{
    pthread_t thread;
    int prepared = 0, plain = 0;
    size_t need = cabledyn_fatal_altstack_size();
    if (need < 64 * 1024) {
        fprintf(stderr, "FAIL: altstack: size %lu is below 64 KiB\n", (unsigned long)need);
        return 1;
    }
#if defined(_SC_SIGSTKSZ)
    if (sysconf(_SC_SIGSTKSZ) > 0 && need < (size_t)sysconf(_SC_SIGSTKSZ)) {
        fprintf(stderr, "FAIL: altstack: size %lu is below _SC_SIGSTKSZ\n", (unsigned long)need);
        return 1;
    }
#endif
    cabledyn_fatal_report_install();
    if (!altstack_ok("the main thread", need, NULL)) {
        return 1;
    }
    if (pthread_create(&thread, NULL, prepared_worker, &prepared) != 0 ||
        pthread_join(thread, NULL) != 0 || !prepared) {
        fprintf(stderr, "FAIL: altstack: a prepared worker thread\n");
        return 1;
    }
    if (pthread_create(&thread, NULL, plain_worker, &plain) != 0 ||
        pthread_join(thread, NULL) != 0 || !plain) {
        fprintf(stderr, "FAIL: altstack: a worker that did not ask has an alternate stack\n");
        return 1;
    }
    fprintf(stderr, "altstack: %lu bytes on the main thread and each prepared worker\n",
            (unsigned long)need);
    return 0;
}

/* The signal dispositions a host process set (here: the defaults) are kept by every library
 * call when the driver has not installed the report. phase 0 records, phase 1 compares. */
static struct sigaction handlers_before[8];
static const int handler_signals[8] = {SIGSEGV, SIGBUS, SIGFPE, SIGILL,
                                       SIGABRT, SIGINT, SIGTERM, SIGHUP};

int fatal_report_test_handlers_unchanged(int phase)
{
    int k;
    struct sigaction now;
    for (k = 0; k < 8; ++k) {
        if (phase == 0) {
            sigaction(handler_signals[k], NULL, &handlers_before[k]);
            continue;
        }
        sigaction(handler_signals[k], NULL, &now);
        if (now.sa_handler != handlers_before[k].sa_handler ||
            now.sa_flags != handlers_before[k].sa_flags) {
            fprintf(stderr, "FAIL: host: the disposition of signal %d changed\n",
                    handler_signals[k]);
            return 1;
        }
    }
    return 0;
}

/* One child sends itself `sig` with kill() after installing the report. A fault signal sent by
 * a process does not re-execute anything, so the report must send it again: the child ends by
 * `sig` with one report, and never runs on to its normal exit. */
static int sent_fault_case(int sig, const char *name)
{
    int errors[2], status = 0, ok, reports;
    pid_t child;
    char text[4096];
    if (pipe(errors) != 0) {
        fprintf(stderr, "FAIL: sent faults: pipe() failed\n");
        return 1;
    }
    fflush(NULL);
    child = fork();
    if (child < 0) {
        fprintf(stderr, "FAIL: sent faults: fork() failed\n");
        return 1;
    }
    if (child == 0) {
        close(errors[0]);
        dup2(errors[1], STDERR_FILENO);
        signal(sig, SIG_DFL);
        cabledyn_fatal_report_install();
        cabledyn_fatal_report_time(7534.6);
        kill(getpid(), sig);
        _exit(0); /* reached only if the sent signal was swallowed */
    }
    close(errors[1]);
    read_all(errors[0], text, sizeof text);
    waitpid(child, &status, 0);
    reports = count(text, "CableDyn_driver: fatal error:");
    ok = WIFSIGNALED(status) && WTERMSIG(status) == sig && reports == 1;
    fprintf(stderr, "sent faults: %s: child ended %s %d, %d report(s)%s\n", name,
            WIFSIGNALED(status) ? "by signal" : "with status",
            WIFSIGNALED(status) ? WTERMSIG(status) : WEXITSTATUS(status), reports,
            ok ? "" : " -- unexpected");
    if (!ok) {
        fprintf(stderr, "%s", text);
    }
    return ok ? 0 : 1;
}

/* SIGSEGV and SIGFPE sent with kill() are reported and re-sent (on macOS SI_USER is positive,
 * so the sender is told apart by name, not by sign). Returns 0 when both hold. */
int fatal_report_test_sent_faults(void)
{
    int failures = sent_fault_case(SIGSEGV, "SIGSEGV from kill()") +
                   sent_fault_case(SIGFPE, "SIGFPE from kill()");
    if (failures != 0) {
        fprintf(stderr, "FAIL: sent faults: %d case(s) wrong\n", failures);
        return 1;
    }
    return 0;
}
#endif

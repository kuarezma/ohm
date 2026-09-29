#include "thaw_table.h"

#include <dlfcn.h>
#include <errno.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

static _Atomic int32_t ohm_slots[OHM_THAW_TABLE_CAPACITY];
static struct sigaction ohm_prev[NSIG];
static _Atomic int ohm_installed = 0;

static const int ohm_signals[] = {
    SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE,
};

int ohm_thaw_table_add(pid_t pid) {
    if (pid <= 0) return -1;
    if (ohm_thaw_table_contains(pid)) return 0;
    for (int i = 0; i < OHM_THAW_TABLE_CAPACITY; i++) {
        int32_t expected = 0;
        if (atomic_compare_exchange_strong(&ohm_slots[i], &expected, (int32_t)pid)) return 0;
    }
    return -1;
}

int ohm_thaw_table_remove(pid_t pid) {
    int removed = 0;
    for (int i = 0; i < OHM_THAW_TABLE_CAPACITY; i++) {
        int32_t expected = (int32_t)pid;
        if (atomic_compare_exchange_strong(&ohm_slots[i], &expected, 0)) removed = 1;
    }
    return removed;
}

int ohm_thaw_table_contains(pid_t pid) {
    for (int i = 0; i < OHM_THAW_TABLE_CAPACITY; i++) {
        if (atomic_load(&ohm_slots[i]) == (int32_t)pid) return 1;
    }
    return 0;
}

int ohm_thaw_table_count(void) {
    int n = 0;
    for (int i = 0; i < OHM_THAW_TABLE_CAPACITY; i++) {
        if (atomic_load(&ohm_slots[i]) > 0) n++;
    }
    return n;
}

// Async-signal-safe: only atomic loads and kill(2).
int ohm_thaw_table_thaw_all(void) {
    int n = 0;
    for (int i = 0; i < OHM_THAW_TABLE_CAPACITY; i++) {
        int32_t pid = atomic_load(&ohm_slots[i]);
        if (pid > 0) {
            kill((pid_t)pid, SIGCONT);
            n++;
        }
    }
    return n;
}

static void ohm_handler(int sig, siginfo_t *info, void *ctx) {
    int saved_errno = errno;
    ohm_thaw_table_thaw_all();

    // Chain whatever was installed before us (crash reporters, runtime backtracers).
    if (sig > 0 && sig < NSIG) {
        struct sigaction *p = &ohm_prev[sig];
        if (p->sa_flags & SA_SIGINFO) {
            if (p->sa_sigaction != NULL) p->sa_sigaction(sig, info, ctx);
        } else if (p->sa_handler != SIG_DFL && p->sa_handler != SIG_IGN && p->sa_handler != NULL) {
            p->sa_handler(sig);
        }
    }

    // Re-raise with the default action. The signal is blocked while we run, so it is delivered
    // (and terminates the process) as soon as the handler returns.
    struct sigaction dfl;
    memset(&dfl, 0, sizeof dfl);
    dfl.sa_handler = SIG_DFL;
    sigemptyset(&dfl.sa_mask);
    sigaction(sig, &dfl, NULL);
    raise(sig);
    errno = saved_errno;
}

int ohm_thaw_table_install_handlers(void) {
    int expected = 0;
    if (!atomic_compare_exchange_strong(&ohm_installed, &expected, 1)) return 0;

    // Alternate stack for the installing thread so a stack-overflow SIGSEGV can still thaw.
    static char altstack[65536];
    stack_t ss;
    ss.ss_sp = altstack;
    ss.ss_size = sizeof altstack;
    ss.ss_flags = 0;
    sigaltstack(&ss, NULL);

    int rc = 0;
    for (size_t i = 0; i < sizeof ohm_signals / sizeof ohm_signals[0]; i++) {
        int sig = ohm_signals[i];
        struct sigaction sa;
        memset(&sa, 0, sizeof sa);
        sa.sa_sigaction = ohm_handler;
        sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
        sigemptyset(&sa.sa_mask);
        if (sigaction(sig, &sa, &ohm_prev[sig]) != 0) rc = -1;
    }
    return rc;
}

typedef pid_t (*ohm_responsible_fn)(pid_t);

pid_t ohm_gov_responsible_pid(pid_t pid) {
    static _Atomic(ohm_responsible_fn) fn = NULL;
    static _Atomic int looked_up = 0;
    if (!atomic_load(&looked_up)) {
        ohm_responsible_fn f = (ohm_responsible_fn)dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
        atomic_store(&fn, f);
        atomic_store(&looked_up, 1);
    }
    ohm_responsible_fn f = atomic_load(&fn);
    if (f == NULL) return -1;
    pid_t r = f(pid);
    return r > 0 ? r : -1;
}

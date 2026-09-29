#ifndef OHM_THAW_TABLE_H
#define OHM_THAW_TABLE_H

#include <stdint.h>
#include <sys/types.h>

// ADR 0004 § 7: async-signal-safe table of (pid, ri_proc_start_abstime) pairs Ohm has SIGSTOPped.
// On fatal/termination signals a C sigaction handler re-verifies each identity with
// proc_pid_rusage (a direct __proc_info syscall wrapper, see ADR 0004 "T-023 sonuçları") and sends
// SIGCONT only to matching processes (D3), then restores the default action and re-raises.
// It does not chain to previously installed handlers (their async-signal-safety is unknown).

#define OHM_THAW_TABLE_CAPACITY 256

/// Adds (pid, start) (idempotent per pid). Returns 0 on success, -1 if the table is full,
/// pid <= 1 or start == 0.
int ohm_thaw_table_add(pid_t pid, uint64_t start_abstime);
/// Removes pid if present. Returns 1 if removed, 0 if absent.
int ohm_thaw_table_remove(pid_t pid);
int ohm_thaw_table_contains(pid_t pid);
int ohm_thaw_table_count(void);
/// The handler's action: SIGCONT to every entry whose identity still matches.
/// Returns the number of SIGCONTs sent.
int ohm_thaw_table_thaw_verified(void);
/// Installs the handler for SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP,
/// SIGABRT and SIGFPE. Idempotent. Returns 0 on success, -1 if any sigaction() failed.
int ohm_thaw_table_install_handlers(void);

/// responsibility_get_pid_responsible_for_pid via dlsym (SPI, ADR 0001: private API stays in COhmSys).
/// Returns -1 when the symbol is unavailable or the call fails.
pid_t ohm_gov_responsible_pid(pid_t pid);

#endif /* OHM_THAW_TABLE_H */

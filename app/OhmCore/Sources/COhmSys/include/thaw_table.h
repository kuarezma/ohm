#ifndef OHM_THAW_TABLE_H
#define OHM_THAW_TABLE_H

#include <sys/types.h>

// ADR 0004 § 7: async-signal-safe table of pids Ohm has SIGSTOPped. A C sigaction handler sends
// SIGCONT to every entry on fatal/termination signals, chains the previous handler and then
// re-raises the signal with its default action. Swift never runs inside the handler.

#define OHM_THAW_TABLE_CAPACITY 256

/// Adds pid (idempotent). Returns 0 on success, -1 if the table is full or pid <= 1.
int ohm_thaw_table_add(pid_t pid);
/// Removes pid if present. Returns 1 if removed, 0 if absent.
int ohm_thaw_table_remove(pid_t pid);
int ohm_thaw_table_contains(pid_t pid);
int ohm_thaw_table_count(void);
/// Sends SIGCONT to every entry (the handler's action). Returns the number of kill() calls.
int ohm_thaw_table_thaw_all(void);
/// Installs the handler for SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP,
/// SIGABRT and SIGFPE. Idempotent. Returns 0 on success, -1 if any sigaction() failed.
int ohm_thaw_table_install_handlers(void);

/// responsibility_get_pid_responsible_for_pid via dlsym (SPI, ADR 0001: private API stays in COhmSys).
/// Returns -1 when the symbol is unavailable or the call fails.
pid_t ohm_gov_responsible_pid(pid_t pid);

#endif /* OHM_THAW_TABLE_H */

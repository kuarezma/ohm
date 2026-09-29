#ifndef COHMSYS_H
#define COHMSYS_H

#include <stdint.h>
#include <sys/types.h>

// Thin C layer for private and awkward-to-bridge system APIs (ADR 0001 § 1).
// Private symbols (IOReport, responsibility SPI) are resolved at run time with dlopen/dlsym,
// never hard-linked, so a future macOS that drops them only disables the feature.

// MARK: proc_pid_rusage(RUSAGE_INFO_V6)

typedef struct {
    uint64_t energy_nj;      // ri_energy_nj
    uint64_t penergy_nj;     // ri_penergy_nj (P-cluster share)
    uint64_t cpu_time_abs;   // ri_user_time + ri_system_time, mach absolute time units
    uint64_t start_abstime;  // ri_proc_start_abstime
} ohm_proc_counters;

/// 0 on success, otherwise errno (EPERM for root/other users, ESRCH when gone).
int ohm_proc_read(pid_t pid, ohm_proc_counters *out);

// MARK: responsibility SPI (libquarantine)

/// 1 if responsibility_get_pid_responsible_for_pid was found.
int ohm_responsibility_available(void);
/// Responsible pid, or -1 when the SPI is unavailable or fails.
pid_t ohm_responsible_pid(pid_t pid);

// MARK: IOReport ("Energy Model" + "CPU Stats / CPU Core Performance States")

typedef struct ohm_ior ohm_ior;

enum {
    OHM_IOR_OK = 0,
    OHM_IOR_ERR_DLOPEN = 1,        // libIOReport not loadable
    OHM_IOR_ERR_SYMBOL = 2,        // a required symbol is missing
    OHM_IOR_ERR_NO_CHANNELS = 3,   // "Energy Model" group missing
    OHM_IOR_ERR_SUBSCRIBE = 4,     // IOReportCreateSubscription failed
};

typedef struct {
    char group[32];
    char name[48];
    char unit[8];      // unit label, e.g. "mJ", "nJ"; empty for state channels
    int32_t is_state;  // 1: residency fields valid; 0: value valid
    int64_t value;     // simple channel delta, in `unit`
    int64_t active;    // state channel: residency outside IDLE/OFF/DOWN
    int64_t total;     // state channel: total residency
} ohm_ior_channel;

/// Opens a subscription and takes the first (baseline) sample. NULL on failure; `err` gets the stage.
ohm_ior *ohm_ior_open(int *err);
void ohm_ior_close(ohm_ior *h);
/// Takes a sample and writes the delta against the previous one. Returns the number of channels
/// written (at most `cap`) or -1; `dt_abs` gets the mach-absolute interval between the samples.
int ohm_ior_sample(ohm_ior *h, ohm_ior_channel *out, int cap, uint64_t *dt_abs);

#endif /* COHMSYS_H */

// T-012 spike: does setpriority(PRIO_DARWIN_PROCESS, pid, PRIO_DARWIN_BG) move a process
// from the P-cluster to the E-cluster?
// Spawns N `yes` children itself (policy is only ever applied to these), measures 5 s per phase:
//   A baseline -> B PRIO_DARWIN_BG via setpriority -> C policy removed (value 0)
//   -> D `taskpolicy -b -p` (comparison) -> E `taskpolicy -B -p` (removed)
// Metrics: P-energy share (ri_penergy_nj / ri_energy_nj), process watts and CPU%,
// IOReport "CPU Stats" P/E cluster active residency. Kills every child on exit.
#include <CoreFoundation/CoreFoundation.h>
#include <libproc.h>
#include <mach/mach_time.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <unistd.h>

extern char **environ;

typedef struct IOReportSubscription *IOReportSubscriptionRef;
extern CFDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
extern IOReportSubscriptionRef IOReportCreateSubscription(void *, CFMutableDictionaryRef,
                                                          CFMutableDictionaryRef *, uint64_t, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
extern CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
extern int32_t IOReportStateGetCount(CFDictionaryRef);
extern CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef, int32_t);
extern int64_t IOReportStateGetResidency(CFDictionaryRef, int32_t);

#define MAXN 16
static pid_t kids[MAXN];
static int nkids;

static void kill_kids(void) {
    for (int i = 0; i < nkids; i++) if (kids[i] > 0) { kill(kids[i], SIGKILL); waitpid(kids[i], NULL, 0); }
    nkids = 0;
}
static void on_sig(int s) { (void)s; kill_kids(); _exit(1); }

static void cstr(CFStringRef s, char *b, size_t n) { b[0] = 0; if (s) CFStringGetCString(s, b, (CFIndex)n, kCFStringEncodingUTF8); }

static IOReportSubscriptionRef sub;
static CFMutableDictionaryRef subbed;

// Average active residency (%) of P and E cores over the delta.
static void cluster_act(CFDictionaryRef delta, double *p, double *e) {
    double pa = 0, pt = 0, ea = 0, et = 0;
    CFArrayRef arr = CFDictionaryGetValue(delta, CFSTR("IOReportChannels"));
    for (CFIndex i = 0; arr && i < CFArrayGetCount(arr); i++) {
        CFDictionaryRef ch = CFArrayGetValueAtIndex(arr, i);
        char name[64];
        cstr(IOReportChannelGetChannelName(ch), name, sizeof name);
        int isP = !strncmp(name, "PCPU", 4), isE = !strncmp(name, "ECPU", 4);
        if (!isP && !isE) continue;
        for (int32_t k = 0; k < IOReportStateGetCount(ch); k++) {
            char s[32];
            cstr(IOReportStateGetNameForIndex(ch, k), s, sizeof s);
            double r = (double)IOReportStateGetResidency(ch, k);
            int act = strcmp(s, "IDLE") && strcmp(s, "OFF") && strcmp(s, "DOWN");
            if (isP) { pt += r; if (act) pa += r; } else { et += r; if (act) ea += r; }
        }
    }
    *p = pt > 0 ? 100 * pa / pt : 0;
    *e = et > 0 ? 100 * ea / et : 0;
}

typedef struct { uint64_t e, pe, cpu; } ru_t;
static void read_ru(ru_t *out) {
    for (int i = 0; i < nkids; i++) {
        struct rusage_info_v6 ri;
        memset(&out[i], 0, sizeof out[i]);
        if (proc_pid_rusage(kids[i], RUSAGE_INFO_V6, (rusage_info_t *)&ri) == 0) {
            out[i].e = ri.ri_energy_nj;
            out[i].pe = ri.ri_penergy_nj;
            out[i].cpu = ri.ri_user_time + ri.ri_system_time;
        }
    }
}

static mach_timebase_info_data_t tb;
static double abs_s(uint64_t d) { return (double)d * tb.numer / tb.denom / 1e9; }

static void measure(const char *label, double secs) {
    ru_t a[MAXN], b[MAXN];
    read_ru(a);
    CFDictionaryRef s0 = IOReportCreateSamples(sub, subbed, NULL);
    uint64_t t0 = mach_absolute_time();
    usleep((useconds_t)(secs * 1e6));
    read_ru(b);
    CFDictionaryRef s1 = IOReportCreateSamples(sub, subbed, NULL);
    double dt = abs_s(mach_absolute_time() - t0);
    CFDictionaryRef d = IOReportCreateSamplesDelta(s0, s1, NULL);
    double pact, eact;
    cluster_act(d, &pact, &eact);
    CFRelease(d); CFRelease(s0); CFRelease(s1);
    double ej = 0, pej = 0, cpu = 0;
    for (int i = 0; i < nkids; i++) {
        ej += (double)(b[i].e - a[i].e) / 1e9;
        pej += (double)(b[i].pe - a[i].pe) / 1e9;
        cpu += abs_s(b[i].cpu - a[i].cpu);
    }
    int prio = getpriority(PRIO_DARWIN_PROCESS, kids[0]);
    printf("%-22s %6.2f %7.3f %7.3f %8.1f | %6.1f %6.1f | %4d\n", label, ej > 0 ? pej / ej : 0,
           ej / dt, pej / dt, 100 * cpu / dt, pact, eact, prio);
    fflush(stdout);
}

static void set_bg(int on) {
    for (int i = 0; i < nkids; i++)
        if (setpriority(PRIO_DARWIN_PROCESS, kids[i], on ? PRIO_DARWIN_BG : 0) != 0) perror("setpriority");
}

static void taskpolicy(const char *flag) {
    for (int i = 0; i < nkids; i++) {
        char cmd[96];
        snprintf(cmd, sizeof cmd, "/usr/sbin/taskpolicy %s -p %d", flag, kids[i]);
        if (system(cmd) != 0) fprintf(stderr, "failed: %s\n", cmd);
    }
}

int main(int argc, char **argv) {
    int n = argc > 1 ? atoi(argv[1]) : 4;
    double secs = argc > 2 ? atof(argv[2]) : 5;
    if (n < 1 || n > MAXN) return 2;
    mach_timebase_info(&tb);
    signal(SIGINT, on_sig); signal(SIGTERM, on_sig);
    atexit(kill_kids);

    CFDictionaryRef cs = IOReportCopyChannelsInGroup(CFSTR("CPU Stats"), CFSTR("CPU Core Performance States"), 0, 0, 0);
    if (!cs) { fprintf(stderr, "no CPU Stats channels\n"); return 1; }
    CFMutableDictionaryRef desired = CFDictionaryCreateMutableCopy(NULL, 0, cs);
    sub = IOReportCreateSubscription(NULL, desired, &subbed, 0, NULL);

    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0);
    char *args[] = {"yes", NULL};
    for (int i = 0; i < n; i++) {
        if (posix_spawnp(&kids[i], "yes", &fa, NULL, args, environ) != 0) { perror("spawn"); return 1; }
        nkids++;
    }
    printf("spawned %d x yes:", nkids);
    for (int i = 0; i < nkids; i++) printf(" %d", kids[i]);
    printf("\n");
    usleep(500000);

    printf("%-22s %6s %7s %7s %8s | %6s %6s | %4s\n", "phase", "P_shr", "proc_W", "procP_W",
           "cpu%", "P_act%", "E_act%", "prio");
    measure("A baseline", secs);
    set_bg(1);
    measure("B setpriority BG", secs);
    set_bg(0);
    measure("C BG removed (0)", secs);
    taskpolicy("-b");
    measure("D taskpolicy -b", secs);
    taskpolicy("-B");
    measure("E taskpolicy -B", secs);

    kill_kids();
    printf("killed all children\n");
    return 0;
}

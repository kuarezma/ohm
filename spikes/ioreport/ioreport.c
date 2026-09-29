// T-010 spike: sudo-less power via libIOReport plus AppleSmartBattery as system reference.
//
// Usage: ioreport list          dump "Energy Model" channels with unit labels (one 1 s delta)
//        ioreport [secs=10]     one line per second
//        ioreport burst [secs]  print only when the coarse CPU/DRAM counters publish a burst,
//                               averaging each burst over the time since the previous one
//
// libIOReport ships no header; prototypes mirror the symbols exported by the SDK's
// libIOReport.tbd with the signatures macmon (github.com/vladkens/macmon) uses.
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct IOReportSubscription *IOReportSubscriptionRef;
extern CFDictionaryRef IOReportCopyChannelsInGroup(CFStringRef group, CFStringRef subgroup,
                                                   uint64_t a, uint64_t b, uint64_t c);
extern void IOReportMergeChannels(CFDictionaryRef a, CFDictionaryRef b, CFTypeRef unused);
extern IOReportSubscriptionRef IOReportCreateSubscription(void *a, CFMutableDictionaryRef desired,
                                                          CFMutableDictionaryRef *subbed,
                                                          uint64_t channel_id, CFTypeRef b);
extern CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef s, CFMutableDictionaryRef ch,
                                             CFTypeRef a);
extern CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef prev, CFDictionaryRef cur,
                                                  CFTypeRef a);
extern CFStringRef IOReportChannelGetGroup(CFDictionaryRef ch);
extern CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef ch);
extern CFStringRef IOReportChannelGetChannelName(CFDictionaryRef ch);
extern CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef ch);
extern int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef ch, int32_t idx);
extern int32_t IOReportStateGetCount(CFDictionaryRef ch);
extern CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef ch, int32_t idx);
extern int64_t IOReportStateGetResidency(CFDictionaryRef ch, int32_t idx);

static void cstr(CFStringRef s, char *buf, size_t n) {
    buf[0] = 0;
    if (s) CFStringGetCString(s, buf, (CFIndex)n, kCFStringEncodingUTF8);
}

static double unit_to_joule(const char *u) {
    if (!strcmp(u, "mJ")) return 1e-3;
    if (!strcmp(u, "uJ")) return 1e-6;
    if (!strcmp(u, "nJ")) return 1e-9;
    return -1; // unknown unit: caller skips the channel
}

// "Energy Model" channel names as enumerated on M3 / macOS 27 with `list`.
enum { C_CPU_P, C_CPU_E, C_GPU, C_ANE, C_DRAM, C_CPU_TOTAL, C_N };
static int classify(const char *n) {
    if (!strcmp(n, "PCPU")) return C_CPU_P; // P-cluster total (cores + PCPM + SRAM)
    if (!strcmp(n, "ECPU")) return C_CPU_E; // E-cluster total
    if (!strcmp(n, "CPU Energy")) return C_CPU_TOTAL;
    if (!strcmp(n, "GPU Energy")) return C_GPU; // nJ, the only per-second energy channel
    if (!strcmp(n, "ANE")) return C_ANE;
    if (!strcmp(n, "DRAM")) return C_DRAM;
    return -1;
}

// System power reference. sysload: PowerTelemetryData.SystemLoad (mW), valid on battery and AC.
// vxa: Voltage x Amperage, which equals system power only while discharging.
static int battery_power(double *sysload_w, double *vxa_w) {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault,
                                                   IOServiceMatching("AppleSmartBattery"));
    if (!svc) return 0;
    CFNumberRef v = IORegistryEntryCreateCFProperty(svc, CFSTR("Voltage"), NULL, 0);
    CFNumberRef a = IORegistryEntryCreateCFProperty(svc, CFSTR("Amperage"), NULL, 0);
    CFDictionaryRef tel = IORegistryEntryCreateCFProperty(svc, CFSTR("PowerTelemetryData"), NULL, 0);
    int64_t mv = 0, ma = 0, load = -1;
    if (v) CFNumberGetValue(v, kCFNumberSInt64Type, &mv);
    if (a) CFNumberGetValue(a, kCFNumberSInt64Type, &ma); // negative while discharging
    if (tel) {
        CFNumberRef l = CFDictionaryGetValue(tel, CFSTR("SystemLoad"));
        if (l) CFNumberGetValue(l, kCFNumberSInt64Type, &load);
    }
    *vxa_w = -(double)mv * (double)ma / 1e6;
    *sysload_w = load >= 0 ? (double)load / 1e3 : -1;
    if (v) CFRelease(v);
    if (a) CFRelease(a);
    if (tel) CFRelease(tel);
    IOObjectRelease(svc);
    return 1;
}

// Active residency of a CPU core performance-state channel: everything except idle/off states.
static void residency(CFDictionaryRef ch, double *active, double *total) {
    int32_t n = IOReportStateGetCount(ch);
    for (int32_t i = 0; i < n; i++) {
        char s[32];
        cstr(IOReportStateGetNameForIndex(ch, i), s, sizeof s);
        double r = (double)IOReportStateGetResidency(ch, i);
        *total += r;
        if (strcmp(s, "IDLE") && strcmp(s, "OFF") && strcmp(s, "DOWN")) *active += r;
    }
}

int main(int argc, char **argv) {
    int list = argc > 1 && !strcmp(argv[1], "list");
    int burst = argc > 1 && !strcmp(argv[1], "burst");
    int seconds = burst ? (argc > 2 ? atoi(argv[2]) : 300) : (!list && argc > 1 ? atoi(argv[1]) : 10);

    CFDictionaryRef em = IOReportCopyChannelsInGroup(CFSTR("Energy Model"), NULL, 0, 0, 0);
    CFDictionaryRef cs = IOReportCopyChannelsInGroup(CFSTR("CPU Stats"),
                                                     CFSTR("CPU Core Performance States"), 0, 0, 0);
    if (!em) { fprintf(stderr, "IOReportCopyChannelsInGroup(Energy Model) returned NULL\n"); return 1; }
    if (cs) IOReportMergeChannels(em, cs, NULL);
    CFMutableDictionaryRef desired = CFDictionaryCreateMutableCopy(NULL, 0, em);
    CFMutableDictionaryRef subbed = NULL;
    IOReportSubscriptionRef sub = IOReportCreateSubscription(NULL, desired, &subbed, 0, NULL);
    if (!sub || !subbed) { fprintf(stderr, "IOReportCreateSubscription failed\n"); return 1; }

    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    CFDictionaryRef prev = IOReportCreateSamples(sub, subbed, NULL);
    uint64_t tprev = mach_absolute_time(), tlast_burst = 0;
    double load_acc = 0; int load_n = 0; // sysload average since the last burst

    if (burst)
        printf("%5s %7s %8s %8s %8s %8s %8s | %10s\n", "t", "win_s", "cpu_p_W", "cpu_e_W", "ane_W",
               "dram_W", "gpu_W", "sysload_W");
    else if (!list)
        printf("%3s %7s %7s %7s %7s %7s | %6s %6s | %9s %8s\n", "t", "cpu_p_W", "cpu_e_W", "gpu_W",
               "ane_W", "dram_W", "P_act%", "E_act%", "sysload_W", "batt_VxA");

    double gpu_acc = 0; // GPU Energy accumulated since the last burst (J)
    for (int t = 1; t <= (list ? 1 : seconds); t++) {
        sleep(1);
        CFDictionaryRef cur = IOReportCreateSamples(sub, subbed, NULL);
        uint64_t tcur = mach_absolute_time();
        double dt = (double)(tcur - tprev) * tb.numer / tb.denom / 1e9;
        CFDictionaryRef delta = IOReportCreateSamplesDelta(prev, cur, NULL);
        CFRelease(prev);
        prev = cur;
        tprev = tcur;
        CFArrayRef arr = CFDictionaryGetValue(delta, CFSTR("IOReportChannels"));
        double joule[C_N] = {0}, pa = 0, pt = 0, ea = 0, et = 0;
        for (CFIndex i = 0; arr && i < CFArrayGetCount(arr); i++) {
            CFDictionaryRef ch = CFArrayGetValueAtIndex(arr, i);
            char name[128], unit[16], grp[64];
            cstr(IOReportChannelGetChannelName(ch), name, sizeof name);
            cstr(IOReportChannelGetGroup(ch), grp, sizeof grp);
            if (!strcmp(grp, "CPU Stats")) {
                if (!strncmp(name, "PCPU", 4)) residency(ch, &pa, &pt);
                else if (!strncmp(name, "ECPU", 4)) residency(ch, &ea, &et);
                continue;
            }
            cstr(IOReportChannelGetUnitLabel(ch), unit, sizeof unit);
            int64_t v = IOReportSimpleGetIntegerValue(ch, 0);
            if (list) { printf("%-28s unit=%-3s delta=%lld\n", name, unit, (long long)v); continue; }
            double k = unit_to_joule(unit);
            int c = classify(name);
            if (k > 0 && c >= 0) joule[c] += (double)v * k;
        }
        CFRelease(delta);
        if (list) break;
        double sysload = -1, vxa = 0;
        battery_power(&sysload, &vxa);
        if (!burst) {
            printf("%3d %7.3f %7.3f %7.3f %7.3f %7.3f | %6.1f %6.1f | %9.3f %8.3f\n", t,
                   joule[C_CPU_P] / dt, joule[C_CPU_E] / dt, joule[C_GPU] / dt, joule[C_ANE] / dt,
                   joule[C_DRAM] / dt, pt > 0 ? 100 * pa / pt : 0, et > 0 ? 100 * ea / et : 0,
                   sysload, vxa);
        } else {
            gpu_acc += joule[C_GPU];
            if (sysload >= 0) { load_acc += sysload; load_n++; }
            if (joule[C_CPU_TOTAL] > 0) {
                if (tlast_burst) {
                    double win = (double)(tcur - tlast_burst) * tb.numer / tb.denom / 1e9;
                    printf("%5d %7.1f %8.3f %8.3f %8.3f %8.3f %8.3f | %10.3f\n", t, win,
                           joule[C_CPU_P] / win, joule[C_CPU_E] / win, joule[C_ANE] / win,
                           joule[C_DRAM] / win, gpu_acc / win, load_n ? load_acc / load_n : -1);
                } else {
                    printf("%5d first burst seen (window unknown, discarded)\n", t);
                }
                tlast_burst = tcur;
                gpu_acc = 0; load_acc = 0; load_n = 0;
            }
        }
        fflush(stdout);
    }
    CFRelease(prev);
    return 0;
}

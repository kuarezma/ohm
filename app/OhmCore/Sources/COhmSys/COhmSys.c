#include "COhmSys.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <errno.h>
#include <libproc.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>

// MARK: proc_pid_rusage

int ohm_proc_read(pid_t pid, ohm_proc_counters *out) {
    struct rusage_info_v6 ri;
    if (proc_pid_rusage(pid, RUSAGE_INFO_V6, (rusage_info_t *)&ri) != 0) return errno ? errno : ESRCH;
    out->energy_nj = ri.ri_energy_nj;
    out->penergy_nj = ri.ri_penergy_nj;
    out->cpu_time_abs = ri.ri_user_time + ri.ri_system_time;
    out->start_abstime = ri.ri_proc_start_abstime;
    return 0;
}

// MARK: responsibility SPI

typedef pid_t (*responsible_fn)(pid_t);
static responsible_fn g_responsible;
static pthread_once_t g_responsible_once = PTHREAD_ONCE_INIT;

static void load_responsible(void) {
    // Exported by libquarantine, which libSystem re-exports; the explicit dlopen is a fallback.
    void *sym = dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
    if (!sym) {
        void *lib = dlopen("/usr/lib/system/libquarantine.dylib", RTLD_LAZY | RTLD_LOCAL);
        if (lib) sym = dlsym(lib, "responsibility_get_pid_responsible_for_pid");
    }
    g_responsible = (responsible_fn)sym;
}

int ohm_responsibility_available(void) {
    pthread_once(&g_responsible_once, load_responsible);
    return g_responsible != NULL;
}

pid_t ohm_responsible_pid(pid_t pid) {
    if (!ohm_responsibility_available()) return -1;
    pid_t r = g_responsible(pid);
    return r > 0 ? r : -1;
}

// MARK: IOReport
//
// libIOReport ships no header. Prototypes mirror the symbols in the SDK's libIOReport.tbd with the
// signatures validated by spikes/ioreport (T-010). The library is not a file on disk: dlopen
// resolves the path from the dyld shared cache.

typedef struct IOReportSubscription *IOReportSubscriptionRef;
typedef CFDictionaryRef (*CopyChannelsInGroup_fn)(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
typedef void (*MergeChannels_fn)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
typedef IOReportSubscriptionRef (*CreateSubscription_fn)(void *, CFMutableDictionaryRef,
                                                        CFMutableDictionaryRef *, uint64_t, CFTypeRef);
typedef CFDictionaryRef (*CreateSamples_fn)(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
typedef CFDictionaryRef (*CreateSamplesDelta_fn)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
typedef CFStringRef (*ChannelGetString_fn)(CFDictionaryRef);
typedef int64_t (*SimpleGetIntegerValue_fn)(CFDictionaryRef, int32_t);
typedef int32_t (*StateGetCount_fn)(CFDictionaryRef);
typedef CFStringRef (*StateGetNameForIndex_fn)(CFDictionaryRef, int32_t);
typedef int64_t (*StateGetResidency_fn)(CFDictionaryRef, int32_t);

static struct {
    CopyChannelsInGroup_fn CopyChannelsInGroup;
    MergeChannels_fn MergeChannels;
    CreateSubscription_fn CreateSubscription;
    CreateSamples_fn CreateSamples;
    CreateSamplesDelta_fn CreateSamplesDelta;
    ChannelGetString_fn ChannelGetGroup;
    ChannelGetString_fn ChannelGetChannelName;
    ChannelGetString_fn ChannelGetUnitLabel;
    SimpleGetIntegerValue_fn SimpleGetIntegerValue;
    StateGetCount_fn StateGetCount;
    StateGetNameForIndex_fn StateGetNameForIndex;
    StateGetResidency_fn StateGetResidency;
} ior;
static int g_ior_status = -1;
static pthread_once_t g_ior_once = PTHREAD_ONCE_INIT;

static void load_ioreport(void) {
    void *lib = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY | RTLD_LOCAL);
    if (!lib) { g_ior_status = OHM_IOR_ERR_DLOPEN; return; }
#define LOAD(field, sym)                                                  \
    if (!(*(void **)&ior.field = dlsym(lib, sym))) {                      \
        g_ior_status = OHM_IOR_ERR_SYMBOL;                                \
        return;                                                           \
    }
    LOAD(CopyChannelsInGroup, "IOReportCopyChannelsInGroup")
    LOAD(MergeChannels, "IOReportMergeChannels")
    LOAD(CreateSubscription, "IOReportCreateSubscription")
    LOAD(CreateSamples, "IOReportCreateSamples")
    LOAD(CreateSamplesDelta, "IOReportCreateSamplesDelta")
    LOAD(ChannelGetGroup, "IOReportChannelGetGroup")
    LOAD(ChannelGetChannelName, "IOReportChannelGetChannelName")
    LOAD(ChannelGetUnitLabel, "IOReportChannelGetUnitLabel")
    LOAD(SimpleGetIntegerValue, "IOReportSimpleGetIntegerValue")
    LOAD(StateGetCount, "IOReportStateGetCount")
    LOAD(StateGetNameForIndex, "IOReportStateGetNameForIndex")
    LOAD(StateGetResidency, "IOReportStateGetResidency")
#undef LOAD
    g_ior_status = OHM_IOR_OK;
}

struct ohm_ior {
    IOReportSubscriptionRef sub;
    CFMutableDictionaryRef subbed;
    CFDictionaryRef prev;
    uint64_t prev_abs;
};

static void cstr(CFStringRef s, char *buf, size_t n) {
    if (!s || !CFStringGetCString(s, buf, (CFIndex)n, kCFStringEncodingUTF8)) buf[0] = 0;
}

ohm_ior *ohm_ior_open(int *err) {
    pthread_once(&g_ior_once, load_ioreport);
    if (g_ior_status != OHM_IOR_OK) { if (err) *err = g_ior_status; return NULL; }

    CFDictionaryRef em = ior.CopyChannelsInGroup(CFSTR("Energy Model"), NULL, 0, 0, 0);
    if (!em) { if (err) *err = OHM_IOR_ERR_NO_CHANNELS; return NULL; }
    CFDictionaryRef cs = ior.CopyChannelsInGroup(CFSTR("CPU Stats"),
                                                 CFSTR("CPU Core Performance States"), 0, 0, 0);
    if (cs) {
        ior.MergeChannels(em, cs, NULL);
        CFRelease(cs);
    }
    CFMutableDictionaryRef desired = CFDictionaryCreateMutableCopy(NULL, 0, em);
    CFRelease(em);
    CFMutableDictionaryRef subbed = NULL;
    IOReportSubscriptionRef sub = ior.CreateSubscription(NULL, desired, &subbed, 0, NULL);
    CFRelease(desired);
    if (!sub || !subbed) {
        if (subbed) CFRelease(subbed);
        if (sub) CFRelease((CFTypeRef)sub);
        if (err) *err = OHM_IOR_ERR_SUBSCRIBE;
        return NULL;
    }
    ohm_ior *h = calloc(1, sizeof *h);
    if (!h) { CFRelease(subbed); CFRelease((CFTypeRef)sub); if (err) *err = OHM_IOR_ERR_SUBSCRIBE; return NULL; }
    h->sub = sub;
    h->subbed = subbed;
    h->prev = ior.CreateSamples(sub, subbed, NULL);
    h->prev_abs = mach_absolute_time();
    if (err) *err = OHM_IOR_OK;
    return h;
}

void ohm_ior_close(ohm_ior *h) {
    if (!h) return;
    if (h->prev) CFRelease(h->prev);
    if (h->subbed) CFRelease(h->subbed);
    if (h->sub) CFRelease((CFTypeRef)h->sub);
    free(h);
}

// Idle states of a CPU core performance-state channel (T-010/T-012): everything else is active.
static int is_idle_state(const char *s) {
    return !strcmp(s, "IDLE") || !strcmp(s, "OFF") || !strcmp(s, "DOWN");
}

int ohm_ior_sample(ohm_ior *h, ohm_ior_channel *out, int cap, uint64_t *dt_abs) {
    if (!h) return -1;
    CFDictionaryRef cur = ior.CreateSamples(h->sub, h->subbed, NULL);
    uint64_t now = mach_absolute_time();
    if (!cur) return -1;
    if (!h->prev) {  // first sample failed at open: this one becomes the baseline
        h->prev = cur;
        h->prev_abs = now;
        if (dt_abs) *dt_abs = 0;
        return 0;
    }
    CFDictionaryRef delta = ior.CreateSamplesDelta(h->prev, cur, NULL);
    CFRelease(h->prev);
    h->prev = cur;
    if (dt_abs) *dt_abs = now - h->prev_abs;
    h->prev_abs = now;
    if (!delta) return -1;

    int n = 0;
    CFArrayRef arr = CFDictionaryGetValue(delta, CFSTR("IOReportChannels"));
    CFIndex count = arr ? CFArrayGetCount(arr) : 0;
    for (CFIndex i = 0; i < count && n < cap; i++) {
        CFDictionaryRef ch = CFArrayGetValueAtIndex(arr, i);
        ohm_ior_channel *c = &out[n];
        memset(c, 0, sizeof *c);
        cstr(ior.ChannelGetGroup(ch), c->group, sizeof c->group);
        cstr(ior.ChannelGetChannelName(ch), c->name, sizeof c->name);
        if (!strcmp(c->group, "CPU Stats")) {
            c->is_state = 1;
            int32_t states = ior.StateGetCount(ch);
            for (int32_t k = 0; k < states; k++) {
                char s[32];
                cstr(ior.StateGetNameForIndex(ch, k), s, sizeof s);
                int64_t r = ior.StateGetResidency(ch, k);
                c->total += r;
                if (!is_idle_state(s)) c->active += r;
            }
        } else {
            cstr(ior.ChannelGetUnitLabel(ch), c->unit, sizeof c->unit);
            c->value = ior.SimpleGetIntegerValue(ch, 0);
        }
        n++;
    }
    CFRelease(delta);
    return n;
}

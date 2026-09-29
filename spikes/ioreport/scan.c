// T-010 diagnostic: subscribe to every IOReport channel, take N one-second deltas and
// print energy-unit channels (label ends in "J") whose delta was non-zero, per group.
// Usage: scan [seconds=3]
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct IOReportSubscription *IOReportSubscriptionRef;
extern CFDictionaryRef IOReportCopyAllChannels(uint64_t a, uint64_t b);
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
extern int32_t IOReportChannelGetFormat(CFDictionaryRef ch);
extern int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef ch, int32_t idx);

static void cstr(CFStringRef s, char *buf, size_t n) {
    buf[0] = 0;
    if (s) CFStringGetCString(s, buf, (CFIndex)n, kCFStringEncodingUTF8);
}

int main(int argc, char **argv) {
    int secs = argc > 1 ? atoi(argv[1]) : 3;
    CFDictionaryRef all = IOReportCopyAllChannels(0, 0);
    if (!all) { fprintf(stderr, "IOReportCopyAllChannels returned NULL\n"); return 1; }
    CFMutableDictionaryRef desired = CFDictionaryCreateMutableCopy(NULL, 0, all);
    CFMutableDictionaryRef subbed = NULL;
    IOReportSubscriptionRef sub = IOReportCreateSubscription(NULL, desired, &subbed, 0, NULL);
    if (!sub) { fprintf(stderr, "subscription failed\n"); return 1; }
    CFDictionaryRef prev = IOReportCreateSamples(sub, subbed, NULL);
    for (int t = 1; t <= secs; t++) {
        sleep(1);
        CFDictionaryRef cur = IOReportCreateSamples(sub, subbed, NULL);
        CFDictionaryRef d = IOReportCreateSamplesDelta(prev, cur, NULL);
        CFRelease(prev);
        prev = cur;
        CFArrayRef arr = CFDictionaryGetValue(d, CFSTR("IOReportChannels"));
        CFIndex n = arr ? CFArrayGetCount(arr) : 0, shown = 0;
        for (CFIndex i = 0; i < n; i++) {
            CFDictionaryRef ch = CFArrayGetValueAtIndex(arr, i);
            char g[96], sg[96], name[128], unit[16];
            cstr(IOReportChannelGetUnitLabel(ch), unit, sizeof unit);
            size_t ul = strlen(unit);
            if (ul == 0 || unit[ul - 1] != 'J' || IOReportChannelGetFormat(ch) != 1) continue;
            int64_t v = IOReportSimpleGetIntegerValue(ch, 0);
            if (v == 0) continue;
            cstr(IOReportChannelGetGroup(ch), g, sizeof g);
            cstr(IOReportChannelGetSubGroup(ch), sg, sizeof sg);
            cstr(IOReportChannelGetChannelName(ch), name, sizeof name);
            printf("t=%d [%s|%s] %s = %lld %s\n", t, g, sg, name, (long long)v, unit);
            shown++;
        }
        printf("t=%d channels=%ld nonzero_energy=%ld\n", t, (long)n, (long)shown);
        CFRelease(d);
    }
    return 0;
}

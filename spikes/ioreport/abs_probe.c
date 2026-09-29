// T-010 diagnostic: print ABSOLUTE (not delta) Energy Model counters once per second for 25 s.
// Shows whether "CPU Energy"/"DRAM" are frozen between publishes while "GPU Energy" advances.
// Build: clang -O2 -framework CoreFoundation -lIOReport -o ../bin/abs_probe abs_probe.c
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
typedef struct IOReportSubscription *S;
extern CFDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
extern S IOReportCreateSubscription(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamples(S, CFMutableDictionaryRef, CFTypeRef);
extern CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
extern int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t);
int main(void) {
    CFDictionaryRef em = IOReportCopyChannelsInGroup(CFSTR("Energy Model"), NULL, 0, 0, 0);
    CFMutableDictionaryRef d = CFDictionaryCreateMutableCopy(NULL, 0, em), sb = NULL;
    S s = IOReportCreateSubscription(NULL, d, &sb, 0, NULL);
    for (int t = 0; t < 25; t++) {
        CFDictionaryRef x = IOReportCreateSamples(s, sb, NULL);
        CFArrayRef a = CFDictionaryGetValue(x, CFSTR("IOReportChannels"));
        for (CFIndex i = 0; i < CFArrayGetCount(a); i++) {
            CFDictionaryRef c = CFArrayGetValueAtIndex(a, i);
            char n[64];
            CFStringGetCString(IOReportChannelGetChannelName(c), n, 64, kCFStringEncodingUTF8);
            if (!strcmp(n, "CPU Energy") || !strcmp(n, "GPU Energy") || !strcmp(n, "DRAM"))
                printf("%s=%lld ", n, (long long)IOReportSimpleGetIntegerValue(c, 0));
        }
        printf("t=%d\n", t);
        fflush(stdout);
        CFRelease(x);
        sleep(1);
    }
}

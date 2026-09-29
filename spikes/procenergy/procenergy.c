// T-011 spike: per-process energy via proc_pid_rusage(RUSAGE_INFO_V6).
// Usage: procenergy [interval_s=5] [top=10] [pid ...]
//   With pids: only those pids are sampled (used by T-012).
#include <libproc.h>
#include <sys/resource.h>
#include <mach/mach_time.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct {
    pid_t pid;
    int ok;           // 1 = read, 0 = EPERM/other error
    int err;
    uint64_t energy_nj, penergy_nj, cpu_abs, start_abs;
    char name[64];
} sample_t;

static int read_one(pid_t pid, sample_t *s) {
    struct rusage_info_v6 ri;
    memset(s, 0, sizeof *s);
    s->pid = pid;
    if (proc_pid_rusage(pid, RUSAGE_INFO_V6, (rusage_info_t *)&ri) != 0) {
        s->err = errno;
        return 0;
    }
    s->ok = 1;
    s->energy_nj = ri.ri_energy_nj;
    s->penergy_nj = ri.ri_penergy_nj;
    s->cpu_abs = ri.ri_user_time + ri.ri_system_time;
    s->start_abs = ri.ri_proc_start_abstime;
    if (proc_name(pid, s->name, sizeof s->name) <= 0) strcpy(s->name, "?");
    return 1;
}

static int take(pid_t *pids, int n, sample_t *out) {
    for (int i = 0; i < n; i++) read_one(pids[i], &out[i]);
    return n;
}

typedef struct { pid_t pid; double w, j, pshare, cpu; char name[64]; } row_t;

static int cmp_row(const void *a, const void *b) {
    double d = ((const row_t *)b)->w - ((const row_t *)a)->w;
    return d > 0 ? 1 : d < 0 ? -1 : 0;
}

int main(int argc, char **argv) {
    double interval = argc > 1 ? atof(argv[1]) : 5.0;
    int top = argc > 2 ? atoi(argv[2]) : 10;
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);

    int n;
    pid_t *pids;
    if (argc > 3) {
        n = argc - 3;
        pids = calloc(n, sizeof *pids);
        for (int i = 0; i < n; i++) pids[i] = atoi(argv[3 + i]);
    } else {
        int cap = proc_listallpids(NULL, 0) + 64;
        pids = calloc(cap, sizeof *pids);
        n = proc_listallpids(pids, cap * (int)sizeof *pids);
    }
    sample_t *a = calloc(n, sizeof *a), *b = calloc(n, sizeof *b);
    uint64_t t0 = mach_absolute_time();
    take(pids, n, a);
    usleep((useconds_t)(interval * 1e6));
    take(pids, n, b);
    double dt = (double)(mach_absolute_time() - t0) * tb.numer / tb.denom / 1e9;

    row_t *rows = calloc(n, sizeof *rows);
    int nr = 0, denied = 0, gone = 0, readable = 0;
    double total_w = 0;
    for (int i = 0; i < n; i++) {
        if (!a[i].ok) { if (a[i].err == EPERM) denied++; else gone++; continue; }
        if (!b[i].ok || b[i].start_abs != a[i].start_abs) { gone++; continue; }
        readable++;
        double dj = (double)(b[i].energy_nj - a[i].energy_nj) / 1e9;
        double dpj = (double)(b[i].penergy_nj - a[i].penergy_nj) / 1e9;
        double dcpu = (double)(b[i].cpu_abs - a[i].cpu_abs) * tb.numer / tb.denom / 1e9;
        row_t *r = &rows[nr++];
        r->pid = pids[i];
        r->j = dj;
        r->w = dj / dt;
        r->pshare = dj > 0 ? dpj / dj : 0;
        r->cpu = dcpu / dt * 100.0;
        memcpy(r->name, b[i].name, sizeof r->name);
        total_w += r->w;
    }
    qsort(rows, nr, sizeof *rows, cmp_row);
    printf("interval=%.2fs pids=%d readable=%d denied(EPERM)=%d exited_or_err=%d sum_readable=%.3fW\n",
           dt, n, readable, denied, gone, total_w);
    printf("%7s %-24s %9s %9s %7s %7s\n", "pid", "name", "watt", "joule", "cpu%", "P_share");
    for (int i = 0; i < nr && i < top; i++)
        printf("%7d %-24.24s %9.3f %9.3f %7.1f %7.2f\n", rows[i].pid, rows[i].name, rows[i].w,
               rows[i].j, rows[i].cpu, rows[i].pshare);
    return 0;
}

#include "Host.c"
#include "HostBenchmarkLegacy.h"
#include "HostTestStubs.h"
static double clock_ms(void) {
    LARGE_INTEGER n, f;
    QueryPerformanceCounter(&n);
    QueryPerformanceFrequency(&f);
    return (double)n.QuadPart * 1000.0 / (double)f.QuadPart;
}
static double cpu_ms(void) {
    FILETIME c, e, k, u;
    GetProcessTimes(GetCurrentProcess(), &c, &e, &k, &u);
    return (double)(ticks(k) + ticks(u)) / 10000.0;
}
static int compare_times(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}
int main(int argc, char **argv) {
    if (argc != 2)
        return 2;
    int mode = atoi(argv[1]);
    if (mode < 0 || mode > 2)
        return 2;
    double cpu = cpu_ms(), start = clock_ms();
    if (mode && !owners_start())
        return 3;
    Sample cold = mode ? collect_host_mode(mode == 2) : collect_legacy();
    printf("mode=%d cold_ms=%.3f processes=%zu\n", mode, clock_ms() - start,
           cold.count);
    sample_free(&cold);
    Sleep(3000);
    printf("cold_plus_worker_cpu_ms=%.3f\n", cpu_ms() - cpu);
    double times[40], sum = 0;
    size_t min_count = SIZE_MAX, max_count = 0;
    cpu = cpu_ms();
    for (size_t i = 0; i < 40; ++i) {
        start = clock_ms();
        Sample s = mode ? collect_host_mode(mode == 2) : collect_legacy();
        times[i] = clock_ms() - start;
        sum += times[i];
        if (s.count < min_count)
            min_count = s.count;
        if (s.count > max_count)
            max_count = s.count;
        sample_free(&s);
        Sleep(250);
    }
    double cost = cpu_ms() - cpu;
    qsort(times, 40, sizeof(double), compare_times);
    printf("warm_mean_ms=%.3f median_ms=%.3f p95_ms=%.3f "
           "whole_process_cpu_ms_per_sample=%.3f processes=%zu..%zu\n",
           sum / 40, times[20], times[37], cost / 40, min_count, max_count);
    if (mode)
        owners_stop();
    return 0;
}

#include "Host.c"
#include <assert.h>
char *environment_processes(size_t *n) {
    *n = 0;
    return NULL;
}
char *environment_detail(const char *t, uint32_t p, const char *s, size_t *n) {
    (void)t;
    (void)p;
    (void)s;
    *n = 0;
    return NULL;
}
bool environment_signal_request(const char *t, uint32_t p, const char *s,
                                bool f, char *e, size_t n) {
    (void)t;
    (void)p;
    (void)s;
    (void)f;
    (void)e;
    (void)n;
    return false;
}
static void require(bool ok) {
    if (!ok)
        abort();
}
int main(int argc, char **argv) {
    Sample real = collect_host();
    bool found = false;
    require(real.cores > 0 && real.kernel > 0 && real.count > 0);
    for (size_t i = 0; i < real.count; ++i)
        if (real.rows[i].pid == GetCurrentProcessId()) {
            found = true;
            require(real.rows[i].created > 0 && real.rows[i].memory > 0 &&
                    strcmp(real.rows[i].user, "Unavailable"));
        }
    require(found);
    sample_free(&real);
    Row a = {.id = 10,
             .pid = 10,
             .created = 100,
             .cpu = 100,
             .command = win_strdup("Windows busy"),
             .user = win_strdup("tester"),
             .target = win_strdup(""),
             .start = win_strdup("")};
    Row b = {.id = CONTAINER_ID_BASE,
             .pid = 10,
             .cpu = 50,
             .command = win_strdup("Alpha · busy"),
             .user = win_strdup("root"),
             .target = win_strdup("alpha"),
             .start = win_strdup("1")};
    history[0] = (Sample){.time = 100,
                          .index = 1,
                          .cores = 8,
                          .has_cpu = true,
                          .user_percent = 10,
                          .system_percent = 20,
                          .idle_percent = 70};
    append_row(&history[0], a);
    append_row(&history[0], b);
    history[1] = (Sample){.time = 101,
                          .index = 2,
                          .cores = 8,
                          .has_cpu = true,
                          .user_percent = 20,
                          .system_percent = 20,
                          .idle_percent = 60};
    a = copy_row(&a);
    a.created = 200;
    a.cpu = 20;
    append_row(&history[1], a);
    history_count = 2;
    HttpRequest r = {.query =
                         "timeMode=fixed&timeStart=100&timeEnd=101&start=0&"
                         "end=100&sort=cpu&direction=desc"};
    StringBuilder f = frame(&r);
    require(read_uint32_le((unsigned char *)f.data + 8) == 3);
    require(read_uint32_le((unsigned char *)f.data + 52) == 10);
    FILE *file = fopen(argc > 1 ? argv[1] : "top-host-frame.bin", "wb");
    require(file != NULL);
    require(fwrite(f.data, 1, f.length, file) == f.length);
    fclose(file);
    free(f.data);
    r.query = "timeMode=fixed&timeStart=100&timeEnd=100&search=alpha";
    f = frame(&r);
    require(read_uint32_le((unsigned char *)f.data + 8) == 1 &&
            read_uint32_le((unsigned char *)f.data + 52) == CONTAINER_ID_BASE);
    free(f.data);
    f = cpu_history();
    require(f.length == 112 &&
            read_uint32_le((unsigned char *)f.data + 12) == 2);
    free(f.data);
    sample_free(&history[0]);
    sample_free(&history[1]);
    history_count = 0;
    HANDLE stop = CreateEventW(NULL, TRUE, FALSE, NULL);
    require(top_start(stop));
    ULONGLONG until = GetTickCount64() + 2500;
    volatile double busy = 0;
    while (GetTickCount64() < until)
        busy += sqrt((double)GetTickCount64());
    (void)busy;
    AcquireSRWLockShared(&lock);
    Sample *last = at(history_count - 1);
    require(history_count >= 2 && last->has_cpu);
    require(fabs(last->user_percent + last->system_percent +
                 last->idle_percent - 100) < 0.01);
    found = false;
    for (size_t i = 0; i < last->count; ++i)
        if (last->rows[i].pid == GetCurrentProcessId()) {
            found = true;
            require(last->rows[i].cpu > 20);
        }
    require(found);
    ReleaseSRWLockShared(&lock);
    top_stop();
    CloseHandle(stop);
    puts("PASS host enumeration, memory, owner, CPU counters, busy process, "
         "historical intervals, reused PIDs, container PID collision, search, "
         "and binary frames");
    return 0;
}

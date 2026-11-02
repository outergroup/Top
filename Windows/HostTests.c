#include "Host.c"
#include "HostTestStubs.h"
#include <assert.h>
static void require(bool ok) {
    if (!ok)
        abort();
}
int main(int argc, char **argv) {
    require(owners_start());
    Sample real = collect_host();
    sample_free(&real);
    Sleep(2000);
    real = collect_host();
    bool found = false;
    require(real.cores > 0 && real.kernel > 0 && real.count > 0);
    for (size_t i = 0; i < real.count; ++i)
        if (real.rows[i].pid == GetCurrentProcessId()) {
            found = true;
            require(real.rows[i].created > 0 && real.rows[i].memory > 0 &&
                    strcmp(real.rows[i].user, "—"));
        }
    require(found);
    sample_free(&real);
    owners_stop();
    FILETIME birth, exit, kernel, user;
    require(GetProcessTimes(GetCurrentProcess(), &birth, &exit, &kernel,
                            &user) != 0);
    Sample bulk = {0};
    require(collect_bulk(&bulk));
    found = false;
    for (size_t i = 0; i < bulk.count; ++i)
        if (bulk.rows[i].pid == GetCurrentProcessId()) {
            found = true;
            require(bulk.rows[i].created == ticks(birth));
            require(bulk.rows[i].ticks >= ticks(kernel) + ticks(user));
            require(bulk.rows[i].memory > 0 && bulk.rows[i].threads > 0);
            require(strstr(bulk.rows[i].command, "TopHostTests") != NULL);
        }
    require(found);
    sample_free(&bulk);
    NativeProcess malformed = {0};
    malformed.next = 1;
    require(!parse_processes(&bulk, (unsigned char *)&malformed,
                             sizeof(malformed)));
    malformed.next = 0;
    malformed.image.length = 2;
    malformed.image.buffer = (PWSTR)1;
    require(!parse_processes(&bulk, (unsigned char *)&malformed,
                             sizeof(malformed)));
    char *wrong_owner = resolve_owner(GetCurrentProcessId(), ticks(birth) + 1);
    require(wrong_owner == NULL);
    char *first_owner = resolve_owner(GetCurrentProcessId(), ticks(birth));
    char *second_owner = resolve_owner(GetCurrentProcessId(), ticks(birth));
    require(first_owner && second_owner && !strcmp(first_owner, second_owner));
    free(first_owner);
    free(second_owner);
    owners_stop();
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
    ProcessOrder stream_order = {0}, independent_order = {0};
    r.query = "timeMode=fixed&timeStart=100&timeEnd=101&start=0&end=1&sort=cpu&"
              "direction=desc";
    f = ordered_frame(&r, &stream_order);
    require(read_uint32_le((unsigned char *)f.data + 84) == UINT32_MAX);
    free(f.data);
    history[0].rows[0].cpu = 1;
    history[0].rows[1].cpu = 200;
    f = ordered_frame(&r, &stream_order);
    require(read_uint32_le((unsigned char *)f.data + 52) == CONTAINER_ID_BASE);
    require(read_uint32_le((unsigned char *)f.data + 84) == 1);
    size_t metrics_offset = 52 + 41 + strlen(b.user) + strlen(b.command);
    require(read_uint32_le((unsigned char *)f.data + metrics_offset + 29) == 1);
    require(read_uint32_le((unsigned char *)f.data + metrics_offset + 33) == 2);
    require(read_uint32_le((unsigned char *)f.data + metrics_offset + 37) ==
            10);
    require(read_uint32_le((unsigned char *)f.data + metrics_offset + 69) == 0);
    char motion_path[1024];
    snprintf(motion_path, sizeof(motion_path), "%s.motion",
             argc > 1 ? argv[1] : "top-host-frame.bin");
    file = fopen(motion_path, "wb");
    require(file != NULL && fwrite(f.data, 1, f.length, file) == f.length);
    fclose(file);
    free(f.data);
    f = ordered_frame(&r, &independent_order);
    require(read_uint32_le((unsigned char *)f.data + 84) == UINT32_MAX);
    free(f.data);
    r.query = "timeMode=fixed&timeStart=100&timeEnd=101&start=1&end=2&sort=cpu&"
              "direction=desc";
    f = ordered_frame(&r, &stream_order);
    require(read_uint32_le((unsigned char *)f.data + 84) == 1);
    free(f.data);
    r.query = "timeMode=fixed&timeStart=100&timeEnd=101&start=0&end=1&sort=cpu&"
              "direction=asc";
    f = ordered_frame(&r, &stream_order);
    require(read_uint32_le((unsigned char *)f.data + 84) == UINT32_MAX);
    free(f.data);
    r.query = "timeMode=fixed&timeStart=100&timeEnd=101&start=0&end=1&sort=cpu&"
              "direction=asc&search=alpha";
    f = ordered_frame(&r, &stream_order);
    require(read_uint32_le((unsigned char *)f.data + 84) == UINT32_MAX);
    free(f.data);
    order_free(&stream_order);
    order_free(&independent_order);
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

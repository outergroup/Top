#include "Host.h"
#include "AppResources.h"
#include <math.h>
#include <psapi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <tlhelp32.h>

#define HISTORY 180
#define CONTAINER_ID_BASE 0x40000000u
char *environment_processes(size_t *length);
char *environment_detail(const char *, uint32_t, const char *, size_t *);
bool environment_signal_request(const char *, uint32_t, const char *, bool,
                                char *, size_t);
typedef struct {
    uint32_t id, pid, parent, threads;
    uint64_t created, ticks, memory;
    double cpu;
    char *command, *user, *target, *start;
} Row;
typedef struct {
    Row *rows;
    size_t count;
    double time, monotonic;
    uint64_t index, idle, kernel, user;
    double idle_percent, system_percent, user_percent;
    bool has_cpu;
    uint32_t cores;
} Sample;
typedef struct Client {
    struct Client *next;
    char *id, *query;
} Client;
static SRWLOCK lock = SRWLOCK_INIT;
static Sample history[HISTORY], containers;
static size_t history_count, history_start;
static uint64_t sequence;
static uint32_t next_host_id = 1;
static uint32_t next_container_id = CONTAINER_ID_BASE;
static HANDLE stop_event, sampler, container_sampler;
static Client *clients;
static uint64_t ticks(FILETIME t) {
    return ((uint64_t)t.dwHighDateTime << 32) | t.dwLowDateTime;
}
static double timestamp(void) {
    FILETIME t;
    GetSystemTimeAsFileTime(&t);
    return (double)(ticks(t) - 116444736000000000ULL) / 1e7;
}
static void put_double(StringBuilder *b, size_t offset, double v) {
    uint64_t bits;
    memcpy(&bits, &v, 8);
    payload_u64(b, offset, bits);
}
static void put_float(StringBuilder *b, size_t offset, double v) {
    float f = (float)v;
    uint32_t bits;
    memcpy(&bits, &f, 4);
    payload_u32(b, offset, bits);
}
static void row_free(Row *r) {
    free(r->command);
    free(r->user);
    free(r->target);
    free(r->start);
}
static void sample_free(Sample *s) {
    for (size_t i = 0; i < s->count; ++i)
        row_free(s->rows + i);
    free(s->rows);
    *s = (Sample){0};
}
static void append_row(Sample *s, Row r) {
    Row *p = realloc(s->rows, (s->count + 1) * sizeof(*p));
    if (!p) {
        row_free(&r);
        return;
    }
    s->rows = p;
    s->rows[s->count++] = r;
}
static Row copy_row(const Row *r) {
    Row v = *r;
    v.command = win_strdup(r->command);
    v.user = win_strdup(r->user);
    v.target = win_strdup(r->target);
    v.start = win_strdup(r->start);
    return v;
}
static Sample *at(size_t i) { return &history[(history_start + i) % HISTORY]; }
static bool same(const Row *a, const Row *b) {
    return a->id == b->id && a->created == b->created &&
           !strcmp(a->start, b->start);
}
static char *process_user(HANDLE p) {
    HANDLE token;
    if (!OpenProcessToken(p, TOKEN_QUERY, &token))
        return win_strdup("Unavailable");
    DWORD n = 0;
    GetTokenInformation(token, TokenUser, NULL, 0, &n);
    TOKEN_USER *user = win_alloc(n);
    char *result = NULL;
    if (GetTokenInformation(token, TokenUser, user, n, &n)) {
        wchar_t name[256], domain[256];
        DWORD nl = 256, dl = 256;
        SID_NAME_USE use;
        if (LookupAccountSidW(NULL, user->User.Sid, name, &nl, domain, &dl,
                              &use))
            result = win_utf8(name);
    }
    free(user);
    CloseHandle(token);
    return result ? result : win_strdup("Unavailable");
}
static Sample collect_host(void) {
    Sample s = {.time = timestamp(), .monotonic = GetTickCount64() / 1000.0};
    FILETIME idle, kernel, user;
    s.cores = GetActiveProcessorCount(ALL_PROCESSOR_GROUPS);
    bool cpu_ok = true;
    WORD groups = GetActiveProcessorGroupCount();
    for (WORD group = 0; group < groups; ++group) {
        GROUP_AFFINITY affinity = {0}, previous;
        affinity.Group = group;
        affinity.Mask = 1;
        if (!SetThreadGroupAffinity(GetCurrentThread(), &affinity, &previous)) {
            cpu_ok = false;
            break;
        }
        bool ok = GetSystemTimes(&idle, &kernel, &user) != 0;
        SetThreadGroupAffinity(GetCurrentThread(), &previous, NULL);
        if (!ok) {
            cpu_ok = false;
            break;
        }
        s.idle += ticks(idle);
        s.kernel += ticks(kernel);
        s.user += ticks(user);
    }
    if (!cpu_ok)
        s.idle = s.kernel = s.user = 0;
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE)
        return s;
    PROCESSENTRY32W entry = {.dwSize = sizeof(entry)};
    if (Process32FirstW(snapshot, &entry))
        do {
            if (!entry.th32ProcessID)
                continue;
            Row r = {.id = entry.th32ProcessID,
                     .pid = entry.th32ProcessID,
                     .parent = entry.th32ParentProcessID,
                     .threads = entry.cntThreads,
                     .command = win_utf8(entry.szExeFile),
                     .target = win_strdup(""),
                     .start = win_strdup("")};
            HANDLE p =
                OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, r.pid);
            if (p) {
                FILETIME created, exit, k, u;
                if (GetProcessTimes(p, &created, &exit, &k, &u)) {
                    r.created = ticks(created);
                    r.ticks = ticks(k) + ticks(u);
                }
                PROCESS_MEMORY_COUNTERS memory = {.cb = sizeof(memory)};
                if (GetProcessMemoryInfo(p, &memory, sizeof(memory)))
                    r.memory = memory.WorkingSetSize;
                r.user = process_user(p);
                CloseHandle(p);
            } else
                r.user = win_strdup("Unavailable");
            append_row(&s, r);
        } while (Process32NextW(snapshot, &entry));
    CloseHandle(snapshot);
    return s;
}
static DWORD WINAPI sample_loop(void *context) {
    (void)context;
    do {
        Sample s = collect_host();
        AcquireSRWLockExclusive(&lock);
        Sample *prev = history_count ? at(history_count - 1) : NULL;
        for (size_t i = 0; i < s.count; ++i) {
            Row *r = s.rows + i;
            r->id = 0;
            if (prev)
                for (size_t j = 0; j < prev->count; ++j) {
                    Row *old = prev->rows + j;
                    if (!*old->target && old->pid == r->pid &&
                        old->created == r->created) {
                        r->id = old->id;
                        break;
                    }
                }
            if (!r->id)
                r->id = next_host_id++;
        }
        if (prev && s.monotonic > prev->monotonic) {
            uint64_t k = s.kernel - prev->kernel, u = s.user - prev->user,
                     idle = s.idle - prev->idle;
            if (s.kernel >= prev->kernel && s.user >= prev->user &&
                s.idle >= prev->idle && prev->kernel && k + u && k >= idle) {
                s.has_cpu = true;
                s.user_percent = 100.0 * (double)u / (double)(k + u);
                s.system_percent = 100.0 * (double)(k - idle) / (double)(k + u);
                s.idle_percent = 100.0 * (double)idle / (double)(k + u);
            }
            for (size_t i = 0; i < s.count; ++i)
                for (size_t j = 0; j < prev->count; ++j)
                    if (same(&s.rows[i], &prev->rows[j]) &&
                        s.rows[i].ticks >= prev->rows[j].ticks) {
                        s.rows[i].cpu =
                            (double)(s.rows[i].ticks - prev->rows[j].ticks) /
                            1e5 / (s.monotonic - prev->monotonic);
                        break;
                    }
        }
        if (s.monotonic - containers.monotonic < 15)
            for (size_t i = 0; i < containers.count; ++i)
                append_row(&s, copy_row(containers.rows + i));
        s.index = ++sequence;
        if (history_count == HISTORY) {
            sample_free(at(0));
            history_start = (history_start + 1) % HISTORY;
            --history_count;
        }
        *at(history_count++) = s;
        ReleaseSRWLockExclusive(&lock);
    } while (WaitForSingleObject(stop_event, 1000) == WAIT_TIMEOUT);
    return 0;
}
static DWORD WINAPI container_loop(void *context) {
    (void)context;
    do {
        size_t length = 0;
        char *data = environment_processes(&length);
        Sample s = {.monotonic = GetTickCount64() / 1000.0};
        if (data && length >= 80 &&
            !read_uint32_le((unsigned char *)data + 12)) {
            uint32_t count = read_uint32_le((unsigned char *)data + 28),
                     offset = read_uint32_le((unsigned char *)data + 32);
            for (uint32_t i = 0;
                 i < count && offset + (uint64_t)(i + 1) * 112 <= length; ++i) {
                const unsigned char *p =
                    (unsigned char *)data + offset + i * 112;
                uint32_t target = read_uint32_le(p + 96);
                size_t t = 80 + (size_t)target * 56;
                if (t + 56 > length)
                    continue;
                Row r = {.pid = read_uint32_le(p),
                         .parent = read_uint32_le(p + 4),
                         .threads = read_uint32_le(p + 40),
                         .memory = payload_read64(p + 16),
                         .target = payload_string(data, length, t),
                         .start = payload_string(
                             data, length,
                             (size_t)(p - (unsigned char *)data) + 56)};
                char *name = payload_string(data, length, t + 24),
                     *command = payload_string(
                         data, length,
                         (size_t)(p - (unsigned char *)data) + 64);
                r.user = payload_string(
                    data, length, (size_t)(p - (unsigned char *)data) + 72);
                StringBuilder label = {0};
                sb_append(&label, name);
                sb_append(&label, " · ");
                sb_append(&label, command);
                r.command = label.data;
                free(name);
                free(command);
                uint64_t frequency = payload_read64(p + 32);
                r.ticks = frequency
                              ? (uint64_t)((double)payload_read64(p + 24) *
                                           1e7 / (double)frequency)
                              : 0;
                AcquireSRWLockShared(&lock);
                for (size_t j = 0; j < containers.count; ++j) {
                    Row *old = containers.rows + j;
                    if (old->pid == r.pid && !strcmp(old->target, r.target) &&
                        !strcmp(old->start, r.start)) {
                        r.id = old->id;
                        if (s.monotonic > containers.monotonic &&
                            r.ticks >= old->ticks)
                            r.cpu = (double)(r.ticks - old->ticks) / 1e5 /
                                    (s.monotonic - containers.monotonic);
                        break;
                    }
                }
                ReleaseSRWLockShared(&lock);
                if (!r.id)
                    r.id = next_container_id++;
                append_row(&s, r);
            }
        }
        free(data);
        AcquireSRWLockExclusive(&lock);
        sample_free(&containers);
        containers = s;
        ReleaseSRWLockExclusive(&lock);
    } while (WaitForSingleObject(stop_event, 1000) == WAIT_TIMEOUT);
    return 0;
}
static double query_number(HttpRequest *r, const char *name, double fallback) {
    char *s = http_query(r, name), *end = NULL;
    double value = s ? strtod(s, &end) : fallback;
    if (s && (!*s || *end || !isfinite(value)))
        value = fallback;
    free(s);
    return value;
}
typedef struct {
    Row row;
    double total;
    size_t samples;
} ViewRow;
typedef struct {
    char *sort;
    bool ascending;
} Sort;
static int compare(void *context, const void *left, const void *right) {
    const ViewRow *a = left, *b = right;
    Sort *sort = context;
    int result;
    if (!strcmp(sort->sort, "command"))
        result = _stricmp(a->row.command, b->row.command);
    else if (!strcmp(sort->sort, "user"))
        result = _stricmp(a->row.user, b->row.user);
    else {
        double x = a->row.cpu, y = b->row.cpu;
        if (!strcmp(sort->sort, "memory")) {
            x = (double)a->row.memory;
            y = (double)b->row.memory;
        } else if (!strcmp(sort->sort, "pid")) {
            x = a->row.pid;
            y = b->row.pid;
        } else if (!strcmp(sort->sort, "cpuTime") ||
                   !strcmp(sort->sort, "time") ||
                   !strcmp(sort->sort, "cputime")) {
            x = (double)a->row.ticks;
            y = (double)b->row.ticks;
        }
        result = x < y ? -1 : x > y;
    }
    if (!result)
        result = a->row.id < b->row.id ? -1 : a->row.id > b->row.id;
    return sort->ascending ? result : -result;
}
static bool matches(const Row *r, const char *search) {
    if (!*search)
        return true;
    char pid[32];
    snprintf(pid, sizeof(pid), "%u", r->pid);
    const char *fields[] = {r->command, r->user, pid};
    for (size_t i = 0; i < 3; ++i)
        for (const char *s = fields[i]; *s; ++s)
            if (!_strnicmp(s, search, strlen(search)))
                return true;
    return false;
}
static StringBuilder frame(HttpRequest *request) {
    StringBuilder b = payload(52);
    if (!history_count)
        return b;
    Sample *latest = at(history_count - 1);
    char *mode = http_query(request, "timeMode"),
         *search = http_query(request, "search"),
         *sort = http_query(request, "sort"),
         *direction = http_query(request, "direction");
    bool fixed = mode && !strcmp(mode, "fixed");
    double end =
        fixed ? query_number(request, "timeEnd", latest->time) : latest->time;
    double start =
        fixed ? query_number(request, "timeStart", end)
              : end - fmin(180,
                           fmax(.5, query_number(request, "timeDuration", 60)));
    ViewRow *rows = NULL;
    size_t count = 0, samples = 0;
    double user = 0, system = 0, idle = 0;
    size_t cpu_samples = 0;
    for (size_t n = 0; n < history_count; ++n) {
        Sample *s = at(n);
        if (s->time < start || s->time > end)
            continue;
        ++samples;
        if (s->has_cpu) {
            user += s->user_percent;
            system += s->system_percent;
            idle += s->idle_percent;
            ++cpu_samples;
        }
        for (size_t i = 0; i < s->count; ++i) {
            Row *r = s->rows + i;
            size_t j;
            if (!matches(r, search ? search : ""))
                continue;
            for (j = 0; j < count; ++j)
                if (same(&rows[j].row, r))
                    break;
            if (j == count) {
                ViewRow *p = realloc(rows, (count + 1) * sizeof(*p));
                if (!p)
                    continue;
                rows = p;
                rows[count++] = (ViewRow){.row = *r};
            }
            rows[j].row = *r;
            rows[j].total += r->cpu;
            ++rows[j].samples;
        }
    }
    for (size_t i = 0; i < count; ++i)
        rows[i].row.cpu = samples ? rows[i].total / (double)samples : 0;
    Sort order = {.sort = sort ? sort : "cpu",
                  .ascending = direction && !strcmp(direction, "asc")};
    qsort_s(rows, count, sizeof(*rows), compare, &order);
    size_t first =
        (size_t)fmin((double)count, fmax(0, query_number(request, "start", 0)));
    size_t last = (size_t)fmin(
        (double)count,
        fmax((double)first, query_number(request, "end", 1000000)));
    put_double(&b, 0, latest->time);
    payload_u32(&b, 8, (uint32_t)(last - first));
    payload_u32(&b, 12, (uint32_t)first);
    payload_u32(&b, 16, (uint32_t)count);
    payload_u64(&b, 20, latest->index);
    put_double(&b, 28, start);
    put_double(&b, 36, end);
    b.data[44] = fixed ? 1 : 3;
    for (size_t i = first; i < last; ++i) {
        Row *r = &rows[i].row;
        size_t o = b.length;
        binary_append_zero(&b, 37);
        payload_u32(&b, o, r->id);
        put_float(&b, o + 4, r->cpu);
        payload_u64(&b, o + 8, r->memory / 1024);
        payload_u64(&b, o + 16, r->ticks / 10000);
        payload_u32(&b, o + 24, (uint32_t)strlen(r->user));
        payload_u32(&b, o + 28, (uint32_t)strlen(r->command));
        payload_u32(&b, o + 32, UINT32_MAX);
        b.data[o + 36] = 2;
        sb_append(&b, r->user);
        sb_append(&b, r->command);
        o = b.length;
        binary_append_zero(&b, 4);
        payload_u32(&b, o, r->pid);
    }
    size_t o = b.length;
    binary_append_zero(&b, 33);
    b.data[o] = latest->has_cpu;
    put_float(&b, o + 1,
              fixed && cpu_samples ? user / (double)cpu_samples
                                   : latest->user_percent);
    put_float(&b, o + 5,
              fixed && cpu_samples ? system / (double)cpu_samples
                                   : latest->system_percent);
    put_float(&b, o + 9,
              fixed && cpu_samples ? idle / (double)cpu_samples
                                   : latest->idle_percent);
    uint32_t threads = 0;
    for (size_t i = 0; i < count; ++i)
        threads += rows[i].row.threads;
    payload_u32(&b, o + 13, (uint32_t)count);
    payload_u32(&b, o + 17, (uint32_t)count);
    payload_u32(&b, o + 21, threads);
    payload_u32(&b, o + 25, latest->cores);
    free(rows);
    free(mode);
    free(search);
    free(sort);
    free(direction);
    return b;
}
static StringBuilder cpu_history(void) {
    StringBuilder b = payload(32 + history_count * 40);
    memcpy(b.data, "OTCH", 4);
    payload_u32(&b, 4, 1);
    payload_u32(&b, 8, (uint32_t)b.length);
    payload_u32(&b, 12, (uint32_t)history_count);
    payload_u32(&b, 16, 40);
    payload_u32(&b, 20, 32);
    for (size_t i = 0; i < history_count; ++i) {
        Sample *s = at(i);
        size_t o = 32 + i * 40;
        put_double(&b, o, s->time);
        payload_u32(&b, o + 8, s->has_cpu);
        put_double(&b, o + 16, s->user_percent);
        put_double(&b, o + 24, s->system_percent);
        put_double(&b, o + 32, s->idle_percent);
    }
    return b;
}
static Row find_row(uint32_t id) {
    Row result = {0};
    AcquireSRWLockShared(&lock);
    if (history_count) {
        Sample *s = at(history_count - 1);
        for (size_t i = 0; i < s->count; ++i)
            if (s->rows[i].id == id) {
                result = copy_row(s->rows + i);
                break;
            }
    }
    ReleaseSRWLockShared(&lock);
    return result;
}
static StringBuilder detail(const Row *r) {
    StringBuilder b = payload(144);
    memcpy(b.data, "OTPD", 4);
    payload_u32(&b, 4, 1);
    payload_u32(&b, 16, 24);
    payload_u32(&b, 20, 144);
    payload_u32(&b, 24, 144);
    put_double(&b, 32, timestamp());
    payload_u32(&b, 40, r->pid);
    payload_u32(&b, 44, r->parent);
    put_double(&b, 48, r->cpu);
    payload_u64(&b, 56, r->memory / 1024);
    payload_u64(&b, 72, r->ticks / 10000);
    payload_u32(&b, 80, r->threads);
    payload_text(&b, 88, r->user);
    payload_text(&b, 96, r->command);
    payload_text(&b, 104, r->command);
    payload_text(&b, 112, "");
    payload_text(&b, 120, "");
    payload_text(
        &b, 128,
        "Open-file inspection is not available for Windows processes.");
    payload_u32(&b, 8, (uint32_t)b.length);
    return b;
}
typedef struct {
    DWORD pid;
    bool posted;
} CloseWindows;
static BOOL CALLBACK close_window(HWND window, LPARAM param) {
    CloseWindows *p = (CloseWindows *)param;
    DWORD pid = 0;
    GetWindowThreadProcessId(window, &pid);
    if (pid == p->pid && !GetWindow(window, GW_OWNER))
        p->posted |= PostMessageW(window, WM_CLOSE, 0, 0) != 0;
    return TRUE;
}
static void terminate(Connection *c, HttpRequest *r, Row *row, bool force) {
    char error[1024] = "This process is unavailable or has exited.";
    bool ok = false;
    if (row->id && *row->target)
        ok = environment_signal_request(row->target, row->pid, row->start,
                                        force, error, sizeof(error));
    else if (row->id && row->created && row->pid != GetCurrentProcessId()) {
        HANDLE p = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION |
                                   (force ? PROCESS_TERMINATE : 0),
                               FALSE, row->pid);
        FILETIME created, exit, k, u;
        if (p && GetProcessTimes(p, &created, &exit, &k, &u) &&
            ticks(created) == row->created) {
            if (force)
                ok = TerminateProcess(p, 1) != 0;
            else {
                CloseWindows windows = {.pid = row->pid};
                EnumWindows(close_window, (LPARAM)&windows);
                ok = windows.posted;
                snprintf(error, sizeof(error),
                         "This process has no window that can accept Quit. Use "
                         "Force "
                         "Quit to terminate it.");
            }
        }
        if (p)
            CloseHandle(p);
    }
    http_text(c, r, ok ? 200 : 409, ok ? "Termination requested." : error);
}
bool top_request(Connection *c, HttpRequest *r, const char *directory) {
    if (!strcmp(r->path, "/api/processes/stream")) {
        Client client = {.id = http_query(r, "clientId"),
                         .query = win_strdup(r->query ? r->query : "")};
        if (!client.id) {
            free(client.query);
            http_text(c, r, 400, "Missing client ID.");
            return true;
        }
        AcquireSRWLockExclusive(&lock);
        client.next = clients;
        clients = &client;
        ReleaseSRWLockExclusive(&lock);
        const char *header = "HTTP/1.1 200 OK\r\nContent-Type: "
                             "application/octet-stream\r\nCache-Control: "
                             "no-store\r\nConnection: close\r\n\r\n";
        c->responded = true;
        bool ok = connection_write(c, header, strlen(header));
        do {
            AcquireSRWLockShared(&lock);
            HttpRequest query = {.query = client.query};
            StringBuilder b = frame(&query);
            ReleaseSRWLockShared(&lock);
            if (ok)
                ok = connection_write(c, b.data, b.length);
            free(b.data);
        } while (ok && WaitForSingleObject(stop_event, 1000) == WAIT_TIMEOUT);
        AcquireSRWLockExclusive(&lock);
        Client **p = &clients;
        while (*p && *p != &client)
            p = &(*p)->next;
        if (*p)
            *p = client.next;
        ReleaseSRWLockExclusive(&lock);
        free(client.id);
        free(client.query);
        return true;
    }
    if (!strcmp(r->path, "/api/processes/viewport")) {
        char *id = http_query(r, "clientId");
        AcquireSRWLockExclusive(&lock);
        for (Client *p = clients; p; p = p->next)
            if (id && !strcmp(p->id, id)) {
                free(p->query);
                p->query = win_strdup(r->query);
            }
        StringBuilder b = frame(r);
        ReleaseSRWLockExclusive(&lock);
        free(id);
        http_send(c, r, 200, "application/octet-stream", b.data, b.length);
        free(b.data);
        return true;
    }
    if (!strcmp(r->path, "/api/processes/history") ||
        !strcmp(r->path, "/api/processes/cpu_history")) {
        AcquireSRWLockShared(&lock);
        StringBuilder b = !strcmp(r->path, "/api/processes/history")
                              ? frame(r)
                              : cpu_history();
        ReleaseSRWLockShared(&lock);
        http_send(c, r, 200, "application/octet-stream", b.data, b.length);
        free(b.data);
        return true;
    }
    char *mode = http_query(r, "mode");
    bool root_detail = !strcmp(r->path, "/") && mode && !strcmp(mode, "detail");
    free(mode);
    if (!strncmp(r->path, "/api/processes/", 15) || root_detail) {
        char *pid = http_query(r, "pid"), *end = NULL;
        const char *number = pid ? pid : r->path + (root_detail ? 0 : 15);
        unsigned long id = strtoul(number, &end, 10);
        Row row = *number && end && !*end ? find_row((uint32_t)id) : (Row){0};
        free(pid);
        if (!strcmp(r->path, "/api/processes/quit") ||
            !strcmp(r->path, "/api/processes/force-quit"))
            terminate(c, r, &row,
                      !strcmp(r->path, "/api/processes/force-quit"));
        else if (!row.id)
            http_text(c, r, 404, "This process has exited.");
        else {
            StringBuilder b;
            if (*row.target) {
                b = (StringBuilder){0};
                b.data = environment_detail(row.target, row.pid, row.start,
                                            &b.length);
            } else
                b = detail(&row);
            if (!b.data)
                http_text(c, r, 404, "This process has exited.");
            else if (root_detail) {
                if (!app_resources_payload(c, r, directory, "TopContent.bundle",
                                           b.data, b.length)) {
                    char *web = win_join(directory, "web");
                    http_static(c, r, web);
                    free(web);
                }
            } else
                http_send(c, r, 200, "application/octet-stream", b.data,
                          b.length);
            free(b.data);
        }
        row_free(&row);
        return true;
    }
    return false;
}
bool top_start(HANDLE stop) {
    stop_event = stop;
    Sample first = collect_host();
    for (size_t i = 0; i < first.count; ++i)
        first.rows[i].id = next_host_id++;
    first.index = ++sequence;
    history[0] = first;
    history_count = 1;
    sampler = CreateThread(NULL, 0, sample_loop, NULL, 0, NULL);
    container_sampler = CreateThread(NULL, 0, container_loop, NULL, 0, NULL);
    return sampler && container_sampler;
}
void top_stop(void) {
    SetEvent(stop_event);
    if (sampler) {
        WaitForSingleObject(sampler, INFINITE);
        CloseHandle(sampler);
    }
    if (container_sampler) {
        WaitForSingleObject(container_sampler, INFINITE);
        CloseHandle(container_sampler);
    }
    for (size_t i = 0; i < history_count; ++i)
        sample_free(at(i));
    sample_free(&containers);
}

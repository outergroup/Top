#include "helper.h"
#include <math.h>
long clock_ticks(void) {
    long n = sysconf(_SC_CLK_TCK);
    return n > 0 ? n : 100;
}
static void process_free(Process *p) {
    free(p->start);
    free(p->command);
    free(p->user);
    free(p->state);
    free(p->cgroup);
    free(p->host_user);
    *p = (Process){0};
}
void processes_free(Processes *p) {
    for (size_t i = 0; i < p->count; i++)
        process_free(&p->items[i]);
    free(p->items);
    *p = (Processes){0};
}
bool process_add(Processes *list, Process p) {
    if (list->count >= (MAX_DATA - RESPONSE_SIZE) / PROCESS_ROW_SIZE) {
        fail("too many processes");
        process_free(&p);
        return false;
    }
    Process *next = realloc(list->items, (list->count + 1) * sizeof(*next));
    if (!next) {
        fail("out of memory");
        process_free(&p);
        return false;
    }
    list->items = next;
    list->items[list->count++] = p;
    return true;
}
static Bytes process_file(int pid, const char *name) {
    char path[128];
    snprintf(path, sizeof(path), "/proc/%d/%s", pid, name);
    failure[0] = 0;
    return read_file(path, 1024 * 1024, false);
}
#ifdef __linux__
static bool process_row(int pid, Process *r) {
    Bytes raw = process_file(pid, "stat"), status = {0}, cmd = {0}, group = {0};
    bool ok = false;
    if (!raw.data)
        goto done;
    status = process_file(pid, "status");
    if (!status.data)
        goto done;
    char *left = strchr((char *)raw.data, '('), *right = strrchr((char *)raw.data, ')');
    if (!left || !right || right <= left)
        goto done;
    *right = 0;
    char *fields[64], *save = NULL;
    size_t count = 0;
    for (char *p = strtok_r(right + 2, " \n", &save); p && count < 64; p = strtok_r(NULL, " \n", &save))
        fields[count++] = p;
    if (count < 22)
        goto done;
    *r = (Process){.pid = pid,
                   .container_pid = pid,
                   .ticks = (uint64_t)clock_ticks(),
                   .state = strdup(fields[0]),
                   .start = strdup(fields[19]),
                   .parent_pid = (int)strtol(fields[1], NULL, 10),
                   .threads = (int)strtol(fields[17], NULL, 10),
                   .cpu_ticks = strtoull(fields[11], NULL, 10) + strtoull(fields[12], NULL, 10),
                   .has_cpu_ticks = true,
                   .user = strdup("")};
    cmd = process_file(pid, "cmdline");
    if (cmd.data) {
        for (size_t i = 0; i < cmd.size; i++)
            if (!cmd.data[i])
                cmd.data[i] = ' ';
        while (cmd.size && isspace(cmd.data[cmd.size - 1]))
            cmd.data[--cmd.size] = 0;
    }
    r->command = strdup(cmd.size ? (char *)cmd.data : left + 1);
    for (char *line = strtok_r((char *)status.data, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        if (!strncmp(line, "Uid:", 4)) {
            char uid[32];
            if (sscanf(line + 4, "%31s", uid) == 1) {
                free(r->user);
                r->user = strdup(uid);
            }
        } else if (!strncmp(line, "VmRSS:", 6))
            r->memory = strtoull(line + 6, NULL, 10) * 1024;
        else if (!strncmp(line, "NSpid:", 6)) {
            char *p = line + 6;
            long value = pid;
            while (*p) {
                while (isspace((unsigned char)*p))
                    p++;
                if (!*p)
                    break;
                char *end;
                value = strtol(p, &end, 10);
                if (end == p)
                    break;
                p = end;
            }
            r->container_pid = (int)value;
        }
    }
    group = process_file(pid, "cgroup");
    r->cgroup = strdup(group.data ? (char *)group.data : "");
    ok = true;
done:
    bytes_free(&raw);
    bytes_free(&status);
    bytes_free(&cmd);
    bytes_free(&group);
    failure[0] = 0;
    return ok;
}
Processes collect_processes(void) {
    Processes rows = {0};
    DIR *dir = opendir("/proc");
    if (!dir) {
        fail("open /proc: %s", strerror(errno));
        return rows;
    }
    struct dirent *e;
    while ((e = readdir(dir))) {
        char *end;
        long pid = strtol(e->d_name, &end, 10);
        if (*end || pid <= 0 || pid > INT_MAX)
            continue;
        Process r = {0};
        if (process_row((int)pid, &r) && !process_add(&rows, r))
            break;
    }
    closedir(dir);
    return rows;
}
const char *container_uid(int pid, const char *uid, char result[32]) {
    Bytes data = process_file(pid, "uid_map");
    if (!data.data) {
        failure[0] = 0;
        return uid;
    }
    unsigned long long v = strtoull(uid, NULL, 10);
    char *save = NULL;
    bool found = false;
    for (char *line = strtok_r((char *)data.data, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        unsigned long long inside, outside, count;
        if (sscanf(line, "%llu %llu %llu", &inside, &outside, &count) == 3 && v >= outside &&
            v - outside < count) {
            snprintf(result, 32, "%llu", inside + v - outside);
            found = true;
            break;
        }
    }
    bytes_free(&data);
    failure[0] = 0;
    return found ? result : uid;
}
#else
const char *container_uid(int pid, const char *uid, char result[32]) {
    (void)pid;
    (void)result;
    return uid;
}
Processes collect_processes(void) {
    Processes rows = {0};
    char *args[] = {"/bin/ps", "-axo", "pid=,ppid=,uid=,pcpu=,rss=,lstart=,comm=", NULL};
    Bytes b = command(args, 4);
    if (!b.data)
        return rows;
    char *save = NULL;
    for (char *line = strtok_r((char *)b.data, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        int pid, ppid, n = 0;
        char uid[32], weekday[16], month[16], day[16], hour[32], year[16];
        double cpu;
        long long rss;
        if (sscanf(line, "%d %d %31s %lf %lld %15s %15s %15s %31s %15s %n", &pid, &ppid, uid, &cpu, &rss,
                   weekday, month, day, hour, year, &n) != 10)
            continue;
        Process r = {.pid = pid,
                     .parent_pid = ppid,
                     .user = strdup(uid),
                     .cpu = cpu,
                     .memory = (uint64_t)rss * 1024,
                     .start = format("%s %s %s %s %s", weekday, month, day, hour, year),
                     .command = strdup(line + n),
                     .ticks = (uint64_t)clock_ticks(),
                     .state = strdup(""),
                     .cgroup = strdup("")};
        if (!process_add(&rows, r))
            break;
    }
    bytes_free(&b);
    return rows;
}
#endif
BinaryReply processes_encode(Processes rows) {
    BinaryReply reply = response_create(OP_PROCESSES, (uint32_t)rows.count, PROCESS_ROW_SIZE);
    if (!reply.metadata.data)
        return reply;
    for (size_t i = 0; i < rows.count && !failure[0]; i++) {
        process_encode_row(&reply.metadata, RESPONSE_SIZE + i * PROCESS_ROW_SIZE, &rows.items[i]);
    }
    return reply;
}

void process_encode_row(Bytes *bytes, size_t offset, const Process *p) {
    unsigned char *r = bytes->data + offset;
    put_u32(r, (uint32_t)p->pid);
    put_u32(r + 4, (uint32_t)p->parent_pid);
    put_u32(r + 8, (uint32_t)p->container_pid);
    put_u64(r + 16, p->memory);
    put_u64(r + 24, p->cpu_ticks);
    put_u64(r + 32, p->ticks);
    put_u32(r + 40, (uint32_t)p->threads);
    put_u32(r + 44, p->has_cpu_ticks ? 1 : 2);
    uint64_t cpu;
    memcpy(&cpu, &p->cpu, 8);
    put_u64(r + 48, cpu);
    binary_string(bytes, offset + 56, p->start);
    binary_string(bytes, offset + 64, p->command);
    binary_string(bytes, offset + 72, p->user);
    binary_string(bytes, offset + 80, p->state);
    binary_string(bytes, offset + 88, p->cgroup);
}

Processes processes_decode(BinaryReply reply) {
    Processes rows = {0};
    if (!response_validate(reply, OP_PROCESSES))
        return rows;
    Bytes b = reply.metadata;
    size_t count = get_u32(b.data + 20), variable = get_u32(b.data + 32);
    for (size_t i = 0; i < count && !failure[0]; i++) {
        size_t offset = RESPONSE_SIZE + i * PROCESS_ROW_SIZE;
        unsigned char *r = b.data + offset;
        uint32_t flags = get_u32(r + 44);
        uint64_t bits = get_u64(r + 48);
        Process p = {.pid = (int)get_u32(r),
                     .parent_pid = (int)get_u32(r + 4),
                     .container_pid = (int)get_u32(r + 8),
                     .memory = get_u64(r + 16),
                     .cpu_ticks = get_u64(r + 24),
                     .ticks = get_u64(r + 32),
                     .threads = (int)get_u32(r + 40),
                     .has_cpu_ticks = flags == 1};
        memcpy(&p.cpu, &bits, 8);
        if (p.pid <= 0 || p.parent_pid < 0 || p.container_pid < 0 || p.threads < 0 || get_u32(r + 12) ||
            (flags != 1 && flags != 2) || !isfinite(p.cpu) || p.cpu < 0)
            fail("invalid process record");
        p.start = binary_read_string(b, offset + 56, variable, 128);
        p.command = binary_read_string(b, offset + 64, variable, MAX_DATA);
        p.user = binary_read_string(b, offset + 72, variable, 256);
        p.state = binary_read_string(b, offset + 80, variable, 32);
        p.cgroup = binary_read_string(b, offset + 88, variable, MAX_DATA);
        if (failure[0]) {
            process_free(&p);
            break;
        }
        if (!process_add(&rows, p))
            break;
    }
    if (failure[0])
        processes_free(&rows);
    return rows;
}

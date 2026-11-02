#define APP_TOP 1
#define HELPER_CAPABILITIES 48u
#define HELPER_APP_ID "org.outershell.Top"
#define HELPER_NAME "outer-top-helper"
#define APP_FRAME_MAGIC "TPH2"
#include "AppEnvironment.h"
#include "../Helper/binary.c"
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
        if (p.pid <= 0 || p.parent_pid < 0 || p.container_pid < 0 ||
            p.threads < 0 || get_u32(r + 12) || (flags != 1 && flags != 2) ||
            !isfinite(p.cpu) || p.cpu < 0)
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

BinaryReply local_binary_operation(const Request *r, Bytes b) {
    (void)r;
    (void)b;
    fail("Windows Top displays container processes only.");
    return (BinaryReply){0};
}
#include "../Backend/Environment/snapshot.inc"
#include "AppEnvironmentRuntime.inc"

char *environment_processes(size_t *length) {
    AcquireSRWLockExclusive(&environment_lock);
    failure[0] = 0;
    environment_initialize();
    EnvironmentSnapshot snapshot = discover_environments();
    for (size_t i = 0; i < snapshot.target_count; i++) {
        EnvironmentTarget *t = &snapshot.targets[i];
        if (strcmp(t->state, "running"))
            continue;
        Request request = {.operation = OP_PROCESSES,
                           .path = "",
                           .destination = "",
                           .revision = "",
                           .start = ""};
        BinaryReply reply =
            environment_binary_operation(t->id, "", &request, (Bytes){0});
        Processes rows = {0};
        if (!failure[0])
            rows = processes_decode(reply);
        binary_reply_free(&reply);
        if (failure[0]) {
            environment_error(&snapshot, t->name, failure);
            failure[0] = 0;
        }
        for (size_t j = 0; j < rows.count; j++) {
            rows.items[j].target_index = (uint32_t)i;
            process_add(&snapshot.processes, rows.items[j]);
        }
        free(rows.items);
    }
    Bytes result = environment_snapshot_encode(&snapshot);
    environment_snapshot_free(&snapshot);
    *length = result.size;
    ReleaseSRWLockExclusive(&environment_lock);
    return (char *)result.data;
}
bool environment_signal_request(const char *target, uint32_t pid,
                                const char *start, bool force, char *error,
                                size_t size) {
    AcquireSRWLockExclusive(&environment_lock);
    failure[0] = 0;
    environment_initialize();
    Request request = {.operation = OP_SIGNAL,
                       .pid = pid,
                       .signal = force ? 9 : 15,
                       .path = "",
                       .destination = "",
                       .revision = "",
                       .start = (char *)start};
    BinaryReply reply =
        environment_binary_operation(target, "", &request, (Bytes){0});
    bool ok = !failure[0] && response_validate(reply, OP_SIGNAL);
    snprintf(error, size, "%s",
             failure[0] ? failure : "Signal could not be sent.");
    binary_reply_free(&reply);
    ReleaseSRWLockExclusive(&environment_lock);
    return ok;
}

char *environment_detail(const char *target, uint32_t pid, const char *start,
                         size_t *length) {
    AcquireSRWLockExclusive(&environment_lock);
    failure[0] = 0;
    environment_initialize();
    Request request = {.operation = OP_PROCESSES,
                       .path = "",
                       .destination = "",
                       .revision = "",
                       .start = ""};
    BinaryReply reply =
        environment_binary_operation(target, "", &request, (Bytes){0});
    Processes rows = {0};
    if (!failure[0])
        rows = processes_decode(reply);
    binary_reply_free(&reply);
    StringBuilder result = {0};
    for (size_t i = 0; i < rows.count; i++) {
        Process *p = &rows.items[i];
        if (p->pid != (int)pid || strcmp(p->start, start))
            continue;
        result = payload(144);
        memcpy(result.data, "OTPD", 4);
        payload_u32(&result, 4, 1);
        payload_u32(&result, 16, 24);
        payload_u32(&result, 20, 144);
        payload_u32(&result, 24, 144);
        FILETIME ft;
        GetSystemTimeAsFileTime(&ft);
        ULARGE_INTEGER ticks;
        ticks.LowPart = ft.dwLowDateTime;
        ticks.HighPart = ft.dwHighDateTime;
        double stamp =
            (double)(ticks.QuadPart - 116444736000000000ULL) / 10000000.0;
        uint64_t bits;
        memcpy(&bits, &stamp, 8);
        payload_u64(&result, 32, bits);
        payload_u32(&result, 40, pid);
        payload_u32(&result, 44, (uint32_t)p->parent_pid);
        double cpu = p->has_cpu_ticks ? 0 : p->cpu;
        memcpy(&bits, &cpu, 8);
        payload_u64(&result, 48, bits);
        payload_u64(&result, 56, p->memory / 1024);
        payload_u64(&result, 72, p->cpu_ticks * 10);
        payload_u32(&result, 80, (uint32_t)p->threads);
        payload_text(&result, 88, p->user);
        payload_text(&result, 96, p->command);
        payload_text(&result, 104, p->command);
        payload_text(&result, 112, "");
        payload_text(&result, 120, "");
        payload_text(
            &result, 128,
            "Open-file inspection is not available for container processes.");
        payload_u32(&result, 8, (uint32_t)result.length);
        break;
    }
    processes_free(&rows);
    *length = result.length;
    ReleaseSRWLockExclusive(&environment_lock);
    return result.data;
}

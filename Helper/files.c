#include "helper.h"
static bool signal_process(const Request *request) {
    if (request->pid <= 1 || request->pid > INT_MAX) {
        fail("invalid process ID or init process");
        return false;
    }
    int signo = request->signal == 1 ? SIGTERM : request->signal == 2 ? SIGKILL : 0;
    if (!signo) {
        fail("invalid signal");
        return false;
    }
    Processes rows = collect_processes();
    if (failure[0])
        return false;
    bool found = false;
    for (size_t i = 0; i < rows.count; i++)
        if (rows.items[i].pid == (int)request->pid && !strcmp(rows.items[i].start, request->start)) {
            found = true;
            break;
        }
    processes_free(&rows);
    if (!found) {
        fail("the selected process has exited or changed");
        return false;
    }
    if (kill((pid_t)request->pid, signo)) {
        fail("signal: %s", strerror(errno));
        return false;
    }
    return true;
}
BinaryReply local_binary_operation(const Request *request, Bytes body) {
    BinaryReply r = {0};
    uint32_t op = request->operation;
    if (body.size) { fail("unexpected request body"); return r; }
    if (op == OP_PROCESSES) {
        Processes rows = collect_processes();
        if (!failure[0])
            r = processes_encode(rows);
        processes_free(&rows);
        return r;
    }
    if (op == OP_SIGNAL) {
        if (signal_process(request))
            r = response_create(op, 0, 0);
        return r;
    }
    fail("unsupported Top operation");
    return r;
}

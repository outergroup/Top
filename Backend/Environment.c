#include "Environment.h"
#include "../Helper/common.c"
#include "../Helper/binary.c"
#include "../Helper/child.c"
#include "../Helper/files.c"
#include "../Helper/protocol.c"
#include "../Helper/processes.c"
#include "Environment/runtime.inc"
#include "Environment/snapshot.inc"
#include "Environment/client.inc"

static pthread_mutex_t environment_mutex = PTHREAD_MUTEX_INITIALIZER;
char *environment_request(const void *body, size_t length, size_t *result_length) {
    if (length > MAX_DATA) return NULL;
    pthread_mutex_lock(&environment_mutex);
    static bool initialized;
    if (!initialized) { atexit(sessions_close); initialized = true; }
    deadline = now() + 25;
    failure[0] = 0;
    Bytes result = environment_operation((Bytes){(unsigned char *)body, length});
    if (result.data) *result_length = result.size;
    pthread_mutex_unlock(&environment_mutex);
    return (char *)result.data;
}

bool environment_signal(const char *target_id, uint32_t pid, const char *start, bool force, char *error, size_t error_size) {
    pthread_mutex_lock(&environment_mutex);
    deadline = now() + 25;
    failure[0] = 0;
    EnvironmentSnapshot snapshot = discover_environments();
    EnvironmentTarget *target = NULL;
    for (size_t i = 1; i < snapshot.target_count; i++)
        if (!strcmp(snapshot.targets[i].id, target_id)) target = &snapshot.targets[i];
    if (!target || !pid || !start || !*start) fail("The selected container process is no longer available.");
    if (!failure[0]) {
        Request request = {.operation = OP_SIGNAL, .pid = pid, .signal = force ? 2 : 1, .start = (char *)start};
        BinaryReply reply = target_operation(target, "", &request, (Bytes){0});
        binary_reply_free(&reply);
    }
    bool ok = !failure[0];
    snprintf(error, error_size, "%s", failure);
    environment_snapshot_free(&snapshot);
    pthread_mutex_unlock(&environment_mutex);
    return ok;
}

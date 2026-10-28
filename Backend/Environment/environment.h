#ifndef ENVIRONMENT_SNAPSHOT_H
#define ENVIRONMENT_SNAPSHOT_H
#include "../../Helper/helper.h"
typedef struct {
    char *id, *runtime, *container, *name, *state, *image, *user;
    char *executable, *socket;
    uid_t owner_uid;
} EnvironmentTarget;
typedef struct {
    char *runtime, *message;
} EnvironmentError;
typedef struct {
    EnvironmentTarget *targets;
    size_t target_count;
    EnvironmentError *errors;
    size_t error_count;
    Processes processes;
    uint64_t time_ms;
} EnvironmentSnapshot;
EnvironmentSnapshot discover_environments(void);
EnvironmentSnapshot unified_processes(void);
void environment_snapshot_free(EnvironmentSnapshot *snapshot);
Bytes environment_snapshot_encode(const EnvironmentSnapshot *snapshot);
Bytes environment_operation(Bytes input);
void sessions_close(void);
#endif

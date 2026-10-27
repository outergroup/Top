#include "environment.h"
Bytes environment_operation(Bytes input) {
    if (input.size) fail("Top expects an empty snapshot request");
    EnvironmentSnapshot snapshot = failure[0] ? (EnvironmentSnapshot){0} : unified_processes();
    Bytes bytes = environment_snapshot_encode(&snapshot);
    environment_snapshot_free(&snapshot);
    return bytes;
}

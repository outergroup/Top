#ifndef ENVIRONMENT_TOOLS_H
#define ENVIRONMENT_TOOLS_H
#include <sys/wait.h>

#include "Environment.h"
static char *environment_tools_processes(size_t *result_length) {
    return environment_request(NULL, 0, result_length);
}
#endif

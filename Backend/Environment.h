#ifndef APP_ENVIRONMENT_H
#define APP_ENVIRONMENT_H
#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>
char *environment_request(const void *body, size_t length, size_t *result_length);
bool environment_signal(const char *target, uint32_t pid, const char *start, bool force, char *error, size_t error_size);
#endif

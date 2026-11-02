#ifndef TOP_WINDOWS_HOST_H
#define TOP_WINDOWS_HOST_H
#include "Runtime.h"
bool top_start(HANDLE stop);
void top_stop(void);
bool top_request(Connection *c, HttpRequest *r, const char *directory);
#endif

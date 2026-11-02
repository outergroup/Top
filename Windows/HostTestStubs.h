char *environment_processes(size_t *n) {
    *n = 0;
    return NULL;
}
char *environment_detail(const char *t, uint32_t p, const char *s, size_t *n) {
    (void)t;
    (void)p;
    (void)s;
    *n = 0;
    return NULL;
}
bool environment_signal_request(const char *t, uint32_t p, const char *s,
                                bool f, char *e, size_t n) {
    (void)t;
    (void)p;
    (void)s;
    (void)f;
    (void)e;
    (void)n;
    return false;
}

#define main top_backend_main
#include "../Backend/main.c"
#undef main
#include <assert.h>

static void put32(unsigned char *p, uint32_t value) {
    for (unsigned i = 0; i < 4; i++) p[i] = (unsigned char)(value >> (i * 8));
}
static void put64(unsigned char *p, uint64_t value) {
    for (unsigned i = 0; i < 8; i++) p[i] = (unsigned char)(value >> (i * 8));
}
int main(void) {
    struct proc_bsdinfo info;
    assert(proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, sizeof(info)) == sizeof(info));
    const char name[] = "WKWebView: Test 雪, example.com";
    unsigned char data[56 + sizeof(name) - 1] = {0};
    memcpy(data, "OLPN", 4);
    put32(data + 4, 1);
    put32(data + 8, getpid());
    put64(data + 12, info.pbi_start_tvsec);
    put64(data + 20, info.pbi_start_tvusec);
    put32(data + 28, 1);
    put32(data + 32, getpid());
    put64(data + 36, info.pbi_start_tvsec);
    put64(data + 44, info.pbi_start_tvusec);
    put32(data + 52, sizeof(name) - 1);
    memcpy(data + 56, name, sizeof(name) - 1);
    assert(outer_loop_parse_labels(data, sizeof(data), getuid()));
    char output[256];
    assert(outer_loop_process_label(getpid(), output, sizeof(output)));
    assert(strcmp(output, name) == 0);
    for (size_t i = 0; i < sizeof(data); i++) {
        outer_loop_label_count = 0;
        assert(!outer_loop_parse_labels(data, i, getuid()));
        assert(outer_loop_label_count == 0);
    }
    put32(data + 4, 2);
    assert(!outer_loop_parse_labels(data, sizeof(data), getuid()));
    put32(data + 4, 1);
    put64(data + 12, info.pbi_start_tvsec + 1);
    assert(!outer_loop_parse_labels(data, sizeof(data), getuid()));
    put64(data + 12, info.pbi_start_tvsec);
    put64(data + 36, info.pbi_start_tvsec + 1);
    assert(outer_loop_parse_labels(data, sizeof(data), getuid()));
    assert(!outer_loop_process_label(getpid(), output, sizeof(output)));
    outer_loop_label_count = 0;
    put64(data + 36, info.pbi_start_tvsec);
    put32(data + 52, UINT32_MAX);
    assert(!outer_loop_parse_labels(data, sizeof(data), getuid()));
    put32(data + 52, sizeof(name) - 1);
    data[56] = 0;
    assert(!outer_loop_parse_labels(data, sizeof(data), getuid()));
    puts("Web process label tests passed");
    return 0;
}

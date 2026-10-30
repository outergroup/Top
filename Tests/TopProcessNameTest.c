#define main top_backend_main
#include "../Backend/main.c"
#undef main
#include <assert.h>

static bool parse_arguments(int count, const char *arguments, size_t length, char *out, size_t capacity) {
    char buffer[1024];
    const char executable[] = "/tmp/OuterframeContent\0\0";
    size_t offset = sizeof(count) + sizeof(executable);
    assert(offset + length <= sizeof(buffer));
    memcpy(buffer, &count, sizeof(count));
    memcpy(buffer + sizeof(count), executable, sizeof(executable));
    memcpy(buffer + offset, arguments, length);
    return outerframe_app_name_from_arguments(buffer, offset + length, out, capacity);
}

int main(void) {
    char name[256];
    const char valid[] = "OuterframeContent\0--app-name\0My App 雪\0--infra-socket-fd\0";
    assert(parse_arguments(4, valid, sizeof(valid), name, sizeof(name)));
    assert(strcmp(name, "OuterframeContent: My App 雪") == 0);
    const char missing[] = "OuterframeContent\0--infra-socket-fd\0003\0--app-name\0Fake\0";
    assert(!parse_arguments(3, missing, sizeof(missing), name, sizeof(name)));
    const char empty[] = "OuterframeContent\0--app-name\0\0";
    assert(!parse_arguments(3, empty, sizeof(empty), name, sizeof(name)));
    const char truncated[] = "OuterframeContent\0--app-name\0Top";
    assert(!parse_arguments(3, truncated, sizeof(truncated) - 1, name, sizeof(name)));
    char small[8];
    assert(parse_arguments(4, valid, sizeof(valid), small, sizeof(small)));
    assert(small[sizeof(small) - 1] == '\0');
    assert(!parse_arguments(4, valid, sizeof(valid), name, 0));
    assert(!outerframe_app_name_from_arguments("", 0, name, sizeof(name)));
    assert(read_outerframe_app_name(getpid(), name, sizeof(name)));
    assert(strcmp(name, "OuterframeContent: Test App 雪") == 0);
    assert(read_process_short_command(getpid(), name, sizeof(name)));
    assert(strcmp(name, "OuterframeContent: Test App 雪") == 0);
    puts("Process name tests passed");
    return 0;
}

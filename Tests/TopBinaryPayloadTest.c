#define main top_backend_main
#include "../Backend/main.c"
#undef main
#include <assert.h>
static void save_fixture(const char *directory, const char *name, const char *bytes, size_t length) {
    char path[PATH_MAX]; snprintf(path, sizeof(path), "%s/%s", directory, name);
    FILE *file = fopen(path, "wb"); assert(file); assert(fwrite(bytes, 1, length, file) == length); fclose(file);
}
int main(int argc, char **argv) {
    assert(argc == 2);
    char buffer[DETAIL_BUFFER_SIZE];
    ProcessDetail detail = {.pid = 123, .parent_pid = 45, .cpu_percent = 12.5, .rss_kb = 12345, .footprint_kb = 5432,
        .vsz_kb = 98765, .cpu_time_ms = 6789, .thread_count = 3, .is_kernel_thread = true};
    strcpy(detail.user, "café"); strcpy(detail.command, "runner \"雪\"\n--test");
    strcpy(detail.short_command, "runner"); strcpy(detail.parent_short_command, "parent");
    strcpy(detail.launch_time, "2026-10-27 12:34");
    OpenFileEntry file = {0}; strcpy(file.descriptor, "4"); strcpy(file.type, "REG");
    strcpy(file.name, "/tmp/雪 café\n\"file\"");
    size_t size = encode_process_detail(&detail, &file, 1, "Some files unavailable", buffer, sizeof(buffer));
    assert(size > 168); save_fixture(argv[1], "detail.bin", buffer, size);
    assert(encode_process_detail(&detail, &file, 1, NULL, buffer, 143) == 0);
    size = encode_process_detail(&detail, NULL, 0, NULL, buffer, sizeof(buffer));
    save_fixture(argv[1], "empty-files.bin", buffer, size);
    current_snapshot.valid = true; current_snapshot.timestamp = 1234.5;
    current_snapshot.metrics.has_cpu = true; current_snapshot.metrics.cpu_user = 12.5;
    current_snapshot.metrics.cpu_system = 25; current_snapshot.metrics.cpu_idle = 62.5;
    size = build_cpu_history_binary(buffer, sizeof(buffer)); assert(size == 72);
    save_fixture(argv[1], "history.bin", buffer, size);
    current_snapshot.valid = false; size = build_cpu_history_binary(buffer, sizeof(buffer)); assert(size == 32);
    save_fixture(argv[1], "empty-history.bin", buffer, size);
    return 0;
}

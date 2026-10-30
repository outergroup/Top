#ifndef OUTER_LOOP_PROCESS_LABELS_H
#define OUTER_LOOP_PROCESS_LABELS_H

#ifdef __APPLE__
#define OUTER_LOOP_LABEL_LIMIT 4096

typedef struct {
    uint32_t pid;
    uint64_t seconds;
    uint64_t microseconds;
    char name[256];
} OuterLoopProcessLabel;

static OuterLoopProcessLabel outer_loop_labels[OUTER_LOOP_LABEL_LIMIT];
static size_t outer_loop_label_count;

static uint32_t outer_loop_u32(const unsigned char *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static uint64_t outer_loop_u64(const unsigned char *p) {
    return (uint64_t)outer_loop_u32(p) | (uint64_t)outer_loop_u32(p + 4) << 32;
}

static bool outer_loop_process_matches(uint32_t pid, uint64_t seconds, uint64_t microseconds, uid_t uid) {
    struct proc_bsdinfo info;
    return pid > 0 && pid <= INT_MAX &&
        proc_pidinfo((int)pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) == sizeof(info) &&
        info.pbi_uid == uid && info.pbi_start_tvsec == seconds && info.pbi_start_tvusec == microseconds;
}

static bool outer_loop_parse_labels(const unsigned char *data, size_t size, uid_t uid) {
    if (size < 32 || memcmp(data, "OLPN", 4) || outer_loop_u32(data + 4) != 1) return false;
    uint32_t count = outer_loop_u32(data + 28);
    if (count > OUTER_LOOP_LABEL_LIMIT ||
        !outer_loop_process_matches(outer_loop_u32(data + 8), outer_loop_u64(data + 12),
                                   outer_loop_u64(data + 20), uid)) return false;
    size_t offset = 32;
    for (uint32_t i = 0; i < count; i++) {
        if (size - offset < 24) return false;
        uint32_t length = outer_loop_u32(data + offset + 20);
        offset += 24;
        if (!length || length > 16384 || length > size - offset || memchr(data + offset, 0, length)) return false;
        offset += length;
    }
    if (offset != size) return false;
    offset = 32;
    for (uint32_t i = 0; i < count && outer_loop_label_count < OUTER_LOOP_LABEL_LIMIT; i++) {
        OuterLoopProcessLabel *label = &outer_loop_labels[outer_loop_label_count++];
        label->pid = outer_loop_u32(data + offset);
        label->seconds = outer_loop_u64(data + offset + 4);
        label->microseconds = outer_loop_u64(data + offset + 12);
        uint32_t length = outer_loop_u32(data + offset + 20);
        offset += 24;
        size_t copied = length < sizeof(label->name) ? length : sizeof(label->name) - 1;
        while (copied < length && copied > 0 && (data[offset + copied] & 0xc0) == 0x80) copied--;
        memcpy(label->name, data + offset, copied);
        label->name[copied] = 0;
        offset += length;
    }
    return true;
}

static void outer_loop_reload_labels(void) {
    outer_loop_label_count = 0;
    struct passwd *user = getpwuid(getuid());
    if (!user) return;
    char path[PATH_MAX];
    int length = snprintf(path, sizeof(path), "%s/Library/Caches/dev.outergroup.OuterLoop/ProcessLabels", user->pw_dir);
    if (length < 0 || (size_t)length >= sizeof(path)) return;
    DIR *directory = opendir(path);
    if (!directory) return;
    struct dirent *entry;
    size_t files = 0;
    while ((entry = readdir(directory)) && files < 256) {
        size_t length = strlen(entry->d_name);
        if (length < 5 || strcmp(entry->d_name + length - 4, ".bin")) continue;
        files++;
        int fd = openat(dirfd(directory), entry->d_name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
        if (fd < 0) continue;
        struct stat info;
        if (fstat(fd, &info) || !S_ISREG(info.st_mode) || info.st_uid != getuid() ||
            info.st_size < 32 || info.st_size > 16 * 1024 * 1024) {
            close(fd);
            continue;
        }
        size_t size = (size_t)info.st_size;
        unsigned char *data = malloc(size);
        if (data) {
            size_t used = 0;
            while (used < size) {
                ssize_t result = read(fd, data + used, size - used);
                if (result < 0 && errno == EINTR) continue;
                if (result <= 0) break;
                used += (size_t)result;
            }
            if (used == size) outer_loop_parse_labels(data, size, info.st_uid);
            free(data);
        }
        close(fd);
    }
    closedir(directory);
}

static bool outer_loop_process_label(int pid, char *out, size_t capacity) {
    for (size_t i = 0; i < outer_loop_label_count; i++) {
        const OuterLoopProcessLabel *label = &outer_loop_labels[i];
        if (label->pid == (uint32_t)pid &&
            outer_loop_process_matches(label->pid, label->seconds, label->microseconds, getuid())) {
            snprintf(out, capacity, "%s", label->name);
            return true;
        }
    }
    return false;
}
#endif
#endif

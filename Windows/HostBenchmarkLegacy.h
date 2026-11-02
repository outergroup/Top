static char *legacy_user(HANDLE p) {
    HANDLE token;
    if (!OpenProcessToken(p, TOKEN_QUERY, &token))
        return win_strdup("Unavailable");
    DWORD n = 0;
    GetTokenInformation(token, TokenUser, NULL, 0, &n);
    TOKEN_USER *user = win_alloc(n);
    char *result = NULL;
    if (GetTokenInformation(token, TokenUser, user, n, &n)) {
        wchar_t name[256], domain[256];
        DWORD nl = 256, dl = 256;
        SID_NAME_USE use;
        if (LookupAccountSidW(NULL, user->User.Sid, name, &nl, domain, &dl,
                              &use))
            result = win_utf8(name);
    }
    free(user);
    CloseHandle(token);
    return result ? result : win_strdup("Unavailable");
}
static Sample collect_legacy(void) {
    Sample s = {.time = timestamp(), .monotonic = GetTickCount64() / 1000.0};
    FILETIME idle, kernel, user;
    s.cores = GetActiveProcessorCount(ALL_PROCESSOR_GROUPS);
    bool cpu_ok = true;
    WORD groups = GetActiveProcessorGroupCount();
    for (WORD group = 0; group < groups; ++group) {
        GROUP_AFFINITY affinity = {0}, previous;
        affinity.Group = group;
        affinity.Mask = 1;
        if (!SetThreadGroupAffinity(GetCurrentThread(), &affinity, &previous)) {
            cpu_ok = false;
            break;
        }
        bool ok = GetSystemTimes(&idle, &kernel, &user) != 0;
        SetThreadGroupAffinity(GetCurrentThread(), &previous, NULL);
        if (!ok) {
            cpu_ok = false;
            break;
        }
        s.idle += ticks(idle);
        s.kernel += ticks(kernel);
        s.user += ticks(user);
    }
    if (!cpu_ok)
        s.idle = s.kernel = s.user = 0;
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE)
        return s;
    PROCESSENTRY32W entry = {.dwSize = sizeof(entry)};
    if (Process32FirstW(snapshot, &entry))
        do {
            if (!entry.th32ProcessID)
                continue;
            Row r = {.id = entry.th32ProcessID,
                     .pid = entry.th32ProcessID,
                     .parent = entry.th32ParentProcessID,
                     .threads = entry.cntThreads,
                     .command = win_utf8(entry.szExeFile),
                     .target = win_strdup(""),
                     .start = win_strdup("")};
            HANDLE p =
                OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, r.pid);
            if (p) {
                FILETIME created, exit, k, u;
                if (GetProcessTimes(p, &created, &exit, &k, &u)) {
                    r.created = ticks(created);
                    r.ticks = ticks(k) + ticks(u);
                }
                PROCESS_MEMORY_COUNTERS memory = {.cb = sizeof(memory)};
                if (GetProcessMemoryInfo(p, &memory, sizeof(memory)))
                    r.memory = memory.WorkingSetSize;
                r.user = legacy_user(p);
                CloseHandle(p);
            } else
                r.user = win_strdup("Unavailable");
            append_row(&s, r);
        } while (Process32NextW(snapshot, &entry));
    CloseHandle(snapshot);
    return s;
}

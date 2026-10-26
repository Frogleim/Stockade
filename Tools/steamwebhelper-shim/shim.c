/*
 * steamwebhelper shim for Stockade.
 *
 * Installed in place of Steam's steamwebhelper.exe; the original is kept as
 * steamwebhelper_real.exe. It starts the original with extra Chromium flags
 * that Steam's own -cef-* options do not provide:
 *
 *   --disable-gpu      CPU rasterisation; the GPU path paints the window black under Wine.
 *   --single-process   renderer and network service in one process; separate processes
 *                      paint black and break TLS through Wine's winsock.
 *
 * Approach after https://github.com/notpop/steam-on-m1-wine (MIT).
 *
 * Build: scripts/build-shim.sh
 */

#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#include <windows.h>
#include <stdlib.h>
#include <wchar.h>

/* Found by the launcher to tell this shim apart from Valve's binary. Do not change. */
__attribute__((used)) static const char marker[] = "FRONTIER_LAUNCHER_WEBHELPER_SHIM_V1";

#define EXTRA_FLAGS L"--disable-gpu --single-process"
#define REAL_NAME L"steamwebhelper_real.exe"

/* The command line minus our own executable token. */
static const wchar_t *forwarded_arguments(void)
{
    const wchar_t *cmd = GetCommandLineW();
    int quoted = 0;
    for (; *cmd; ++cmd) {
        if (*cmd == L'"') quoted = !quoted;
        else if (*cmd == L' ' && !quoted) break;
    }
    while (*cmd == L' ') ++cmd;
    return cmd;
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE previous, PWSTR args, int show)
{
    (void)instance; (void)previous; (void)args; (void)show;
    (void)marker;

    wchar_t real[MAX_PATH];
    DWORD length = GetModuleFileNameW(NULL, real, MAX_PATH);
    if (length == 0 || length >= MAX_PATH) return 1;
    wchar_t *slash = wcsrchr(real, L'\\');
    if (!slash || (size_t)(slash - real) + 1 + wcslen(REAL_NAME) >= MAX_PATH) return 1;
    wcscpy(slash + 1, REAL_NAME);

    const wchar_t *tail = forwarded_arguments();
    size_t capacity = wcslen(real) + wcslen(EXTRA_FLAGS) + wcslen(tail) + 8;
    wchar_t *command = calloc(capacity, sizeof(wchar_t));
    if (!command) return 1;
    _snwprintf(command, capacity, L"\"%ls\" %ls %ls", real, EXTRA_FLAGS, tail);

    STARTUPINFOW startup = { .cb = sizeof(startup) };
    PROCESS_INFORMATION child = {0};
    if (!CreateProcessW(real, command, NULL, NULL, TRUE, 0, NULL, NULL, &startup, &child)) {
        free(command);
        return 1;
    }
    WaitForSingleObject(child.hProcess, INFINITE);
    DWORD code = 1;
    GetExitCodeProcess(child.hProcess, &code);
    CloseHandle(child.hThread);
    CloseHandle(child.hProcess);
    free(command);
    return (int)code;
}

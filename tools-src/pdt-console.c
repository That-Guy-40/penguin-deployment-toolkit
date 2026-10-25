/* pdt-console.c - a text frame of another process's console, and keystrokes into it.
 *
 *   pdt-console dump <title> <out.txt> [--all]   the console whose title contains
 *                                                <title>: its viewport (or, --all, the
 *                                                whole buffer) as UTF-8 text, one line
 *                                                per row, trailing blanks trimmed, a
 *                                                first line "# cols= rows= cursor= ...".
 *                                                Written only when it differs from the
 *                                                file already there.
 *   pdt-console keys <title> <text>              type <text> into that console: key
 *                                                down/up per character; {enter} {esc}
 *                                                {tab} {ctrl-c} as tokens
 *   pdt-console keys <title> --hex <hex>         the same, the text as UTF-8 in hex
 *                                                (nothing for cmd to misquote)
 *   pdt-console list <out.txt>                   every process, with the title of its
 *                                                console or "-" (cannot attach): what
 *                                                "dump" and "keys" have to choose from
 *
 * For machines without a usable display: deploy.cmd titles its window "pdt-deploy",
 * shell-loop.cmd runs "dump" every few seconds and uploads a frame when the screen
 * changed (bin/console shows them), and bin/keys answers a prompt the deploy window is
 * sitting at, which bin/shell (a new cmd) cannot. tmux's capture-pane and send-keys,
 * on the two Win32 console calls Windows has had since NT: ReadConsoleOutput and
 * WriteConsoleInput. Plain Win32 (kernel32 + user32), nothing WinPE lacks. Built on
 * Linux with mingw-w64 by bin/build-tools; the hash of the result is recorded like
 * every other tool.
 *
 * How the console is found: this process gives up its own console (FreeConsole), then
 * tries AttachConsole on every process in a Toolhelp snapshot and looks for <title>
 * in that console's title (a substring: WinPE shows "Administrator:  pdt-deploy", and
 * cmd appends the running command); the console window itself belongs to conhost,
 * which refuses AttachConsole, so the title is the handle. Ctrl+C is ignored first:
 * once attached, a Ctrl+C in that window would reach this process too.
 *
 * Exit codes: 0 done (dump: a new frame was written), 4 dump: identical to the file
 * already there (nothing to upload), 2 no console with that title (or usage),
 * 3 I/O or console error.
 */
#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

static int attach_by_title(const wchar_t *want)
{
    wchar_t title[1024];
    DWORD me = GetCurrentProcessId();
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return 0;
    PROCESSENTRY32W pe;
    pe.dwSize = sizeof pe;
    int found = 0;
    if (Process32FirstW(snap, &pe)) {
        do {
            if (pe.th32ProcessID == me || pe.th32ProcessID == 0) continue;
            if (!AttachConsole(pe.th32ProcessID)) continue;
            DWORD len = GetConsoleTitleW(title, 1024);
            if (len >= 1024) len = 1023;
            title[len] = 0;
            if (wcsstr(title, want)) { found = 1; break; }
            FreeConsole();
        } while (Process32NextW(snap, &pe));
    }
    CloseHandle(snap);
    return found;
}

/* utf8 <- one UTF-16 code unit (surrogates are written as they come, pairwise) */
static size_t put_utf8(wchar_t c, char *out)
{
    unsigned u = (unsigned)c;
    if (u < 0x80) { out[0] = (char)u; return 1; }
    if (u < 0x800) { out[0] = (char)(0xC0 | (u >> 6)); out[1] = (char)(0x80 | (u & 0x3F)); return 2; }
    out[0] = (char)(0xE0 | (u >> 12)); out[1] = (char)(0x80 | ((u >> 6) & 0x3F)); out[2] = (char)(0x80 | (u & 0x3F));
    return 3;
}

static int do_dump(const wchar_t *title, const char *path, int all)
{
    if (!attach_by_title(title)) return 2;
    HANDLE out = CreateFileW(L"CONOUT$", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                             NULL, OPEN_EXISTING, 0, NULL);
    if (out == INVALID_HANDLE_VALUE) return 3;
    CONSOLE_SCREEN_BUFFER_INFO info;
    if (!GetConsoleScreenBufferInfo(out, &info)) { CloseHandle(out); return 3; }
    int cols = info.dwSize.X;
    int top = all ? 0 : info.srWindow.Top, bottom = info.srWindow.Bottom;
    if (cols <= 0 || bottom < top) { CloseHandle(out); return 3; }
    wchar_t wtitle[1024];
    DWORD tlen = GetConsoleTitleW(wtitle, 1024);
    if (tlen >= 1024) tlen = 1023;
    wtitle[tlen] = 0;

    /* The frame: header, then one line per row. 4 bytes per cell is the UTF-8 ceiling. */
    size_t cap = 256 + 4 * (size_t)tlen + (size_t)(bottom - top + 1) * ((size_t)cols * 3 + 1);
    char *frame = malloc(cap);
    CHAR_INFO *row = malloc(sizeof(CHAR_INFO) * (size_t)cols);
    if (!frame || !row) { CloseHandle(out); return 3; }
    size_t len = (size_t)snprintf(frame, 256, "# cols=%d rows=%d cursor=%d,%d viewport=%d-%d title=",
                                  cols, bottom - top + 1, info.dwCursorPosition.X, info.dwCursorPosition.Y, top, bottom);
    for (DWORD i = 0; i < tlen; i++) {
        wchar_t c = wtitle[i];
        if (c == L'\n' || c == L'\r') c = L' ';
        len += put_utf8(c, frame + len);
    }
    frame[len++] = '\n';
    COORD size = { (SHORT)cols, 1 }, origin = { 0, 0 };
    for (int y = top; y <= bottom; y++) {
        SMALL_RECT region = { 0, (SHORT)y, (SHORT)(cols - 1), (SHORT)y };
        if (!ReadConsoleOutputW(out, row, size, origin, &region)) { free(frame); free(row); CloseHandle(out); return 3; }
        int last = cols - 1;
        while (last >= 0 && (row[last].Char.UnicodeChar == L' ' || row[last].Char.UnicodeChar == 0)) last--;
        for (int x = 0; x <= last; x++) {
            wchar_t c = row[x].Char.UnicodeChar;
            if (c == 0) c = L' ';
            len += put_utf8(c, frame + len);
        }
        frame[len++] = '\n';
    }
    free(row);
    CloseHandle(out);

    /* Unchanged since the last frame? Then there is nothing to upload: exit 4. */
    FILE *f = fopen(path, "rb");
    if (f) {
        char *old = malloc(len + 1);
        size_t got = old ? fread(old, 1, len + 1, f) : 0;
        fclose(f);
        int same = old && got == len && memcmp(old, frame, len) == 0;
        free(old);
        if (same) { free(frame); return 4; }
    }
    char tmp[MAX_PATH + 8];
    snprintf(tmp, sizeof tmp, "%s.part", path);
    f = fopen(tmp, "wb");
    if (!f) { free(frame); return 3; }
    int ok = fwrite(frame, 1, len, f) == len;
    ok = (fclose(f) == 0) && ok;
    free(frame);
    if (!ok) return 3;
    if (!MoveFileExA(tmp, path, MOVEFILE_REPLACE_EXISTING)) return 3;
    return 0;
}

static int do_list(const char *path)
{
    FILE *f = fopen(path, "wb");
    if (!f) return 3;
    wchar_t title[1024];
    DWORD me = GetCurrentProcessId();
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) { fclose(f); return 3; }
    PROCESSENTRY32W pe;
    pe.dwSize = sizeof pe;
    if (Process32FirstW(snap, &pe)) {
        do {
            char line[2400];
            size_t len = (size_t)snprintf(line, 64, "%6lu  ", (unsigned long)pe.th32ProcessID);
            for (const wchar_t *c = pe.szExeFile; *c && len < 300; c++) len += put_utf8(*c, line + len);
            line[len++] = ' '; line[len++] = ' ';
            if (pe.th32ProcessID == me || pe.th32ProcessID == 0 || !AttachConsole(pe.th32ProcessID)) {
                line[len++] = '-';
            } else {
                DWORD n = GetConsoleTitleW(title, 1024);
                if (n >= 1024) n = 1023;
                for (DWORD i = 0; i < n && len < 2300; i++) len += put_utf8(title[i] == L'\n' || title[i] == L'\r' ? L' ' : title[i], line + len);
                FreeConsole();
            }
            line[len++] = '\n';
            fwrite(line, 1, len, f);
        } while (Process32NextW(snap, &pe));
    }
    CloseHandle(snap);
    return fclose(f) == 0 ? 0 : 3;
}

static int hexval(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* key <down/up pair> for one character (or a virtual key with a control state) */
static void key(INPUT_RECORD *rec, wchar_t ch, WORD vk, DWORD state)
{
    for (int down = 1; down >= 0; down--) {
        memset(rec, 0, sizeof *rec);
        rec->EventType = KEY_EVENT;
        rec->Event.KeyEvent.bKeyDown = down;
        rec->Event.KeyEvent.wRepeatCount = 1;
        rec->Event.KeyEvent.wVirtualKeyCode = vk;
        rec->Event.KeyEvent.wVirtualScanCode = (WORD)MapVirtualKeyW(vk, MAPVK_VK_TO_VSC);
        rec->Event.KeyEvent.uChar.UnicodeChar = ch;
        rec->Event.KeyEvent.dwControlKeyState = state;
        rec++;
    }
}

static int do_keys(const wchar_t *title, const wchar_t *text)
{
    size_t n = wcslen(text);
    INPUT_RECORD *recs = malloc(sizeof(INPUT_RECORD) * 2 * (n + 1));
    if (!recs) return 3;
    size_t count = 0;
    for (size_t i = 0; i < n; i++) {
        wchar_t c = text[i];
        if (c == L'{') {
            if (wcsncmp(text + i, L"{enter}", 7) == 0) { key(recs + count, L'\r', VK_RETURN, 0); count += 2; i += 6; continue; }
            if (wcsncmp(text + i, L"{esc}", 5) == 0) { key(recs + count, 0x1b, VK_ESCAPE, 0); count += 2; i += 4; continue; }
            if (wcsncmp(text + i, L"{tab}", 5) == 0) { key(recs + count, L'\t', VK_TAB, 0); count += 2; i += 4; continue; }
            if (wcsncmp(text + i, L"{ctrl-c}", 8) == 0) { key(recs + count, 3, 'C', LEFT_CTRL_PRESSED); count += 2; i += 7; continue; }
        }
        if (c == L'\n') { key(recs + count, L'\r', VK_RETURN, 0); count += 2; continue; }
        SHORT scan = VkKeyScanW(c);
        WORD vk = scan == -1 ? 0 : (WORD)(scan & 0xff);
        DWORD state = (scan != -1 && (scan & 0x100)) ? SHIFT_PRESSED : 0;
        key(recs + count, c, vk, state);
        count += 2;
    }
    if (!attach_by_title(title)) { free(recs); return 2; }
    HANDLE in = CreateFileW(L"CONIN$", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                            NULL, OPEN_EXISTING, 0, NULL);
    if (in == INVALID_HANDLE_VALUE) { free(recs); return 3; }
    DWORD written = 0;
    int ok = count == 0 || (WriteConsoleInputW(in, recs, (DWORD)count, &written) && written == count);
    CloseHandle(in);
    free(recs);
    return ok ? 0 : 3;
}

static wchar_t *widen(const char *s, UINT cp)
{
    int n = MultiByteToWideChar(cp, 0, s, -1, NULL, 0);
    if (n <= 0) return NULL;
    wchar_t *w = malloc(sizeof(wchar_t) * (size_t)n);
    if (w && MultiByteToWideChar(cp, 0, s, -1, w, n) <= 0) { free(w); return NULL; }
    return w;
}

int main(int argc, char **argv)
{
    static const char usage[] =
        "usage: pdt-console dump <title> <out.txt> [--all]\n"
        "       pdt-console keys <title> <text>        ({enter} {esc} {tab} {ctrl-c})\n"
        "       pdt-console keys <title> --hex <hex>   (the text as UTF-8 in hex)\n"
        "       pdt-console list <out.txt>\n";
    if (argc == 3 && strcmp(argv[1], "list") == 0) {
        SetConsoleCtrlHandler(NULL, TRUE);
        FreeConsole();
        return do_list(argv[2]);
    }
    if (argc >= 4 && strcmp(argv[1], "dump") == 0 && (argc == 4 || (argc == 5 && strcmp(argv[4], "--all") == 0))) {
        wchar_t *title = widen(argv[2], CP_ACP);
        if (!title) return 2;
        SetConsoleCtrlHandler(NULL, TRUE);
        FreeConsole();
        return do_dump(title, argv[3], argc == 5);
    }
    if (argc >= 4 && strcmp(argv[1], "keys") == 0) {
        wchar_t *title = widen(argv[2], CP_ACP), *text = NULL;
        if (!title) return 2;
        if (strcmp(argv[3], "--hex") == 0) {
            if (argc != 5) { fputs(usage, stderr); return 2; }
            size_t hl = strlen(argv[4]);
            if (hl % 2) { fputs("pdt-console: --hex wants an even number of hex digits\n", stderr); return 2; }
            char *bytes = malloc(hl / 2 + 1);
            if (!bytes) return 3;
            for (size_t i = 0; i < hl; i += 2) {
                int hi = hexval(argv[4][i]), lo = hexval(argv[4][i + 1]);
                if (hi < 0 || lo < 0) { fputs("pdt-console: --hex wants hex digits only\n", stderr); free(bytes); return 2; }
                bytes[i / 2] = (char)(hi * 16 + lo);
            }
            bytes[hl / 2] = 0;
            text = widen(bytes, CP_UTF8);
            free(bytes);
        } else if (argc == 4) {
            text = widen(argv[3], CP_ACP);
        } else { fputs(usage, stderr); return 2; }
        if (!text) return 2;
        SetConsoleCtrlHandler(NULL, TRUE);
        FreeConsole();
        return do_keys(title, text);
    }
    fputs(usage, stderr);
    return 2;
}

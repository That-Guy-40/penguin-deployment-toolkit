/* pdt-screen.c - write the current screen to a BMP file.  pdt-screen <out.bmp>
 *
 * For machines without a usable display: the task sequence runs this every few
 * seconds and uploads the file; bin/screen on the server shows it. Plain Win32
 * (GDI BitBlt of the desktop), no runtime beyond what WinPE has, no network of
 * its own: the upload is curl's job. Built on Linux with mingw-w64 by
 * bin/build-tools; the hash of the result is recorded like every other tool.
 *
 * Exit codes: 0 written, 1 usage, 2 no desktop (nothing to capture), 3 I/O.
 */
#include <windows.h>
#include <stdio.h>

int main(int argc, char **argv)
{
    if (argc != 2) { fputs("usage: pdt-screen <out.bmp>\n", stderr); return 1; }
    HDC screen = GetDC(NULL);
    if (!screen) return 2;
    int w = GetSystemMetrics(SM_CXVIRTUALSCREEN), h = GetSystemMetrics(SM_CYVIRTUALSCREEN);
    int x = GetSystemMetrics(SM_XVIRTUALSCREEN), y = GetSystemMetrics(SM_YVIRTUALSCREEN);
    if (w <= 0 || h <= 0) { ReleaseDC(NULL, screen); return 2; }

    BITMAPINFO bi = {0};
    bi.bmiHeader.biSize = sizeof(bi.bmiHeader);
    bi.bmiHeader.biWidth = w;
    bi.bmiHeader.biHeight = -h;            /* top-down */
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 24;
    bi.bmiHeader.biCompression = BI_RGB;
    void *bits = NULL;
    HDC mem = CreateCompatibleDC(screen);
    HBITMAP bmp = CreateDIBSection(mem, &bi, DIB_RGB_COLORS, &bits, NULL, 0);
    if (!mem || !bmp || !bits) { ReleaseDC(NULL, screen); return 3; }
    HGDIOBJ old = SelectObject(mem, bmp);
    if (!BitBlt(mem, 0, 0, w, h, screen, x, y, SRCCOPY | CAPTUREBLT)) return 3;
    GdiFlush();

    DWORD stride = ((w * 3 + 3) & ~3), size = stride * h;
    BITMAPFILEHEADER fh = {0};
    fh.bfType = 0x4D42;
    fh.bfOffBits = sizeof(fh) + sizeof(bi.bmiHeader);
    fh.bfSize = fh.bfOffBits + size;
    bi.bmiHeader.biSizeImage = size;

    /* Write to a temp name and rename, so the uploader never sends a half file. */
    char tmp[MAX_PATH + 8];
    snprintf(tmp, sizeof tmp, "%s.part", argv[1]);
    FILE *f = fopen(tmp, "wb");
    if (!f) return 3;
    int ok = fwrite(&fh, sizeof fh, 1, f) == 1 && fwrite(&bi.bmiHeader, sizeof bi.bmiHeader, 1, f) == 1
          && fwrite(bits, 1, size, f) == size;
    fclose(f);
    if (!ok) return 3;
    DeleteFileA(argv[1]);
    if (!MoveFileA(tmp, argv[1])) return 3;

    SelectObject(mem, old);
    DeleteObject(bmp);
    DeleteDC(mem);
    ReleaseDC(NULL, screen);
    return 0;
}

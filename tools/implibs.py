#!/usr/bin/env python3
"""Generate import libraries (build/<dll>.lib) for every Win32 function the asm uses.

There is no Windows SDK on the Linux build host, so we describe the DLL exports we
need here and let `lld-link /lib /def:` turn each list into an import library.
A function missing from this table shows up as an undefined symbol at link time.
"""
import os, subprocess, sys

IMPORTS = {
    "kernel32": """ExitProcess GetProcessHeap HeapAlloc HeapFree HeapReAlloc GetCommandLineW GetModuleHandleW
        MultiByteToWideChar WideCharToMultiByte lstrlenW lstrcpyW lstrcmpW lstrcmpiW CreateFileW WriteFile ReadFile
        CloseHandle GetLastError CreateThread GetCurrentThreadId Sleep GetTickCount64 GetEnvironmentVariableW
        SetEnvironmentVariableW GetFileSizeEx CreateDirectoryW GetStdHandle LocalFree GetModuleFileNameW
        QueryPerformanceCounter QueryPerformanceFrequency FlushFileBuffers GetFileAttributesW DeleteFileW
        CreateEventW SetEvent WaitForSingleObject GetSystemTimeAsFileTime GetLocalTime SetUnhandledExceptionFilter MoveFileExW lstrcatW CreateMutexW GlobalAlloc GlobalLock GlobalUnlock GlobalFree
        CreateJobObjectW SetInformationJobObject AssignProcessToJobObject TerminateProcess GetExitCodeProcess ResumeThread
        ExpandEnvironmentStringsW CreateProcessW""",
    "user32": """RegisterClassExW CreateWindowExW DefWindowProcW ShowWindow UpdateWindow GetMessageW TranslateMessage
        DispatchMessageW PostQuitMessage PostMessageW PostThreadMessageW SendMessageW BeginPaint EndPaint InvalidateRect
        GetClientRect GetWindowRect LoadCursorW SetCursor GetDC ReleaseDC SetTimer KillTimer MoveWindow DestroyWindow
        SetWindowTextW GetWindowTextW SetFocus GetFocus GetKeyState AdjustWindowRectEx TrackMouseEvent SetProcessDPIAware
        GetDpiForWindow GetDpiForSystem GetSystemMetrics ScreenToClient ClientToScreen SetCapture ReleaseCapture MessageBoxW
        PeekMessageW FindWindowW SetForegroundWindow OpenClipboard EmptyClipboard SetClipboardData CloseClipboard GetWindowLongPtrW SetWindowLongPtrW IsWindow SetWindowPos EnableWindow CallWindowProcW""",
    "gdi32": """CreateCompatibleDC CreateDIBSection SelectObject DeleteObject DeleteDC BitBlt GdiFlush SetBkColor SetTextColor
        CreateSolidBrush CreateFontW CreateFontIndirectW""",
    "gdiplus": """GdiplusStartup GdiplusShutdown GdipCreateFromHDC GdipDeleteGraphics GdipSetSmoothingMode
        GdipSetTextRenderingHint GdipSetInterpolationMode GdipCreateSolidFill GdipSetSolidFillColor GdipDeleteBrush
        GdipFillRectangleI GdipFillEllipseI GdipFillPath GdipFillPolygonI GdipCreatePath GdipDeletePath GdipAddPathArcI
        GdipClosePathFigure GdipStartPathFigure GdipCreatePen1 GdipDeletePen GdipDrawLineI GdipDrawEllipseI GdipDrawArcI
        GdipDrawPath GdipSetPenStartCap GdipSetPenEndCap GdipCreateFontFamilyFromName GdipDeleteFontFamily
        GdipGetGenericFontFamilySansSerif GdipCreateFont GdipDeleteFont GdipCreateStringFormat GdipDeleteStringFormat
        GdipSetStringFormatAlign GdipSetStringFormatLineAlign GdipSetStringFormatTrimming GdipSetStringFormatFlags
        GdipDrawString GdipMeasureString GdipCreateBitmapFromStream GdipCreateBitmapFromScan0 GdipDisposeImage
        GdipDrawImageRectI GdipGetImageWidth GdipGetImageHeight GdipGetImageGraphicsContext GdipBitmapGetPixel
        GdipSetClipRectI GdipResetClip GdipGraphicsClear GdipFillRectangle GdipSetCompositingQuality
        GdipSetPixelOffsetMode GdipCreateLineBrushI GdipDeleteBrush GdipSetLineLinearBlend GdipFillPie GdipFillPieI
        GdipSetClipPath GdipSetLineColors GdipSetPenLineJoin GdipSetPenWidth GdipSetCompositingMode""",
    "shell32": """CommandLineToArgvW ShellExecuteW SHGetFolderPathW SHCreateDirectoryExW""",
    "shlwapi": """SHCreateMemStream""",
    "winhttp": """WinHttpOpen WinHttpConnect WinHttpOpenRequest WinHttpSendRequest WinHttpReceiveResponse
        WinHttpQueryHeaders WinHttpQueryDataAvailable WinHttpReadData WinHttpCloseHandle WinHttpAddRequestHeaders
        WinHttpSetTimeouts WinHttpCrackUrl WinHttpSetOption""",
    "ws2_32": """WSAStartup WSACleanup socket bind listen accept recv send closesocket htons htonl inet_addr
        setsockopt WSAGetLastError getsockname""",
    "bcrypt": """BCryptGenRandom BCryptOpenAlgorithmProvider BCryptCloseAlgorithmProvider BCryptHash""",
    "crypt32": """CryptProtectData CryptUnprotectData""",
    "ole32": """CoInitializeEx CoUninitialize CoTaskMemFree CoCreateInstance""",
    "ntdll": """RtlGetVersion""",
    "advapi32": """RegOpenKeyExW RegQueryValueExW RegCloseKey""",
}

def main(out):
    os.makedirs(out, exist_ok=True)
    tables = dict(IMPORTS)
    for dll, names in tables.items():
        fn = sorted(set(names.split()))
        deff = os.path.join(out, dll + ".def")
        with open(deff, "w") as f:
            f.write("LIBRARY %s.dll\nEXPORTS\n" % dll)
            f.write("\n".join(fn) + "\n")
        subprocess.check_call(["lld-link", "/lib", "/def:" + deff, "/out:" + os.path.join(out, dll + ".lib"),
                               "/machine:x64"], stdout=subprocess.DEVNULL)
    print(" ".join(sorted(tables)))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "build")

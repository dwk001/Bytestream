#!/usr/bin/env python3
"""Builds build/bytestream.exe.  Works on Linux (cross-assembling) and on Windows.

    python tools/build.py

Needs nasm, lld-link and llvm-readobj on PATH (override with NASM, LLD_LINK, LLVM_READOBJ).
Steps: generate import libraries -> assemble -> reject 32-bit absolute relocations -> link (+ linker map).
"""
import os, shutil, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, "build")
LIBS = "kernel32 user32 gdi32 gdiplus shell32 shlwapi winhttp ws2_32 bcrypt crypt32 ole32 ntdll advapi32".split()


def tool(env, *names):
    if os.environ.get(env):
        return os.environ[env]
    for n in names:
        p = shutil.which(n)
        if p:
            return p
    sys.exit("error: none of %s found on PATH (set %s)" % ("/".join(names), env))


def run(cmd, **kw):
    print(" ".join(os.path.relpath(c, ROOT) if os.path.isabs(c) and c.startswith(ROOT) else c for c in cmd))
    r = subprocess.run(cmd, cwd=ROOT, **kw)
    if r.returncode:
        sys.exit(r.returncode)
    return r


def git_id():
    try:
        h = subprocess.run(["git", "rev-parse", "--short", "HEAD"], capture_output=True, text=True, cwd=ROOT).stdout.strip()
        dirty = subprocess.run(["git", "status", "--porcelain"], capture_output=True, text=True, cwd=ROOT).stdout.strip()
        return (h or "dev") + ("+" if dirty and h else "")
    except OSError:
        return "dev"


def main():
    nasm = tool("NASM", "nasm")
    lld = tool("LLD_LINK", "lld-link")
    readobj = tool("LLVM_READOBJ", "llvm-readobj")
    os.makedirs(BUILD, exist_ok=True)

    sys.path.insert(0, os.path.join(ROOT, "tools"))
    import implibs
    implibs.main(BUILD)

    obj = os.path.join(BUILD, "main.obj")
    build_id = os.environ.get("BUILD_ID") or git_id()
    run([nasm, "-fwin64", "-Isrc/", '-DBUILD_ID="%s"' % build_id, "src/main.asm", "-o", obj])

    # [symbol+register] addressing assembles to a 32-bit absolute address, which faults at a 64-bit image base.
    rel = subprocess.run([readobj, "--relocations", obj], capture_output=True, text=True, cwd=ROOT).stdout
    bad = [l for l in rel.splitlines() if "IMAGE_REL_AMD64_ADDR32 " in l]
    if bad:
        print("error: absolute 32-bit relocation in main.obj (use `lea r, [sym]` and index from the register):")
        print("\n".join(bad[:20]))
        sys.exit(1)

    exe = os.path.join(BUILD, "bytestream.exe")
    run([lld, "/nologo", "/subsystem:windows", "/entry:start", "/manifest:embed",
         "/manifestinput:src/bytestream.manifest", "/map:" + os.path.join(BUILD, "bytestream.map"),
         "/out:" + exe, obj] + [os.path.join(BUILD, l + ".lib") for l in LIBS])
    print("built", os.path.relpath(exe, ROOT), os.path.getsize(exe), "bytes")


if __name__ == "__main__":
    main()

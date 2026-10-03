#!/usr/bin/env python3
"""指定したプロセスが終わるまで Mac を起こしておく（local_update.sh が使う）。

蓋を閉じてスリープしている Mac も、電源アダプタにつないでいれば Power Nap で
約 16 分ごとに 40 秒ほど目を覚まし（DarkWake）、そのとき launchd が予定を実行する。
取り込みが 40 秒を超えると途中で眠ってしまうので、実行中はスリープを止めておく。

使う電源アサーションは NetworkClientActive。IOPMLib.h に「電源アダプタ接続時は
DarkWake でも通常の起動中でもシステムを起こしておく」と明記されている種類のため。
caffeinate が作るものはこの用途の保証がない:
  - PreventUserIdleSystemSleep（-i）: 「DarkWake 中は効果なし」「蓋を閉じると眠りうる」と明記
  - PreventSystemSleep（-s）: IOPMLib.h で廃止扱い

    python3 scripts/stay_awake.py <PID>

PID のプロセスが終わったら解除して終わる。万一の取り残しを防ぐため、最長 30 分で
必ず解除する。このプロセス自体が落ちても、アサーションは OS が自動で外す。
"""

import ctypes
import os
import sys
import time

MAX_SECONDS = 30 * 60
# pmset -g assertions に出る名前。日本語は空欄で表示されるため ASCII にしてある
NAME = "loto-update: lottery data import"
KCF_UTF8 = 0x08000100           # kCFStringEncodingUTF8
LEVEL_ON = 255                  # kIOPMAssertionLevelOn


def main() -> int:
    if len(sys.argv) != 2 or not sys.argv[1].isdigit():
        print("使い方: stay_awake.py <PID>", file=sys.stderr)
        return 2
    pid = int(sys.argv[1])

    cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    iokit = ctypes.CDLL("/System/Library/Frameworks/IOKit.framework/IOKit")
    cf.CFStringCreateWithCString.restype = ctypes.c_void_p
    cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
    cf.CFRelease.argtypes = [ctypes.c_void_p]
    iokit.IOPMAssertionCreateWithName.restype = ctypes.c_int
    iokit.IOPMAssertionCreateWithName.argtypes = [
        ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)]
    iokit.IOPMAssertionRelease.restype = ctypes.c_int
    iokit.IOPMAssertionRelease.argtypes = [ctypes.c_uint32]

    kind = cf.CFStringCreateWithCString(None, b"NetworkClientActive", KCF_UTF8)
    name = cf.CFStringCreateWithCString(None, NAME.encode(), KCF_UTF8)
    aid = ctypes.c_uint32(0)
    rc = iokit.IOPMAssertionCreateWithName(kind, LEVEL_ON, name, ctypes.byref(aid))
    cf.CFRelease(kind)
    cf.CFRelease(name)
    if rc != 0:
        print(f"stay_awake: スリープ防止を設定できませんでした (IOReturn 0x{rc & 0xffffffff:08x})",
              file=sys.stderr)
        return 1

    try:
        deadline = time.monotonic() + MAX_SECONDS
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                break                   # 見守っていたプロセスが終わった
            except PermissionError:
                pass                    # 別ユーザーのプロセスとして生きている
            time.sleep(1)
    finally:
        iokit.IOPMAssertionRelease(aid)
    return 0


if __name__ == "__main__":
    sys.exit(main())

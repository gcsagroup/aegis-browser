"""检查构建空间：macOS区分重要用途可用容量与已经空闲的容量。"""
import argparse
import ctypes as C
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

GIB = 1024 ** 3


def allocated_bytes(path):
    """统计实际分配；临时文件消失时重读，权限错误或持续失败必须中止。"""
    path = Path(path).resolve(strict=True)
    for _ in range(3):
        result = subprocess.run(['du', '-sk', str(path)], capture_output=True,
                                text=True, env={**os.environ, 'LC_ALL': 'C'})
        if result.returncode == 0:
            value = int(result.stdout.split()[0]) * 1024
            if value < 0:
                raise ValueError('目录分配容量无效')
            return value
        errors = result.stderr.strip().splitlines()
        if not errors or not all(line.endswith(': No such file or directory') for line in errors):
            break
    raise OSError('目录容量无法可靠读取：' + result.stderr.strip())


def important_capacity(path):
    """只读CoreFoundation属性，不编译程序、不请求清理、不缓存容量。"""
    cf = C.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    cf.CFURLCreateFromFileSystemRepresentation.argtypes = [C.c_void_p, C.c_char_p, C.c_long, C.c_bool]
    cf.CFURLCreateFromFileSystemRepresentation.restype = C.c_void_p
    cf.CFURLCopyResourcePropertyForKey.argtypes = [C.c_void_p, C.c_void_p, C.POINTER(C.c_void_p), C.POINTER(C.c_void_p)]
    cf.CFURLCopyResourcePropertyForKey.restype = C.c_bool
    cf.CFGetTypeID.argtypes = [C.c_void_p]
    cf.CFGetTypeID.restype = C.c_ulong
    cf.CFNumberGetTypeID.restype = C.c_ulong
    cf.CFNumberGetValue.argtypes = [C.c_void_p, C.c_long, C.c_void_p]
    cf.CFNumberGetValue.restype = C.c_bool
    cf.CFRelease.argtypes = [C.c_void_p]
    raw = bytes(path)
    url = cf.CFURLCreateFromFileSystemRepresentation(None, raw, len(raw), path.is_dir())
    value, error = C.c_void_p(), C.c_void_p()
    if not url:
        raise OSError('无法创建卷查询URL')
    try:
        key = C.c_void_p.in_dll(cf, 'kCFURLVolumeAvailableCapacityForImportantUsageKey')
        if not cf.CFURLCopyResourcePropertyForKey(url, key, C.byref(value), C.byref(error)) or not value:
            raise OSError('系统未返回重要用途可用容量')
        number = C.c_int64()
        # kCFNumberSInt64Type=4；必须是数值且能无损转换。
        if cf.CFGetTypeID(value) != cf.CFNumberGetTypeID() or not cf.CFNumberGetValue(value, 4, C.byref(number)):
            raise OSError('容量属性类型无效')
        return number.value
    finally:
        for item in (value, error, url):
            if item:
                cf.CFRelease(item)


def evaluate(total, free, important=None):
    if not 0 <= free <= total:
        raise ValueError('直接空闲容量无效')
    if important is not None and not 0 <= important <= total:
        raise ValueError('重要用途可用容量无效')
    available = free if important is None else important
    reasons = []
    if available < 30 * GIB:
        reasons.append('系统可用容量低于30GiB')
    if free < 8 * GIB:
        reasons.append('直接空闲低于8GiB，不能等待系统回收')
    return {'totalBytes': total, 'freeBytes': free,
            'importantAvailableBytes': important, 'availableBytes': available,
            'capacitySource': 'important_usage' if important is not None else 'free_only',
            'minimumAvailableBytes': 30 * GIB, 'minimumFreeBytes': 8 * GIB,
            'allowed': not reasons, 'reasons': reasons}


def snapshot(path):
    path = Path(path).resolve(strict=True)
    usage = shutil.disk_usage(path)
    important, error = None, None
    if sys.platform == 'darwin':
        try:
            important = important_capacity(path)
            if not 0 <= important <= usage.total:
                raise ValueError('系统容量超出卷范围')
        except (OSError, ValueError, AttributeError) as exc:
            important, error = None, str(exc)
    result = evaluate(usage.total, usage.free, important)
    result.update(path=str(path), queryError=error)
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('path', type=Path)
    args = parser.parse_args()
    try:
        result = snapshot(args.path)
    except (OSError, ValueError) as exc:
        parser.exit(2, f'容量查询失败：{exc}\n')
    print(json.dumps(result, ensure_ascii=False, indent=2))
    sys.exit(0 if result['allowed'] else 1)

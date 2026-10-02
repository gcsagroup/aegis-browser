#!/usr/bin/env python3
"""读取固定 macOS 验收 App 的进程资源；不启停程序或修改配置。"""
import argparse
import datetime
import json
import math
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import time

APP = Path('/Users/lazy/Applications/GCSA Aegis Test.app')
EXECUTABLE = APP / 'Contents/MacOS/GCSA Aegis'


def cpu_seconds(value):
    match = re.fullmatch(r'(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+(?:\.\d+)?)', value)
    if not match:
        raise ValueError('无法解析 ps CPU 时间')
    days, hours, minutes, seconds = match.groups()
    if float(seconds) >= 60 or (hours is not None and int(minutes) >= 60):
        raise ValueError('ps CPU 时间范围错误')
    return int(days or 0) * 86400 + int(hours or 0) * 3600 + int(minutes) * 60 + float(seconds)


def parse_processes(output):
    processes = {}
    for line in output.splitlines():
        if not line.strip():
            continue
        fields = line.split()
        if len(fields) != 4:
            raise ValueError('ps 进程字段数量错误')
        pid, parent, elapsed, rss = fields
        pid, parent, rss = int(pid), int(parent), int(rss)
        if pid <= 0 or parent < 0 or rss < 0 or pid in processes:
            raise ValueError('ps 进程身份或内存错误')
        processes[pid] = {'parentPid': parent, 'cpuSeconds': cpu_seconds(elapsed), 'rssKiB': rss}
    return processes


def descendants(processes, root_pid):
    if root_pid not in processes:
        raise ValueError('固定 App 主进程已退出，不能当作零用量')
    selected = {root_pid}
    while True:
        next_selected = selected | {pid for pid, value in processes.items()
                                    if value['parentPid'] in selected}
        if next_selected == selected:
            return {pid: processes[pid] for pid in sorted(selected)}
        selected = next_selected


def compare_samples(previous, current):
    before, after = previous['processes'], current['processes']
    elapsed = current['monotonicSeconds'] - previous['monotonicSeconds']
    if elapsed <= 0:
        raise ValueError('采样时间必须递增')
    delta = sum(value['cpuSeconds'] for value in after.values()) - sum(
        value['cpuSeconds'] for value in before.values())
    # 退出进程末段CPU不可回读；进程集合改变的区间不能贡献准确CPU增量。
    valid = before.keys() == after.keys() and all(
        after[pid]['cpuSeconds'] >= before[pid]['cpuSeconds'] for pid in before)
    return {'elapsedSeconds': elapsed, 'cohortStable': valid,
            'cpuPercentOneCore': max(0, delta / elapsed * 100) if valid else None,
            'summedRssKiB': sum(value['rssKiB'] for value in after.values()),
            'processCount': len(after)}


def summarize(intervals):
    stable = [entry for entry in intervals if entry['cohortStable']]
    values = sorted(entry['cpuPercentOneCore'] for entry in stable)
    elapsed = sum(entry['elapsedSeconds'] for entry in stable)
    return {'intervals': len(intervals), 'stableIntervals': len(stable),
            'cpuMeanPercentOneCore': sum(entry['cpuPercentOneCore'] * entry['elapsedSeconds']
                                        for entry in stable) / elapsed if elapsed else None,
            'cpuP95PercentOneCore': values[math.ceil(len(values) * .95) - 1] if values else None,
            'peakSummedRssKiB': max((entry['summedRssKiB'] for entry in intervals), default=None)}


def command(*args):
    return subprocess.check_output(args, text=True, timeout=10)


def verify_app(pid):
    actual = command('/bin/ps', '-ww', '-p', str(pid), '-o', 'comm=').strip()
    if actual != str(EXECUTABLE):
        raise ValueError('PID不属于固定验收App，拒绝采样')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--samples', type=int, default=31)
    parser.add_argument('--interval', type=float, default=1)
    parser.add_argument('--conditions', required=True, help='明确记录编译、模型调用等并行负载')
    args = parser.parse_args()
    if sys.platform != 'darwin' or args.pid <= 0 or not 2 <= args.samples <= 301 or not .1 <= args.interval <= 10:
        raise ValueError('仅支持macOS，PID为正数，样本2–301，间隔0.1–10秒')
    if not args.conditions.strip():
        raise ValueError('必须记录采样条件')
    verify_app(args.pid)
    with (APP / 'Contents/Info.plist').open('rb') as file:
        info = plistlib.load(file)
    samples = []
    started = time.monotonic()
    for index in range(args.samples):
        target = started + index * args.interval
        time.sleep(max(0, target - time.monotonic()))
        processes = parse_processes(command('/bin/ps', '-axo', 'pid=,ppid=,time=,rss='))
        samples.append({'monotonicSeconds': time.monotonic(),
                        'processes': descendants(processes, args.pid)})
    verify_app(args.pid)
    intervals = [compare_samples(before, after) for before, after in zip(samples, samples[1:])]
    print(json.dumps({'schemaVersion': 1, 'capturedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                      'app': str(APP), 'rootPid': args.pid, 'bundleId': info.get('CFBundleIdentifier'),
                      'chromiumVersion': info.get('CFBundleShortVersionString'),
                      'conditions': args.conditions, 'summary': summarize(intervals),
                      'samples': samples, 'intervals': intervals,
                      'qualification': '进程观察，不自动认定空闲或性能通过；CPU百分比以一个核心为100%，RSS相加可能重复计算共享页。进程变动区间排除CPU统计，不能当作零用量。'},
                     ensure_ascii=False, indent=2))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f'资源采样失败：{error}', file=sys.stderr)
        sys.exit(1)

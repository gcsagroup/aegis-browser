"""停止本次构建的完整进程树，包括链接封装另建的进程组。"""
import os
import signal
import subprocess
import time


def processes():
    rows = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,pgid=,stat='], text=True)
    return [(int(pid), int(parent), int(group), state)
            for pid, parent, group, state in (row.split() for row in rows.splitlines())]


def signal_group(group, sig):
    try:
        os.killpg(group, sig)
    except ProcessLookupError:
        pass
    except PermissionError:
        # macOS对仅剩僵尸或已消失的进程组也可能返回EPERM；活进程的拒绝不能忽略。
        if any(g == group and not state.startswith('Z')
               for _, _, g, state in processes()):
            raise


def stop_process_tree(pid, timeout=15):
    """仅接收以start_new_session创建的直接子进程；冻结后核对组成员再停止。"""
    rows = processes()
    root = next((row for row in rows if row[0] == pid), None)
    if root is None or root[3].startswith('Z'):
        return {'groups': [], 'forcedGroups': []}
    if root[1] != os.getpid() or root[2] != pid or pid == os.getpgrp():
        raise ValueError('停止目标必须是本进程创建的独立会话子进程')
    groups = set()
    completed = False
    os.kill(pid, signal.SIGSTOP)
    try:
        # 先冻结调度器；再逐轮冻结它已有的子组，收敛冻结期间刚创建的后代。
        for _ in range(16):
            rows = processes()
            owned = {pid} | {p for p, _, g, _ in rows if g in groups}
            while True:
                children = {p for p, parent, _, _ in rows if parent in owned} - owned
                if not children:
                    break
                owned |= children
            found = {g for p, _, g, _ in rows if p in owned}
            if os.getpgrp() in found or any(p not in owned for p, _, g, _ in rows if g in found):
                raise ValueError('构建进程组混入其他进程，拒绝整组停止')
            new_groups = found - groups
            if not new_groups:
                break
            for group in new_groups:
                signal_group(group, signal.SIGSTOP)
            groups |= new_groups
        else:
            raise RuntimeError('构建进程树未能稳定冻结')
        for group in groups:
            signal_group(group, signal.SIGTERM)
            signal_group(group, signal.SIGCONT)
        deadline = time.monotonic() + timeout
        while True:
            live = {g for _, _, g, state in processes()
                    if g in groups and not state.startswith('Z')}
            if not live or time.monotonic() >= deadline:
                break
            time.sleep(0.1)
        for group in live:
            signal_group(group, signal.SIGKILL)
        completed = True
        return {'groups': sorted(groups), 'forcedGroups': sorted(live)}
    finally:
        if not completed:
            for group in groups:
                signal_group(group, signal.SIGCONT)
            try:
                os.kill(pid, signal.SIGCONT)
            except ProcessLookupError:
                pass

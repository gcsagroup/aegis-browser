"""把桌面补丁和工作区 overlay 合成为 Windows 编译输入。Git 的实际索引、分支及提交保持由开发者管理。"""

import hashlib
import json
import os
from pathlib import Path, PureWindowsPath
import re
import stat
# 同步使用本机 Git 的二进制输入输出，不拼接 shell 命令。
import subprocess  # nosec B404
import tempfile

from chromium_access_gtests import command_argv, series, tool, write_json

# 只识别同一路径、完整 blob ID 的 Git 补丁头；缩写、改名和 hunk 内容不作为旧版本凭据。
PATCH_VERSION = re.compile(
    rb"^diff --git a/([^\n]+) b/\1\n(?:(?:new file|deleted file|old|new) mode [0-7]+\n)*"
    rb"index ([0-9a-f]{40})\.\.([0-9a-f]{40})(?: [0-7]+)?$", re.MULTILINE)


def git(repo, *args, data=None, env=None):
    """以独立参数传递 Git 路径和二进制输入，保留 NUL 分隔的文件名及 blob 原始字节。"""
    command = command_argv([
        tool("git", env), "--literal-pathspecs", "-c", "core.autocrlf=false", "-C", str(repo), *args,
    ])
    # Git 从开发者工具链解析为绝对路径；路径参数按字面传递，补丁字节只进入标准输入。
    # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit.dangerous-subprocess-use-audit, python.lang.security.audit.dangerous-subprocess-use-tainted-env-args.dangerous-subprocess-use-tainted-env-args
    return subprocess.check_output(command, input=data, env=env, shell=False)  # nosec B603


def names(data):
    return [item.decode("utf-8") for item in data.split(b"\0") if item]


def checked_path(root, name):
    """同步只允许普通源码文件，拒绝 Git 元数据、输出目录、链接、目录联接和 Windows 路径别名。"""
    path = PureWindowsPath(name)
    if (not name or path.drive or path.root or "\\" in name or
            any(part.lower() == ".git" or part in {"", ".", ".."} or ":" in part
                or part.endswith((".", " ")) or PureWindowsPath(part).is_reserved()
                for part in name.split("/")) or path.parts[0].lower() == "out"):
        raise ValueError(f"不安全的源码路径：{name}")
    target = root
    for part in name.split("/"):
        target /= part
        try:
            info = target.lstat()
        except FileNotFoundError:
            continue
        if (stat.S_ISLNK(info.st_mode) or
                getattr(info, "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT):
            raise ValueError(f"源码路径经过链接：{target}")
    return target


def blob(data):
    """Git blob ID 只用于开发文件相等性比较，写入时始终保留原始字节。"""
    # 与现有 Git 对象格式兼容，不用于签名、凭据或远程来源认证。
    # nosemgrep: python.lang.security.insecure-hash-algorithms.insecure-hash-algorithm-sha1
    return hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data,
                        usedforsecurity=False).hexdigest()


def identities(path):
    """同时识别原始 blob 和 Git for Windows 签出的 CRLF 文本。"""
    if not path.exists():
        return (None,)
    data = path.read_bytes()
    raw = blob(data)
    if b"\0" not in data[:8000] and b"\r\n" in data:
        return raw, blob(data.replace(b"\r\n", b"\n"))
    return (raw,)


class PatchTree:
    """在私有索引重放固定基线和有序补丁；按补丁内容复用对象，以便日常启动只处理变化文件。"""

    def __init__(self, src, base, patches, cache):
        self.src = src
        if git(src, "rev-parse", "--show-toplevel").decode().strip().replace("\\", "/").casefold() != src.as_posix().casefold():
            raise ValueError(f"缺少独立 Git 源码树：{src}")
        git(src, "merge-base", "--is-ancestor", base, "HEAD")
        cache.mkdir(parents=True, exist_ok=True)
        objects = Path(git(src, "rev-parse", "--path-format=absolute", "--git-path", "objects").decode().strip())
        private = cache / "objects"
        private.mkdir(exist_ok=True)
        self.env = dict(os.environ, GIT_OBJECT_DIRECTORY=str(private),
                        GIT_ALTERNATE_OBJECT_DIRECTORIES=str(objects), GIT_INDEX_FILE=str(cache / "index"),
                        GIT_NO_LAZY_FETCH="1", GIT_OPTIONAL_LOCKS="0")
        digest = hashlib.sha256(base.encode())
        inputs = []
        self.versions = {}
        for name in series(patches):
            data = (patches / name).read_bytes().replace(b"\r\n", b"\n")
            digest.update(hashlib.sha256(data).digest())
            inputs.append(data)
            for match in PATCH_VERSION.finditer(data):
                path, before, after = (part.decode("utf-8") for part in match.groups())
                self.versions.setdefault(path, set()).update((before, after))
        record = cache / "patch-tree.json"
        saved = json.loads(record.read_text("utf-8")) if record.exists() else {}
        if saved.get("key") == digest.hexdigest():
            tree = saved["tree"]
        else:
            git(src, "read-tree", base, env=self.env)
            # 同一组补丁依次作用于私有索引，避免在大型 Chromium 索引上逐个启动 Git。
            with tempfile.TemporaryDirectory(dir=cache) as directory:
                files = []
                for index, data in enumerate(inputs):
                    patch = Path(directory) / f"{index}.patch"
                    patch.write_bytes(data)
                    files.append(str(patch))
                for offset in range(0, len(files), 24):
                    git(src, "apply", "--cached", "--binary", "--whitespace=nowarn",
                        *files[offset:offset + 24], env=self.env)
            tree = git(src, "write-tree", env=self.env).decode().strip()
            write_json(record, {"key": digest.hexdigest(), "tree": tree})
        self.base = base
        self.desired = {}
        rows = names(git(src, "diff-tree", "-r", "-z", "--no-renames", "--no-abbrev", base, tree, env=self.env))
        for header, name in zip(rows[::2], rows[1::2]):
            before, after, _, oid, _ = header.lstrip(":").split()
            if (before, after, name) == ("160000", "160000", "v8"):
                continue  # V8 使用自己的固定基线、补丁及独立工作树。
            if {before, after} - {"100644", "100755", "000000"}:
                raise ValueError(f"补丁包含不支持的源码类型：{name}")
            self.desired[name] = None if after == "000000" else oid
        # 文件可能在早期补丁新增、在后续补丁删除，此时最终 diff 没有该路径。
        # 首次从中间版本启动也应清理这类已撤回的文件，或还原被补丁改回的基线内容。
        reverted = self.versions.keys() - self.desired.keys() - {"v8"}
        originals = self.entries(base, reverted)
        self.desired.update((name, originals.get(name)) for name in reverted)

    def entries(self, tree, paths):
        """只读取本次接管路径的历史值，不触碰构建树里其他依赖及本地文件。"""
        result = {}
        paths = sorted(paths)
        for offset in range(0, len(paths), 48):
            rows = names(git(self.src, "ls-tree", "-z", tree, "--", *paths[offset:offset + 48], env=self.env))
            for row in rows:
                meta, name = row.split("\t", 1)
                mode, _, oid = meta.split()
                if mode not in {"100644", "100755"}:
                    raise ValueError(f"目标不是普通源码文件：{name}")
                result[name] = oid
        return result


def overlay_files(project):
    """纳入已提交、已暂存、未暂存及未忽略的新文件；已跟踪文件的本地删除也要同步。"""
    prefix = "apps/browser/overlay/"
    tracked = git(project, "ls-tree", "-rz", "--name-only", "HEAD", "--", prefix)
    working = git(project, "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", prefix)
    overlay = project / prefix
    result = {}
    for entry in set(names(tracked) + names(working)):
        name = entry[len(prefix):]
        file = checked_path(overlay, name)
        result[name] = file.read_bytes() if file.exists() else None
    return result


def plan(tree, overlay, previous, pending):
    """先比对整组输入。已手改的目标报冲突；上次写到一半时允许原值及已发布的新值。"""
    active = dict(tree.desired)
    active.update({name: overlay_id(data) for name, data in overlay.items()})
    retired = (previous.keys() | pending.keys()) - active.keys()
    base = tree.entries(tree.base, retired)
    desired = {**{name: base.get(name) for name in retired}, **active}
    head = tree.entries("HEAD", desired.keys() - previous.keys())
    changes = []
    conflicts = []
    for name, wanted in sorted(desired.items()):
        target = checked_path(tree.src, name)
        current = identities(target)
        if wanted in current:
            continue
        # 首次接管时，本机可能手动同步过系列中的某个中间版本。仅认同路径已归档的完整 blob；
        # 同步过一次后只接受上次观察值，不把用户后来主动回退的改动误认作旧构建。
        archived = name not in previous and not tree.versions.get(name, set()).isdisjoint(current)
        if (previous.get(name, head.get(name)) not in current and not archived and
                (name not in pending or pending[name] not in current)):
            conflicts.append(str(target))
            continue
        changes.append((target, current[0], wanted, overlay.get(name)))
    if conflicts:
        raise ValueError("以下文件在编译树中有独立修改，请先合并：\n" + "\n".join(conflicts))
    return active, desired, changes


def overlay_id(data):
    """工作区换行方式不同但文本相同的 overlay 复用编译结果。"""
    if data is None:
        return None
    return blob(data if b"\0" in data[:8000] else data.replace(b"\r\n", b"\n"))


def publish(target, old, data):
    """逐文件原子替换，并在发布前复核原值，避免编译读到半写内容或覆盖同步期间的编辑。"""
    if identities(target)[0] != old:
        raise ValueError(f"同步期间目标文件已变化：{target}")
    if data is None:
        target.unlink()
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as file:
        temporary = Path(file.name)
    try:
        temporary.write_bytes(data)
        temporary.replace(target)
    finally:
        temporary.unlink(missing_ok=True)


def apply_changes(tree, changes):
    """通过同一个只读 Git 进程取回补丁 blob，overlay 按预检时读取的原始字节发布。"""
    command = command_argv([tool("git", tree.env), "-C", str(tree.src), "cat-file", "--batch"])
    # 可执行文件来自本地工具链，参数固定为只读 cat-file；对象标识不进入命令行或 shell。
    # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit.dangerous-subprocess-use-audit, python.lang.security.audit.dangerous-subprocess-use-tainted-env-args.dangerous-subprocess-use-tainted-env-args
    with subprocess.Popen(command, env=tree.env, shell=False,  # nosec B603
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE) as batch:
        try:
            for target, old, wanted, data in changes:
                if wanted and data is None:
                    batch.stdin.write(wanted.encode() + b"\n")
                    batch.stdin.flush()
                    header = batch.stdout.readline().split()
                    if len(header) != 3 or header[:2] != [wanted.encode(), b"blob"]:
                        raise ValueError(f"缺少补丁对象：{wanted}")
                    data = batch.stdout.read(int(header[2]))
                    if len(data) != int(header[2]) or batch.stdout.read(1) != b"\n":
                        raise ValueError(f"补丁对象不完整：{wanted}")
                publish(target, old, data)
        finally:
            batch.stdin.close()

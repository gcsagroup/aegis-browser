"""Conservative input admission for the bounded tracker experiment.

This parser does not authorize builds. It accepts literal compiler argv, never
shell recipes, and charges repeated references before reading response files.
Unknown recipe syntax must be resolved before the command can be admitted.
"""

from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path
import shlex
import stat


class Refusal(ValueError):
    """The supplied input cannot be admitted."""


@dataclass
class Budget:
    bytes_left: int = 65536
    items_left: int = 4096

    def charge(self) -> None:
        if self.items_left <= 0:
            raise Refusal("dependency reference budget exhausted")
        self.items_left -= 1


def read_bounded(path: Path, budget: Budget) -> bytes:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise Refusal("input is not a regular file")
        chunks = []
        remaining = budget.bytes_left
        while True:
            data = os.read(fd, min(8192, remaining + 1))
            if not data:
                break
            if len(data) > remaining:
                raise Refusal("aggregate response/file-list byte budget exhausted")
            chunks.append(data)
            remaining -= len(data)
        budget.bytes_left = remaining
        return b"".join(chunks)
    finally:
        os.close(fd)


def reject_cwd_overrides(argv: list[str]) -> None:
    # A trailing override affects earlier operands too; inspect the whole argv
    # before resolving any path. Also reject linker and driver forwarding forms.
    for arg in argv:
        if "working-directory" in arg or arg == "-fdebug-compilation-dir":
            raise Refusal("compiler working-directory override is unsupported")


def expand(argv: list[str], cwd: Path, budget: Budget | None = None,
           active: tuple[Path, ...] = ()) -> list[str]:
    budget = budget if budget is not None else Budget()
    result = []
    for arg in argv:
        budget.charge()
        if not isinstance(arg, str) or not arg or "\0" in arg:
            raise Refusal("invalid argument")
        if arg.startswith("@"):
            path = canonical(cwd / arg[1:])
            if path in active or len(active) >= 8:
                raise Refusal("response-file cycle or depth limit")
            data = read_bounded(path, budget)
            try:
                nested = shlex.split(data.decode("utf-8"), posix=True)
            except (UnicodeError, ValueError) as exc:
                raise Refusal("invalid response-file encoding/quoting") from exc
            result.extend(expand(nested, cwd, budget, (*active, path)))
        elif arg in ("-filelist", "-Wl,-filelist") or "filelist," in arg:
            # Darwin link filelists need an explicit grammar and producer
            # binding. Refuse instead of silently treating them as options.
            raise Refusal("link filelist requires separate admission")
        else:
            result.append(arg)
    reject_cwd_overrides(result)
    return result


def canonical(path: Path) -> Path:
    # Walk the ORIGINAL sequence. In alias/../input.o the alias must be
    # examined before '..' can discard it; abspath/normpath would hide it.
    original = path if path.is_absolute() else Path.cwd() / path
    current = Path(original.anchor)
    parts = original.parts[1:]
    for index, part in enumerate(parts):
        if part == "..":
            current = current.parent
            continue
        candidate = current / part
        info = candidate.lstat()
        if stat.S_ISLNK(info.st_mode):
            raise Refusal("unadmitted symlink alias")
        if index + 1 < len(parts) and not stat.S_ISDIR(info.st_mode):
            raise Refusal("non-directory intermediate input component")
        current = candidate
    return current


def references(values: list[str], cwd: Path, admitted: dict[str, str],
               budget: Budget | None = None) -> list[Path]:
    """Validate explicit, implicit, order-only and depfile references alike.

    The caller supplies every occurrence, including duplicates. Admission of
    generated inputs additionally requires their producer receipt upstream.
    """
    budget = budget if budget is not None else Budget()
    result = []
    for value in values:
        budget.charge()
        path = canonical(cwd / value)
        if str(path) not in admitted:
            raise Refusal("unknown input or historical object")
        result.append(path)
    return result

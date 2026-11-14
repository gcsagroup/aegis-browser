"""读取 Windows 构建的最终语言包，验证原生卸载确认框和窗口占用提示。"""

import argparse
from pathlib import Path
import re
import sys


# 按窗口标题、确认正文、关闭浏览器提示的顺序比对，捕获中文回退到英文的情况。
MESSAGES = ("IDS_UNINSTALL_CHROME", "IDS_UNINSTALL_VERIFY", "IDS_UNINSTALL_CLOSE_APP")
EXPECTED = {
    "en-US": ("Uninstall GCSA Aegis", "Are you sure you want to uninstall GCSA Aegis?",
              "Please close all GCSA Aegis windows and try again."),
    "zh-CN": ("卸载 GCSA Aegis", "确定要卸载 GCSA Aegis 吗？", "请关闭所有 GCSA Aegis 窗口并重试。"),
    "zh-TW": ("解除安裝 GCSA Aegis", "你確定要解除安裝 GCSA Aegis 嗎？", "請關閉所有 GCSA Aegis 視窗，然後再試一次。"),
}


def main():
    """使用同次构建的资源编号读取 .pak，无需启动浏览器或执行卸载。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("src", type=Path, help="Chromium src 目录")
    parser.add_argument("out", type=Path, help="包含 gen 和 locales 的 Windows 构建输出目录")
    args = parser.parse_args()
    sys.path.insert(0, str(args.src / "tools/grit"))
    from grit.format.data_pack import ReadDataPack

    header = (args.out / "gen/chrome/grit/branded_strings.h").read_text(encoding="utf-8")
    ids = dict(re.findall(r"^#define (IDS_\w+) (\d+)$", header, re.MULTILINE))
    for locale, expected in EXPECTED.items():
        resources = ReadDataPack(args.out / f"locales/{locale}.pak").resources
        for name, text in zip(MESSAGES, expected, strict=True):
            actual = resources[int(ids[name])].decode("utf-8")
            if actual != text:
                raise AssertionError(f"{locale} {name}: {actual!r} != {text!r}")
    print("Windows 卸载提示英文、简体中文及繁体中文语言包回归通过。")


if __name__ == "__main__":
    main()

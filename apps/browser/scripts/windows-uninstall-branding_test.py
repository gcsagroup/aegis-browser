"""在 Windows 构建产物中验证卸载窗口和浏览器账号页使用安装器 ICO 的同一图层。"""

import argparse
from pathlib import Path
import re
import struct
import sys


def read_installer_png(icon_path: Path) -> bytes:
    """读取仓库 ICO 的 256px PNG 图层；格式或范围错误必须显式失败。"""
    data = icon_path.read_bytes()
    reserved, kind, count = struct.unpack_from("<HHH", data)
    if reserved != 0 or kind != 1:
        raise AssertionError("安装器资源不是有效 ICO")
    for index in range(count):
        width, height, _, _, _, _, size, offset = struct.unpack_from(
            "<BBBBHHII", data, 6 + 16 * index
        )
        if width == 0 and height == 0:
            if offset < 6 + count * 16 or offset + size > len(data):
                raise AssertionError("安装器 256px 图层超出 ICO 数据范围")
            png = data[offset:offset + size]
            if not png.startswith(b"\x89PNG\r\n\x1a\n"):
                raise AssertionError("安装器 256px 图层必须为 PNG")
            return png
    raise AssertionError("安装器 ICO 缺少 256px 图层")


def main():
    """从同次构建的 GRIT 头文件解析资源编号，防止编号重排导致比对错误。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("src", type=Path, help="Chromium src 目录")
    parser.add_argument("out", type=Path, help="包含 gen 与 resources.pak 的构建目录")
    args = parser.parse_args()
    sys.path.insert(0, str(args.src / "tools/grit"))
    from grit.format.data_pack import ReadDataPack

    resources = ReadDataPack(args.out / "resources.pak").resources
    expected = read_installer_png(args.src / "chrome/app/theme/gcsa_aegis/win/chromium.ico")
    for header_name, symbol in (
        ("chrome_unscaled_resources.h", "IDR_AEGIS_WINDOWS_APP_ICON"),
        ("aegis_resources.h", "IDR_AEGIS_ACCOUNT_ICON"),
    ):
        header = (args.out / "gen/chrome/grit" / header_name).read_text("utf-8")
        match = re.search(rf"^#define {symbol} (\d+)$", header, re.MULTILINE)
        if match is None or resources.get(int(match[1])) != expected:
            raise AssertionError(f"{symbol} 缺失或与安装器 ICO 的 256px 图层不一致")
    print("Windows 安装器、卸载窗口和账号页的应用图标完全一致。")


if __name__ == "__main__":
    main()

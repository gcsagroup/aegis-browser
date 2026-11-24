"""验证最终 Windows 资源包中的卸载图标与安装器 ICO 一致，不执行安装或卸载。"""

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
    """从同次构建的编号与资源包比对原图，防止卸载界面回退为透明 Logo。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("src", type=Path, help="Chromium src 目录")
    parser.add_argument("out", type=Path, help="包含 gen 与 resources.pak 的构建目录")
    args = parser.parse_args()
    sys.path.insert(0, str(args.src / "tools/grit"))
    from grit.format.data_pack import ReadDataPack

    header = (args.out / "gen/chrome/grit/chrome_unscaled_resources.h").read_text("utf-8")
    match = re.search(r"^#define IDR_AEGIS_WINDOWS_APP_ICON (\d+)$", header, re.MULTILINE)
    if match is None:
        raise AssertionError("构建资源缺少卸载应用图标编号")
    resources = ReadDataPack(args.out / "resources.pak").resources
    expected = read_installer_png(args.src / "chrome/app/theme/gcsa_aegis/win/chromium.ico")
    if resources[int(match[1])] != expected:
        raise AssertionError("卸载图标与安装器 ICO 的 256px 图层不一致")
    print("Windows 卸载图标与安装器应用图标完全一致。")


if __name__ == "__main__":
    main()

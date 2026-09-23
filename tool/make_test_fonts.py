#!/usr/bin/env python3
"""生成金色截图测试使用的子集字体（仅测试用，不进应用）。

1. 下载 Noto Sans SC（可变字体），实例化为 Regular 400。
2. 按 lib/ 源码中实际出现的字符子集化 -> test/fonts/ui_font.ttf
3. 按 lib/ 源码中实际使用的 Icons.xxx 子集化 MaterialIcons -> test/fonts/icons.otf
4. 生成 test/fonts/LICENSE.txt（OFL 1.1 + Apache 2.0 说明）

用法：
  python tool/make_test_fonts.py            # 全部生成
  python tool/make_test_fonts.py --icons-only   # 只重生成图标字体
依赖：pip install fonttools
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "test" / "fonts"
FLUTTER_ROOT = Path(os.environ.get("FLUTTER_ROOT", r"C:\flutter"))
NOTO_URL = (
    "https://raw.githubusercontent.com/google/fonts/main/ofl/notosanssc/"
    "NotoSansSC%5Bwght%5D.ttf"
)

# 框架内部使用、但未显式出现在 lib/ 源码中的图标
EXTRA_ICONS = ["expand_more", "expand_less"]

SUBSET_FLAGS = [
    "--layout-features=*",
    "--glyph-names",
    "--symbol-cmap",
    "--legacy-cmap",
    "--notdef-glyph",
    "--notdef-outline",
    "--recommended-glyphs",
    "--name-IDs=*",
    "--name-legacy",
    "--name-languages=*",
]


def run(cmd: list[str]) -> None:
    print("+", " ".join(cmd))
    subprocess.run(cmd, check=True)


def collect_chars() -> str:
    chars: set[str] = set()
    for path in (ROOT / "lib").rglob("*.dart"):
        chars.update(path.read_text(encoding="utf-8"))
    return "".join(sorted(chars))


def collect_icon_codepoints() -> str:
    names: set[str] = set(EXTRA_ICONS)
    for path in (ROOT / "lib").rglob("*.dart"):
        text = path.read_text(encoding="utf-8")
        names.update(re.findall(r"Icons\.([A-Za-z0-9_]+)", text))
    icons_dart = (
        FLUTTER_ROOT / "packages" / "flutter" / "lib" / "src" / "material"
        / "icons.dart"
    )
    if not icons_dart.exists():
        sys.exit(f"找不到 icons.dart：{icons_dart}，请设置 FLUTTER_ROOT")
    codepoints: dict[str, int] = {}
    for m in re.finditer(
        r"static const IconData (\w+) = IconData\(0x([0-9a-fA-F]+), "
        r"fontFamily: 'MaterialIcons'",
        icons_dart.read_text(encoding="utf-8"),
    ):
        codepoints[m.group(1)] = int(m.group(2), 16)
    missing = sorted(n for n in names if n not in codepoints)
    if missing:
        print("警告：以下图标未找到码点：", missing)
    return "".join(chr(codepoints[n]) for n in sorted(names) if n in codepoints)


def make_ui_font() -> None:
    var_ttf = OUT / "NotoSansSC-var.ttf"
    if not var_ttf.exists():
        print("下载", NOTO_URL)
        with urllib.request.urlopen(NOTO_URL) as resp, var_ttf.open("wb") as fh:
            fh.write(resp.read())
    static_ttf = OUT / "NotoSansSC-Regular.ttf"
    run([
        sys.executable, "-m", "fontTools.varLib.instancer",
        str(var_ttf), "wght=400", "-o", str(static_ttf),
    ])
    chars_file = OUT / "chars.txt"
    chars_file.write_text(collect_chars(), encoding="utf-8")
    run([
        sys.executable, "-m", "fontTools.subset",
        str(static_ttf),
        f"--text-file={chars_file}",
        f"--output-file={OUT / 'ui_font.ttf'}",
        *SUBSET_FLAGS,
    ])
    for name in ("NotoSansSC-var.ttf", "NotoSansSC-Regular.ttf", "chars.txt"):
        (OUT / name).unlink(missing_ok=True)


def make_icons_font() -> None:
    icon_text = collect_icon_codepoints()
    material = (
        FLUTTER_ROOT / "bin" / "cache" / "artifacts" / "material_fonts"
        / "MaterialIcons-Regular.otf"
    )
    if not material.exists():
        sys.exit(f"找不到 MaterialIcons：{material}")
    run([
        sys.executable, "-m", "fontTools.subset",
        str(material),
        f"--text={icon_text}",
        f"--output-file={OUT / 'icons.otf'}",
        *SUBSET_FLAGS,
    ])


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--icons-only", action="store_true")
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    if not args.icons_only:
        make_ui_font()
    make_icons_font()
    (OUT / "LICENSE.txt").write_text(
        "本目录字体仅用于 flutter test 的金色截图测试，不打包进应用。\n"
        "\n"
        "ui_font.ttf\n"
        "  来源：Noto Sans SC（Google Fonts），子集化并实例化为 Regular。\n"
        "  版权：Copyright 2014-2022 Adobe (http://www.adobe.com/)，"
        "保留原始版权声明。\n"
        "  许可：SIL Open Font License 1.1（见 OFL.txt）。\n"
        "\n"
        "icons.otf\n"
        "  来源：MaterialIcons-Regular.otf（Flutter SDK），"
        "按 UI 实际使用的图标子集化。\n"
        "  版权：Copyright 2014 Google LLC。\n"
        "  许可：Apache License 2.0（见 Apache-2.0.txt）。\n",
        encoding="utf-8",
    )
    print("完成")


if __name__ == "__main__":
    main()
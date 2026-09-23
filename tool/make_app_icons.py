#!/usr/bin/env python3
"""生成应用图标：Windows app_icon.ico + Android mipmap + iOS/macOS 图标。

用法：python tool/make_app_icons.py
依赖：pip install pillow
"""
from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
PRIMARY = (243, 210, 35)   # #F3D223 金黄
ACCENT = (245, 158, 11)    # #F59E0B 琥珀
INK = (25, 41, 68, 255)    # #192944 深藏青（符号/文字）


def lerp(a: tuple[int, int, int], b: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))  # type: ignore[return-value]


def draw_master(size: int = 1024, *, rounded: bool = True) -> Image.Image:
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # 渐变底（iOS 全出血方形，其余平台圆角）
    if rounded:
        radius = int(size * 0.215)
        mask = Image.new("L", (size, size), 0)
        ImageDraw.Draw(mask).rounded_rectangle(
            (0, 0, size - 1, size - 1), radius=radius, fill=255
        )
    else:
        mask = Image.new("L", (size, size), 255)
    grad = Image.new("RGBA", (size, size))
    gd = ImageDraw.Draw(grad)
    for y in range(size):
        t = y / max(size - 1, 1)
        color = lerp(PRIMARY, ACCENT, t) + (255,)
        gd.line((0, y, size, y), fill=color)
    img.paste(grad, (0, 0), mask)

    # WiFi 图标（三条弧 + 圆点，深藏青）
    cx, cy = size / 2, size * 0.545
    dot_r = size * 0.046
    thickness = size * 0.035
    radii = (size * 0.135, size * 0.235, size * 0.335)

    def band(outer_r: float) -> None:
        bbox = (cx - outer_r, cy - outer_r, cx + outer_r, cy + outer_r)
        draw.arc(bbox, start=225, end=315, fill=INK, width=round(thickness))

    for r in radii:
        band(r)
    bbox = (cx - dot_r, cy - dot_r, cx + dot_r, cy + dot_r)
    draw.ellipse(bbox, fill=INK)
    return img


def main() -> None:
    master = draw_master()
    master_sq = draw_master(rounded=False)

    # Windows .ico（多尺寸）
    ico_path = ROOT / "windows" / "runner" / "resources" / "app_icon.ico"
    master.save(
        ico_path,
        format="ICO",
        sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
    )
    print("written", ico_path)

    # Android mipmap 启动图标
    mipmaps = {
        "mdpi": 48,
        "hdpi": 72,
        "xhdpi": 96,
        "xxhdpi": 144,
        "xxxhdpi": 192,
    }
    for name, px in mipmaps.items():
        out = (
            ROOT / "android" / "app" / "src" / "main" / "res"
            / f"mipmap-{name}" / "ic_launcher.png"
        )
        out.parent.mkdir(parents=True, exist_ok=True)
        master.resize((px, px), Image.Resampling.LANCZOS).save(out)
        print("written", out)

    # iOS 图标（全出血方形、无透明通道）
    ios_sizes = {
        "20x20@1x": 20, "20x20@2x": 40, "20x20@3x": 60,
        "29x29@1x": 29, "29x29@2x": 58, "29x29@3x": 87,
        "40x40@1x": 40, "40x40@2x": 80, "40x40@3x": 120,
        "60x60@2x": 120, "60x60@3x": 180,
        "76x76@1x": 76, "76x76@2x": 152,
        "83.5x83.5@2x": 167,
        "1024x1024@1x": 1024,
    }
    ios_dir = ROOT / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
    ios_dir.mkdir(parents=True, exist_ok=True)
    for name, px in ios_sizes.items():
        out = ios_dir / f"Icon-App-{name}.png"
        master_sq.resize((px, px), Image.Resampling.LANCZOS).convert("RGB").save(out)
        print("written", out)

    # macOS 图标（圆角，保留透明）
    mac_dir = ROOT / "macos" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
    mac_dir.mkdir(parents=True, exist_ok=True)
    for px in (16, 32, 64, 128, 256, 512, 1024):
        out = mac_dir / f"app_icon_{px}.png"
        master.resize((px, px), Image.Resampling.LANCZOS).save(out)
        print("written", out)

    # 仓库里也留一份 512 预览图
    preview = ROOT / "assets" / "app_icon.png"
    preview.parent.mkdir(parents=True, exist_ok=True)
    master.resize((512, 512), Image.Resampling.LANCZOS).save(preview)
    print("written", preview)


if __name__ == "__main__":
    main()
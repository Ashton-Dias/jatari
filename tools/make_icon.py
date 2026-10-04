#!/usr/bin/env python3
"""Builds the app icon from tools/icon-source/source.jpeg.

Output: 1024x1024 sRGB PNG, no alpha, square corners (iOS rounds them itself).
Uses the whole image (a zoomed crop on the characters cut off a hand and the text, so it was dropped).
Usage: python3 tools/make_icon.py [output.png]
"""
import sys, os
from PIL import Image

here = os.path.dirname(os.path.abspath(__file__))
src = Image.open(os.path.join(here, "icon-source", "source.jpeg")).convert("RGB")   # drops any alpha
out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "..", "MyApp", "Assets.xcassets", "AppIcon.appiconset", "icon-1024.png")

icon = src.resize((1024, 1024), Image.LANCZOS)
os.makedirs(os.path.dirname(out), exist_ok=True)
icon.save(out, "PNG", optimize=True)
print("wrote", os.path.normpath(out), icon.size, icon.mode)

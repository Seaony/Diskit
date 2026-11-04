#!/usr/bin/env python3
"""按由内到外的顺序签名，不使用递归重签。"""
import argparse
import os
from pathlib import Path
import subprocess

MACHO = {bytes.fromhex(value) for value in ("feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca")}


def code_paths(app):
    binaries, bundles = [], []
    for base, directories, files in os.walk(app, followlinks=False):
        directories[:] = [name for name in directories if not (Path(base) / name).is_symlink()]
        folder = Path(base)
        if folder != app and folder.suffix in (".app", ".framework", ".xpc", ".bundle"):
            bundles.append(folder)
        for name in files:
            path = folder / name
            if path.is_symlink():
                continue
            with path.open("rb") as stream:
                if stream.read(4) in MACHO:
                    binaries.append(path)
    return sorted(binaries, key=lambda value: len(value.parts), reverse=True) + sorted(bundles, key=lambda value: len(value.parts), reverse=True) + [app]


def main():
    parser = argparse.ArgumentParser(description="逐个签名或验证应用组件")
    parser.add_argument("app", type=Path)
    parser.add_argument("--identity")
    parser.add_argument("--timestamp", choices=("auto", "required", "none"), default="auto")
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    app = args.app.resolve()
    if not (app / "Contents/Info.plist").is_file():
        parser.error("找不到有效应用包")
    paths = code_paths(app)
    if not args.verify:
        if not args.identity:
            parser.error("签名需要 --identity")
        timestamp = args.timestamp == "required" or (args.timestamp == "auto" and args.identity.startswith("Developer ID Application:"))
        if not timestamp:
            print("本地验证签名未使用可信时间戳；正式发行需 Developer ID 和可访问的时间戳服务。")
        for path in paths:
            subprocess.run(["codesign", "--force", "--sign", args.identity, "--options", "runtime", "--preserve-metadata=identifier,entitlements", "--timestamp" if timestamp else "--timestamp=none", str(path)], check=True)
    for path in paths:
        subprocess.run(["codesign", "--verify", "--strict", "--verbose=2", str(path)], check=True)


if __name__ == "__main__":
    main()

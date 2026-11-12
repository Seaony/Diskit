#!/usr/bin/env python3
"""按由内到外的顺序签名，不使用递归重签。"""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

MACHO = {bytes.fromhex(value) for value in ("feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca")}


def code_paths(app):
    binaries, bundles = [], []
    for base, directories, files in os.walk(app, followlinks=False):
        directories[:] = [name for name in directories if not (Path(base) / name).is_symlink()]
        folder = Path(base)
        if folder != app and folder.suffix in (".app", ".appex", ".framework", ".xpc", ".bundle"):
            bundles.append(folder)
        for name in files:
            path = folder / name
            if path.is_symlink():
                continue
            with path.open("rb") as stream:
                if stream.read(4) in MACHO:
                    binaries.append(path)
    return sorted(binaries, key=lambda value: len(value.parts), reverse=True) + sorted(bundles, key=lambda value: len(value.parts), reverse=True) + [app]


def profile_entitlements(bundle, profile, source, folder):
    """把描述文件嵌进包里，并按描述文件展开权限文件里的团队前缀。"""
    decoded = plistlib.loads(subprocess.run(["security", "cms", "-D", "-i", str(profile)], check=True, capture_output=True).stdout)
    allowed = decoded["Entitlements"]
    team = decoded["TeamIdentifier"][0]
    identifier = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"]
    if allowed["com.apple.application-identifier"] != f"{team}.{identifier}":
        raise SystemExit(f"描述文件 {profile.name} 不是给 {identifier} 的")
    text = source.read_text().replace("$(TeamIdentifierPrefix)", team + ".").replace("$(AppIdentifierPrefix)", team + ".")
    entitlements = plistlib.loads(text.encode())
    missing = [key for key in entitlements if key.startswith("com.apple.developer.") and key not in allowed]
    if missing:
        raise SystemExit(f"描述文件 {profile.name} 缺少权限：{', '.join(missing)}")
    entitlements["com.apple.application-identifier"] = allowed["com.apple.application-identifier"]
    entitlements["com.apple.developer.team-identifier"] = team
    shutil.copyfile(profile, bundle / "Contents/embedded.provisionprofile")
    output = Path(folder) / (identifier + ".entitlements")
    output.write_bytes(plistlib.dumps(entitlements))
    return output


def main():
    parser = argparse.ArgumentParser(description="逐个签名或验证应用组件")
    parser.add_argument("app", type=Path)
    parser.add_argument("--identity")
    parser.add_argument("--timestamp", choices=("auto", "required", "none"), default="auto")
    parser.add_argument("--verify", action="store_true")
    parser.add_argument("--profile", action="append", default=[], metavar="包内路径=描述文件:权限文件",
                        help="给 App（包内路径写 .）或扩展嵌入描述文件并签上对应权限")
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
        with tempfile.TemporaryDirectory(prefix="diskit-sign-") as folder:
            entitlements = {}
            for item in args.profile:
                relative, _, files = item.partition("=")
                profile, _, source = files.partition(":")
                bundle = (app / relative).resolve()
                entitlements[bundle] = profile_entitlements(bundle, Path(profile), Path(source), folder)
            for path in paths:
                metadata = ["--entitlements", str(entitlements[path])] if path in entitlements else ["--preserve-metadata=identifier,entitlements"]
                subprocess.run(["codesign", "--force", "--sign", args.identity, "--options", "runtime", *metadata, "--timestamp" if timestamp else "--timestamp=none", str(path)], check=True)
    for path in paths:
        subprocess.run(["codesign", "--verify", "--strict", "--verbose=2", str(path)], check=True)


if __name__ == "__main__":
    main()

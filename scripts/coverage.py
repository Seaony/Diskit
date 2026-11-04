#!/usr/bin/env python3
"""汇总自有源码行覆盖率；缺测试或未达标时明确失败。"""
import json
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build" / "Coverage"
LIMITS = {
    "Core": 85, "ADB": 80, "RicohGR": 75, "AliyunDrive": 85,
    "Quark": 85, "S3Drive": 85, "CloudDrive": 85, "CameraUSB": 75,
    "PikPakDrive": 85, "LanzouDrive": 85, "TianyiDrive": 85,
    "ChinaWebDrive": 85, "DevTool": 70,
}


def run(command, log):
    with log.open("w") as output:
        result = subprocess.run(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT)
    return result.returncode == 0


def package_lines(document, source):
    covered = count = 0
    for record in document["data"]:
        for file in record["files"]:
            if Path(file["filename"]).is_relative_to(source):
                lines = file["summary"]["lines"]
                covered += lines["covered"]
                count += lines["count"]
    return covered, count


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    rows = []
    for name, minimum in LIMITS.items():
        package = ROOT / "Packages" / name
        ok = run(["swift", "test", "--package-path", str(package), "--enable-code-coverage"],
                 OUT / f"{name}.log")
        covered = count = 0
        if ok:
            path = subprocess.check_output([
                "swift", "test", "--package-path", str(package), "--show-codecov-path"
            ], cwd=ROOT, text=True).strip()
            covered, count = package_lines(json.loads(Path(path).read_text()), package / "Sources")
        rows.append((name, covered, count, minimum, ok))
    package_covered = sum(row[1] for row in rows)
    package_total = sum(row[2] for row in rows)
    rows.append(("所有包", package_covered, package_total, 85, all(row[4] for row in rows)))

    result = OUT / "App.xcresult"
    if result.exists():
        shutil.rmtree(result)
    ok = run([
        "xcodebuild", "-project", "Kayoi.xcodeproj", "-scheme", "KayoiTests",
        "-destination", "platform=macOS,arch=arm64", "-derivedDataPath", "build/Tests",
        "-enableCodeCoverage", "YES", "-resultBundlePath", str(result),
        "test", "CODE_SIGNING_ALLOWED=NO",
    ], OUT / "App.log")
    covered = count = 0
    if ok:
        report = json.loads(subprocess.check_output([
            "xcrun", "xccov", "view", "--report", "--json", str(result)
        ], text=True))
        for target in report["targets"]:
            for file in target.get("files", []):
                if Path(file["path"]).is_relative_to(ROOT / "App" / "Logic"):
                    covered += file["coveredLines"]
                    count += file["executableLines"]
    rows.append(("App 逻辑", covered, count, 75, ok))
    failed = False
    output = []
    for name, covered, count, minimum, ok in rows:
        percent = 100 * covered / count if count else 0
        passed = ok and count > 0 and percent >= minimum
        failed |= not passed
        output.append(f"{name}: {covered}/{count} = {percent:.2f}%; 目标 {minimum}%; "
                      + ("通过" if passed else "未通过")
                      + ("" if ok else "（测试未通过或缺少测试目标）"))
    text = "\n".join(output) + "\n"
    (OUT / "summary.txt").write_text(text)
    print(text, end="")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())

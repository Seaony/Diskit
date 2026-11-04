#!/usr/bin/env python3
"""命令行工具与 SwiftPM 资源包必须保持相邻。"""
from pathlib import Path
import shutil
import sys


def verify_resources(destination):
    core = destination / 'Core_Core.bundle/Contents/Resources'
    for language in ('en', 'zh-Hans'):
        for name in ('Localizable.strings', 'Localizable.stringsdict'):
            resource = core / f'{language}.lproj' / name
            if not resource.is_file() or resource.stat().st_size == 0:
                raise ValueError(f'命令行工具缺少本地化资源：{resource}')


def package(source, destination):
    verify_resources(source)
    destination.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source / 'kayoi-dev', destination / 'kayoi-dev')
    for bundle in source.glob('*.bundle'):
        shutil.copytree(bundle, destination / bundle.name, dirs_exist_ok=True, symlinks=True)
    verify_resources(destination)


if __name__ == '__main__':
    try:
        if len(sys.argv) == 3 and sys.argv[1] == '--verify':
            verify_resources(Path(sys.argv[2]))
        elif len(sys.argv) == 3:
            package(Path(sys.argv[1]), Path(sys.argv[2]))
        else:
            raise ValueError('用法：package-cli.py 构建产物目录 输出目录，或 --verify 输出目录')
    except (ValueError, OSError) as error:
        raise SystemExit(str(error))

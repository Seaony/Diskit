#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
python3 - "$@" <<'PY'
import pathlib, re, sys
files = [pathlib.Path(p) for p in sys.argv[1:]] or sorted(pathlib.Path('App').rglob('*.swift'))
failures = []
for path in files:
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if 'grid: ok' in line:
            continue
        values = re.findall(r'\b(?:spacing|width|height|minWidth|maxWidth|minHeight|maxHeight|minLength|cornerRadius)\s*:\s*(\d+(?:\.\d+)?)', line)
        values += re.findall(r'\.padding\((?:\.[A-Za-z]+,\s*)?(\d+(?:\.\d+)?)\)', line)
        invalid = [v for v in values if float(v) not in (0, 1, 2) and float(v) % 4 != 0]
        if invalid:
            failures.append(f'{path}:{number}: 非网格尺寸 {", ".join(invalid)}: {line.strip()}')
        if re.search(r'\.(?:offset|position)\(', line):
            failures.append(f'{path}:{number}: 位移缺少 grid: ok 说明: {line.strip()}')
print('\n'.join(failures) if failures else f'PASS grid-lint: {len(files)} files')
sys.exit(bool(failures))
PY

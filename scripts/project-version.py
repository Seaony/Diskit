#!/usr/bin/env python3
import re
from pathlib import Path

source = (Path(__file__).resolve().parent.parent / "project.yml").read_text()
for key in ("MARKETING_VERSION", "CURRENT_PROJECT_VERSION"):
    values = re.findall(r"^    " + key + r':\s*"?([^"\s]+)"?\s*$', source, re.MULTILINE)
    if len(values) != 1:
        raise SystemExit("版本必须只在 project.yml settings.base 定义一次：" + key)
    print(values[0])

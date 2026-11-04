#!/usr/bin/env python3
"""校验应用与共享包的实际本地化键，不依赖编译器自动提取 L。"""
from __future__ import annotations

import argparse
from collections import Counter
from dataclasses import dataclass
import json
from pathlib import Path
import re
import sys

PRINTF = re.compile(r"%(?:(\d+)\$)?[-+ #0']*(?:\d+|\*)?(?:\.(?:\d+|\*))?(hh|ll|h|l|L|z|j|t)?([@diuoxXfFeEgGaAcCsSp%])")
NUMERIC = set("diuoxXfFeEgGaA")
LOCALIZED_CALLS = {"L", "LF", "Text", "Button", "Label", "Toggle", "Picker", "TextField", "SecureField", "Section", "GroupBox", "Window", "Menu", "Link", "ContentUnavailableView", "LocalizedStringKey", "navigationTitle", "help", "accessibilityLabel", "accessibilityHint", "accessibilityValue", "confirmationDialog", "alert"}


@dataclass
class Token:
    kind: str
    value: str
    start: int
    dynamic: bool = False


def tokens(source: str, offset: int = 0, stop_at_parenthesis: bool = False) -> list[Token]:
    result: list[Token] = []
    i = 0
    paren_depth = 1
    while i < len(source):
        if source[i].isspace():
            i += 1
        elif source.startswith("//", i):
            end = source.find("\n", i)
            i = len(source) if end < 0 else end
        elif source.startswith("/*", i):
            depth = 1
            i += 2
            while i < len(source) and depth:
                if source.startswith("/*", i): depth += 1; i += 2
                elif source.startswith("*/", i): depth -= 1; i += 2
                else: i += 1
        elif source[i] == '"' or (source[i] == "#" and re.match(r'#+"', source[i:])):
            start = i
            hashes = 0
            while source[i] == "#": hashes += 1; i += 1
            quote = '"""' if source.startswith('"""', i) else '"'
            i += len(quote)
            closing = quote + "#" * hashes
            escape = "\\" + "#" * hashes
            value: list[str] = []
            nested: list[Token] = []
            dynamic = False
            while i < len(source) and not source.startswith(closing, i):
                if source.startswith(escape + "(", i):
                    dynamic = True
                    begin = i + len(escape) + 1
                    depth, end = 1, begin
                    # 表达式里的字符串由递归词法器识别，括号只在代码令牌中计数。
                    expression_tokens = tokens(source[begin:], offset + begin, stop_at_parenthesis=True)
                    for token in expression_tokens:
                        if token.kind == "punct" and token.value == "(": depth += 1
                        if token.kind == "punct" and token.value == ")":
                            depth -= 1
                            if depth == 0:
                                end = token.start - offset
                                break
                    else:
                        end = len(source)
                    nested.extend(tokens(source[begin:end], offset + begin))
                    value.append("\0")
                    i = min(end + 1, len(source))
                elif source.startswith(escape, i):
                    i += len(escape)
                    if i >= len(source): break
                    unicode = re.match(r"u\{([0-9a-fA-F]+)\}", source[i:])
                    if unicode:
                        value.append(chr(int(unicode[1], 16))); i += len(unicode[0])
                    else:
                        value.append({"n": "\n", "t": "\t", "r": "\r", "0": "\0"}.get(source[i], source[i])); i += 1
                else:
                    value.append(source[i]); i += 1
            i += len(closing)
            text = "".join(value)
            if quote == '"""':
                lines = text.splitlines()
                if lines and not lines[0].strip(): lines.pop(0)
                if lines and not lines[-1].strip():
                    indent = len(lines.pop())
                    lines = [line[indent:] if len(line) >= indent else line for line in lines]
                text = "\n".join(lines)
            result.append(Token("string", text, offset + start, dynamic))
            result.extend(nested)
        elif source[i].isalpha() or source[i] == "_":
            start = i
            i += 1
            while i < len(source) and (source[i].isalnum() or source[i] == "_"): i += 1
            result.append(Token("identifier", source[start:i], offset + start))
        else:
            character = source[i]
            result.append(Token("punct", character, offset + i)); i += 1
            if stop_at_parenthesis:
                if character == "(": paren_depth += 1
                if character == ")":
                    paren_depth -= 1
                    if paren_depth == 0: break
    return sorted(result, key=lambda token: token.start)


def extract_keys(source: str, path: str) -> tuple[dict[str, list[str]], list[str]]:
    values = tokens(source)
    found: dict[str, list[str]] = {}
    issues: list[str] = []
    for index, token in enumerate(values[:-2]):
        if token.kind != "identifier" or token.value not in LOCALIZED_CALLS: continue
        if index and values[index - 1].value == "func": continue
        if values[index + 1].value != "(": continue
        argument = values[index + 2]
        if argument.kind != "string":
            if token.value in {"L", "LF"}:
                line = source.count("\n", 0, token.start) + 1
                issues.append(f"{path}:{line}: 本地化键必须是明确的字面量")
            continue
        line = source.count("\n", 0, argument.start) + 1
        location = f"{path}:{line}"
        if argument.dynamic:
            if token.value in {"L", "LF"} or re.search(r"[A-Za-z\u3400-\u9fff]", argument.value.replace("\0", "")):
                issues.append(f"{location}: 含插值的文案请改为 LF 格式参数")
            continue
        if token.value in {"L", "LF"} and index + 3 < len(values) and values[index + 3].value not in {",", ")"}:
            issues.append(f"{location}: 本地化键不能拼接或计算")
            continue
        if argument.value:
            found.setdefault(argument.value, []).append(location)
    return found, issues


def format_signature(value: str) -> Counter[tuple[int, str]]:
    result: Counter[tuple[int, str]] = Counter()
    next_index = 1
    for match in PRINTF.finditer(value):
        if match[3] == "%": continue
        index = int(match[1]) if match[1] else next_index
        next_index += 1
        result[index, (match[2] or "") + match[3]] += 1
    return result


def string_units(node: dict):
    if "stringUnit" in node:
        yield node["stringUnit"]
    for value in node.values():
        if isinstance(value, dict): yield from string_units(value)


def has_plural(node: dict, language: str) -> bool:
    plural = node.get("variations", {}).get("plural", {})
    required = {"other", "one"} if language == "en" else {"other"}
    if required <= plural.keys(): return True
    return any(has_plural(value, language) for value in node.get("substitutions", {}).values())


def validate_catalog(path: Path, used: dict[str, list[str]], *, check_formats: bool = True) -> list[str]:
    issues: list[str] = []
    if not path.exists(): return [f"{path}: 字符串目录不存在"]
    try:
        catalog = json.loads(path.read_text())["strings"]
    except (ValueError, KeyError) as error:
        return [f"{path}: 字符串目录格式错误：{error}"]
    for key in sorted(used.keys() - catalog.keys()):
        issues.append(f"{used[key][0]}: 缺少键 {key!r}（{path}）")
    for key in sorted(catalog.keys() - used.keys()):
        issues.append(f"{path}: 未使用的键 {key!r}")
    for key, entry in catalog.items():
        for language in ["zh-Hans", "en"]:
            localized = entry.get("localizations", {}).get(language)
            units = list(string_units(localized or {}))
            if not units:
                issues.append(f"{path}: {key!r} 缺少 {language} 翻译")
                continue
            substitutions = (localized or {}).get("substitutions", {})
            expected = format_signature(key)
            checked_units = []
            root = {name: value for name, value in (localized or {}).items() if name != "substitutions"}
            for unit in string_units(root):
                value = unit.get("value", "")
                for name, substitution in substitutions.items():
                    argument = substitution.get("argNum")
                    specifier = substitution.get("formatSpecifier", "")
                    value = value.replace(f"%#@{name}@", f"%{argument}${specifier}")
                checked_units.append((unit, value, expected))
            for name, substitution in substitutions.items():
                argument = substitution.get("argNum")
                specifier = substitution.get("formatSpecifier", "")
                signature = Counter({(argument, specifier): 1})
                if (argument, specifier) not in expected:
                    issues.append(f"{path}: {key!r} 的 {language} 替换参数 {name!r} 不匹配")
                for unit in string_units(substitution):
                    value = unit.get("value", "").replace("%arg", f"%{argument}${specifier}")
                    checked_units.append((unit, value, signature))
                if not has_plural(substitution, language):
                    issues.append(f"{path}: {key!r} 的 {language} 替换参数缺少复数变体")
            for unit, value, signature in checked_units:
                if not unit.get("value") or unit.get("state") != "translated":
                    issues.append(f"{path}: {key!r} 的 {language} 翻译未完成")
                if check_formats and (format_signature(value) != signature or "%#@" in value):
                    issues.append(f"{path}: {key!r} 的 {language} 格式参数不一致：{value!r}")
            numeric = {(number, spec) for number, spec in expected if spec[-1] in NUMERIC}
            if check_formats and numeric:
                if not has_plural(localized or {}, language):
                    issues.append(f"{path}: {key!r} 的 {language} 缺少数字复数变体")
                if len(numeric) > 1 and numeric != {(item.get("argNum"), item.get("formatSpecifier")) for item in substitutions.values()}:
                    issues.append(f"{path}: {key!r} 的 {language} 多个数字参数必须显式声明复数替换")
    return issues


def inventory(root: Path) -> tuple[dict[str, dict[str, list[str]]], list[str]]:
    catalogs = {
        "App/Localizable.xcstrings": {},
        "Packages/Core/Sources/Core/Resources/Localizable.xcstrings": {},
        "App/InfoPlist.xcstrings": {},
    }
    issues: list[str] = []
    sources = sorted((root / "App").rglob("*.swift")) + sorted((root / "Packages").glob("*/Sources/**/*.swift"))
    for path in sources:
        if "Vendor" in path.parts: continue
        relative = path.relative_to(root).as_posix()
        found, problems = extract_keys(path.read_text(), relative)
        issues.extend(problems)
        destination = "App/Localizable.xcstrings" if relative.startswith("App/") else "Packages/Core/Sources/Core/Resources/Localizable.xcstrings"
        for key, locations in found.items(): catalogs[destination].setdefault(key, []).extend(locations)
    project = root / "project.yml"
    if project.exists():
        for match in re.finditer(r"^\s*(NS\w+UsageDescription):", project.read_text(), re.MULTILINE):
            catalogs["App/InfoPlist.xcstrings"][match[1]] = ["project.yml"]
    return catalogs, issues


def check(root: Path) -> tuple[list[str], dict[str, dict[str, list[str]]]]:
    catalogs, issues = inventory(root)
    for relative, used in catalogs.items():
        issues.extend(validate_catalog(root / relative, used, check_formats=not relative.endswith("InfoPlist.xcstrings")))
    return issues, catalogs


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--inventory", type=Path, help="只导出使用键，供目录归拢")
    options = parser.parse_args()
    if options.inventory:
        values, problems = inventory(options.root)
        options.inventory.write_text(json.dumps(values, ensure_ascii=False, indent=2) + "\n")
        for problem in problems: print(problem, file=sys.stderr)
        return bool(problems)
    issues, catalogs = check(options.root)
    if issues:
        for issue in issues: print(issue, file=sys.stderr)
        print(f"本地化校验失败：{len(issues)} 项", file=sys.stderr)
        return 1
    print(f"本地化校验通过：{sum(len(keys) for keys in catalogs.values())} 个实际使用键，中文/英文、格式参数和复数一致")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

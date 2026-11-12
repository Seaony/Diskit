#!/usr/bin/env python3
"""验证版本与制品关联；密码学验签由 Sparkle 官方工具执行。"""
from pathlib import Path
import base64
import plistlib
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

def require(condition, message):
    if not condition:
        raise SystemExit(message)
root = Path(__file__).resolve().parent.parent
app = Path(sys.argv[1]).resolve()
feed = Path(sys.argv[2]).resolve() if len(sys.argv) > 2 and sys.argv[2] else None
archive = Path(sys.argv[3]).resolve() if len(sys.argv) > 3 and sys.argv[3] else None
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
versions = subprocess.check_output([sys.executable, str(root / 'scripts/project-version.py')], text=True).splitlines()
require(info['CFBundleShortVersionString'] == versions[0], '营销版本不匹配')
require(str(info['CFBundleVersion']) == versions[1], '构建号不匹配')
require(info['LSMinimumSystemVersion'] == '26.0', '最低系统版本不匹配')
require(info['SUFeedURL'] == 'https://github.com/Seaony/Diskit/releases/latest/download/appcast.xml', '更新源不匹配')
require(info['SUPublicEDKey'] == 'FnPUWAEY6WKwo0yvQLOBvEt7xjuhAabwNu1Y9QalNQc=', '更新公钥不匹配')
require(len(base64.b64decode(info['SUPublicEDKey'], validate=True)) == 32, '发行校验失败')
require(info['SURequireSignedFeed'] and info['SUVerifyUpdateBeforeExtraction'], '必须先验签再解压，并校验feed')
require(info['SUEnableAutomaticChecks'] and info['SUScheduledCheckInterval'] == 86400, '发行校验失败')
require((app / 'Contents/Frameworks/Sparkle.framework').is_dir(), '缺少 Sparkle.framework')
architectures = subprocess.check_output(['lipo', '-archs', str(app / 'Contents/MacOS/Diskit')], text=True).split()
require({'arm64', 'x86_64'} <= set(architectures), '应用不是通用二进制')
extension = app / 'Contents/Extensions/DiskitFS.appex'
require(extension.is_dir(), '缺少 FSKit 扩展')
# App 和扩展都要用 Developer ID 签名、带描述文件，否则别人机器上挂载会被系统拒绝
for bundle, permission in ((app, 'com.apple.developer.fskit.mount'), (extension, 'com.apple.developer.fskit.fsmodule')):
    require((bundle / 'Contents/embedded.provisionprofile').is_file(), bundle.name + ' 缺少描述文件')
    details = subprocess.run(['codesign', '-dvv', str(bundle)], capture_output=True, text=True, check=True).stderr
    require('Authority=Developer ID Application:' in details and 'TeamIdentifier=JJJKGPY7T7' in details, bundle.name + ' 不是 Developer ID 签名')
    require('(runtime)' in details, bundle.name + ' 没开 hardened runtime')
    entitlements = plistlib.loads(subprocess.check_output(['codesign', '-d', '--entitlements', '-', '--xml', str(bundle)], stderr=subprocess.DEVNULL))
    require(entitlements.get(permission) is True, bundle.name + ' 缺少 ' + permission)
    require(entitlements.get('keychain-access-groups') == ['JJJKGPY7T7.com.seaony.Diskit.shared'], bundle.name + ' 共享钥匙串组不对')
    require('com.apple.security.get-task-allow' not in entitlements, bundle.name + ' 带了调试权限')
if feed:
    require(archive and archive.is_file(), '必须同时提供压缩包')
    document = ET.parse(feed).getroot()
    namespace = {'s': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}
    items = document.findall('./channel/item')
    require(len(items) == 1, '发布验收需要恰好一个版本')
    item = items[0]
    require(item.findtext('s:version', namespaces=namespace) == versions[1], 'feed构建号不匹配')
    require(item.findtext('s:shortVersionString', namespaces=namespace) == versions[0], 'feed营销版本不匹配')
    require(item.findtext('s:minimumSystemVersion', namespaces=namespace) == '26.0', 'feed最低系统版本不匹配')
    enclosure = item.find('enclosure')
    expected = 'https://github.com/Seaony/Diskit/releases/download/v' + versions[0] + '/' + archive.name
    require(enclosure.attrib['url'] == expected, '制品URL不匹配')
    require(int(enclosure.attrib['length']) == archive.stat().st_size, '制品长度不匹配')
    require(len(base64.b64decode(enclosure.attrib['{' + namespace['s'] + '}edSignature'], validate=True)) == 64, '发行校验失败')
    with tempfile.TemporaryDirectory(prefix='diskit-validate-') as temporary:
        subprocess.run(['ditto', '-x', '-k', str(archive), temporary], check=True)
        bundled = Path(temporary) / 'Diskit.app'
        extracted = plistlib.loads((bundled / 'Contents/Info.plist').read_bytes())
        require(extracted == info, '压缩包内Info.plist不同于被验证应用')
        subprocess.run([sys.executable, str(root / 'scripts/sign-app.py'), str(bundled), '--verify'], check=True)
        subprocess.run(['xcrun', 'stapler', 'validate', str(bundled)], check=True)
        executable = bundled / 'Contents/MacOS/Diskit'
        require(executable.read_bytes() == (app / 'Contents/MacOS/Diskit').read_bytes(), '压缩包可执行文件不匹配')
print('已验证 Diskit ' + versions[0] + ' (' + versions[1] + ')')

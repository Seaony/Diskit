# 发版配置，由共用脚本 ~/.agents/skills/mac-release/scripts/mac-release 读取，变量说明见同目录的 SKILL.md。
APP_NAME=Diskit
# 源码、安装包和更新源都在 origin（Seaony/Diskit），共用脚本默认就发到 origin
# 版本号唯一来源是 project.yml，发布时一起提交
VERSION_FILES=project.yml
release_test() { make test; }
release_set_version() {
  sed -i '' -E "s/^    MARKETING_VERSION: \"[^\"]+\"/    MARKETING_VERSION: \"$VERSION\"/; s/^    CURRENT_PROJECT_VERSION: \"[^\"]+\"/    CURRENT_PROJECT_VERSION: \"$BUILD_NUMBER\"/" project.yml
  [[ "$(python3 scripts/project-version.py | tr '\n' ' ')" == "$VERSION $BUILD_NUMBER " ]] || { echo '写入版本号失败' >&2; return 1; }
}
# 要嵌入描述文件、给文件系统扩展签权限，用自己的 make release 构建和签名
release_build() {
  make release RELEASE_IDENTITY="$SIGN_IDENTITY"
  APP_PATH="$PWD/build/DerivedData/Build/Products/Release/Diskit.app"
  SPARKLE_BIN="$PWD/build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
}
release_validate() { scripts/validate-release.sh "$@"; }
# 带背景图和固定图标布局的安装窗口，配置见 scripts/dmg/
DMG_SETTINGS=scripts/dmg/dmg-settings.py

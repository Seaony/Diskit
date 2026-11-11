.PHONY: gen build release test coverage dev-tool format
export KAYOI_BUILD_CONFIG ?= Config/Validation.xcconfig
SIGN_IDENTITY ?= Apple Development: seaony@outlook.com
SIGN_TIMESTAMP ?= auto

gen:
	xcodegen generate
	mkdir -p Kayoi.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
	cp Dependencies/Package.resolved Kayoi.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved

# 开发构建由 Xcode 用付费团队自动签名：FSKit 扩展的权限必须写在团队描述文件里，事后重签会丢掉
build: gen
	xcodebuild -project Kayoi.xcodeproj -scheme Kayoi -configuration Debug -derivedDataPath build/DerivedData build -allowProvisioningUpdates -onlyUsePackageVersionsFromResolvedFile
	codesign --verify --deep --strict --verbose=1 build/DerivedData/Build/Products/Debug/Kayoi.app

release: gen dev-tool
	xcodebuild -project Kayoi.xcodeproj -scheme Kayoi -configuration Release -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build CODE_SIGNING_ALLOWED=NO -onlyUsePackageVersionsFromResolvedFile
	python3 scripts/sign-app.py build/DerivedData/Build/Products/Release/Kayoi.app --identity "$(SIGN_IDENTITY)" --timestamp "$(SIGN_TIMESTAMP)"
	scripts/validate-release.sh build/DerivedData/Build/Products/Release/Kayoi.app

test: gen
	./scripts/check-strings.sh
	python3 -m unittest discover -s scripts/tests -p 'test_*.py'
	xcodebuild -project Kayoi.xcodeproj -scheme KayoiTests -destination 'platform=macOS,arch=arm64' -derivedDataPath build/Tests test CODE_SIGNING_ALLOWED=NO -onlyUsePackageVersionsFromResolvedFile
	swift test --package-path Packages/Core
	swift test --package-path Packages/ADB
	swift test --package-path Packages/RicohGR
	swift test --package-path Packages/AliyunDrive
	swift test --package-path Packages/Quark
	swift test --package-path Packages/S3Drive
	swift test --package-path Packages/CloudDrive
	swift test --package-path Packages/CameraUSB
	swift test --package-path Packages/PikPakDrive
	swift test --package-path Packages/LanzouDrive
	swift test --package-path Packages/TianyiDrive
	swift test --package-path Packages/ChinaWebDrive --force-resolved-versions
	swift test --package-path Packages/DevTool --force-resolved-versions

dev-tool:
	swift build --package-path Packages/DevTool -c release --arch arm64 --arch x86_64 --force-resolved-versions
	mkdir -p build/bin
	python3 scripts/package-cli.py "$$(swift build --package-path Packages/DevTool -c release --arch arm64 --arch x86_64 --show-bin-path --force-resolved-versions)" build/bin
	codesign --force --sign "$(SIGN_IDENTITY)" --identifier com.seaony.Kayoi.dev build/bin/kayoi-dev

format:
	rg --files App Packages -g '*.swift' -0 | xargs -0 xcrun swift-format format --in-place

coverage: gen
	python3 scripts/coverage.py

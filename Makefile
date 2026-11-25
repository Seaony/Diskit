.PHONY: gen build release test coverage dev-tool format
export DISKIT_BUILD_CONFIG ?= Config/Validation.xcconfig
SIGN_IDENTITY ?= Apple Development: seaony@outlook.com
SIGN_TIMESTAMP ?= auto
RELEASE_IDENTITY ?= Developer ID Application: SHEN WANG (JJJKGPY7T7)
RELEASE_APP = build/DerivedData/Build/Products/Release/Diskit.app

gen:
	xcodegen generate
	mkdir -p Diskit.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
	cp Dependencies/Package.resolved Diskit.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved

# 开发构建由 Xcode 用付费团队自动签名：FSKit 扩展的权限必须写在团队描述文件里，事后重签会丢掉
build: gen
	xcodebuild -project Diskit.xcodeproj -scheme Diskit -configuration Debug -derivedDataPath build/DerivedData build -allowProvisioningUpdates -onlyUsePackageVersionsFromResolvedFile
	codesign --verify --deep --strict --verbose=1 build/DerivedData/Build/Products/Debug/Diskit.app

# 正式包用 Developer ID 签名：FSKit 扩展和共享钥匙串的权限靠 Config/Profiles 里的描述文件授权
release: SIGN_IDENTITY = $(RELEASE_IDENTITY)
release: SIGN_TIMESTAMP = required
release: gen dev-tool
	xcodebuild -project Diskit.xcodeproj -scheme Diskit -configuration Release -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build CODE_SIGNING_ALLOWED=NO -onlyUsePackageVersionsFromResolvedFile
	python3 scripts/sign-app.py $(RELEASE_APP) --identity "$(SIGN_IDENTITY)" --timestamp "$(SIGN_TIMESTAMP)" \
		--profile .=Config/Profiles/Diskit.provisionprofile:App/Diskit.entitlements \
		--profile Contents/Extensions/DiskitFS.appex=Config/Profiles/DiskitFS.provisionprofile:FSExtension/DiskitFS.entitlements
	scripts/validate-release.sh $(RELEASE_APP)

test: gen
	./scripts/check-strings.sh
	python3 -m unittest discover -s scripts/tests -p 'test_*.py'
	xcodebuild -project Diskit.xcodeproj -scheme DiskitTests -destination 'platform=macOS,arch=arm64' -derivedDataPath build/Tests test CODE_SIGNING_ALLOWED=NO -onlyUsePackageVersionsFromResolvedFile
	swift test --package-path Packages/Core
	swift test --package-path Packages/ADB
	swift test --package-path Packages/Quark
	swift test --package-path Packages/S3Drive
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
	codesign --force --sign "$(SIGN_IDENTITY)" --identifier com.seaony.Diskit.dev build/bin/diskit-dev

format:
	rg --files App Packages -g '*.swift' -0 | xargs -0 xcrun swift-format format --in-place

coverage: gen
	python3 scripts/coverage.py

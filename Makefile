.PHONY: gen build release test dev-tool format
SIGN_IDENTITY ?= Apple Development: seaony@outlook.com

gen:
	xcodegen generate

build: gen
	xcodebuild -project Kayoi.xcodeproj -scheme Kayoi -configuration Debug -derivedDataPath build/DerivedData build CODE_SIGNING_ALLOWED=NO
	codesign --force --deep --options runtime --timestamp=none --sign "$(SIGN_IDENTITY)" --identifier com.seaony.Kayoi build/DerivedData/Build/Products/Debug/Kayoi.app

release: gen dev-tool
	xcodebuild -project Kayoi.xcodeproj -scheme Kayoi -configuration Release -derivedDataPath build/DerivedData build CODE_SIGNING_ALLOWED=NO
	codesign --force --deep --options runtime --timestamp=none --sign "$(SIGN_IDENTITY)" --identifier com.seaony.Kayoi build/DerivedData/Build/Products/Release/Kayoi.app
	codesign --verify --deep --strict --verbose=2 build/DerivedData/Build/Products/Release/Kayoi.app

test:
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
	swift test --package-path Packages/ChinaWebDrive

dev-tool:
	swift build --package-path Packages/DevTool -c release
	mkdir -p build/bin
	cp Packages/DevTool/.build/release/kayoi-dev build/bin/kayoi-dev
	codesign --force --sign "$(SIGN_IDENTITY)" --identifier com.seaony.Kayoi.dev build/bin/kayoi-dev

format:
	rg --files App Packages -g '*.swift' -0 | xargs -0 xcrun swift-format format --in-place

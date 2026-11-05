<div align="center">

<a href="https://github.com/Seaony/Kayoi-Releases/releases/latest"><img src="docs/assets/icon-512.png" width="112" alt="Kayoi"></a>

# Kayoi

### Every location. One menu bar.

**Android phones, cameras, network shares, cloud drives and object storage, saved in one panel.**<br>
Click the menu bar icon to see what's connected and how much space is left,<br>
and mount your shares in Finder with one click.

![macOS 26+](https://img.shields.io/badge/macOS-26%2B-000000?logo=apple&logoColor=white) ![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white) ![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-0A84FF?logo=swift&logoColor=white)

**[Download](https://github.com/Seaony/Kayoi-Releases/releases/latest)** &nbsp;·&nbsp; **[Releasing](docs/RELEASING.md)** &nbsp;·&nbsp; **English** · [简体中文](README.zh-CN.md)

<br>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/product-dark-en.jpg">
  <img src="docs/assets/product-light-en.jpg" width="900" alt="Kayoi's panel open under its menu bar icon, showing a NAS, a phone, a camera and several cloud drives">
</picture>

</div>

<br>

## Is Kayoi for you?

Your files live in many places: a NAS at home, a phone on your desk, a camera in your bag, a few cloud drives and a storage bucket. Each one has its own app, its own sign-in and its own way to connect, and you end up looking them up again every time.

Kayoi keeps them all in one panel in the menu bar:

- **See everything at a glance**: each location is a card with its status and free space. Switch between cards and a compact list.
- **Mount shares in one click**: SMB, WebDAV and NFS shares mount in Finder and stay there until you eject them.
- **Connect phones and cameras without extra apps**: Kayoi speaks ADB itself, over USB or wireless debugging, and reads cameras through macOS.
- **Keep secrets in the Keychain**: passwords, tokens and cookies never go into a config file.

It's for you if you move files between several devices and services. If everything you use already lives in one cloud drive with its own Mac app, you don't need it.

> [!NOTE]
> Kayoi is early (0.2). Today only SMB, WebDAV and NFS mount in Finder. Phones, cameras, cloud drives and object storage can be saved and tested in the app; their files are reachable through the `kayoi-dev` command-line tool when you build from source. Many integrations have not been checked against real accounts and devices yet.

## Quick start

**1 · Install.** Download the DMG from the **[latest release](https://github.com/Seaony/Kayoi-Releases/releases/latest)**, open it and drag `Kayoi.app` into Applications.

<sub>Builds are universal (Apple silicon and Intel) and need macOS 26 or later. They are not signed with an Apple Developer ID or notarised yet, so the first launch may be blocked; open **System Settings → Privacy & Security** and choose to open Kayoi anyway. Kayoi updates itself from GitHub Releases through Sparkle.</sub>

**2 · Add a location.** Click the Kayoi icon in the menu bar, press **+**, pick a type and fill in what it asks for. Devices and shares Kayoi finds on your network or USB appear first. Press **Test and Save**.

**3 · Use it.** Click a card for its actions: mount or eject a share, test a phone or drive again, edit, reorder or delete. Mounted shares show up in Finder's sidebar under Locations.

## Supported locations

<table>
<tr><td><b>Devices</b></td><td>Android phone (USB) · Android phone (wireless debugging) · Ricoh GR IV · USB cameras</td></tr>
<tr><td><b>Shares</b></td><td>SMB · WebDAV (HTTP and HTTPS, with presets for Jianguoyun, Nextcloud, ownCloud, Synology, QNAP and OpenList) · NFS</td></tr>
<tr><td><b>Cloud drives</b></td><td>Aliyun Drive · Baidu Netdisk · 115 Drive · 123 Drive · OneDrive · Google Drive · Dropbox</td></tr>
<tr><td><b>Experimental drives</b></td><td>Quark Drive · UC Drive · Tianyi Cloud · Mobile Cloud · Xunlei Drive · PikPak · Lanzou Cloud (read-only)</td></tr>
<tr><td><b>Object storage</b></td><td>Amazon S3 · Cloudflare R2 · Alibaba Cloud OSS · Tencent Cloud COS · Qiniu Kodo · MinIO · Backblaze B2</td></tr>
</table>

Official cloud drives sign in through each provider's own authorisation page. Experimental drives sign in through the provider's website or with your account and password, and use unofficial interfaces, so they may stop working when the provider changes its site.

## What it does

### A panel, not another window

Kayoi lives in the menu bar with no Dock icon. The panel shows every saved location as a card or a row, with a status dot and the space left. Drag to reorder, right-click for actions, and use the keyboard: arrow keys to select, Return for the main action, ⌘N to add, ⌘E to edit. The menu bar icon fills in when something is mounted and flags locations that need attention.

### Shares in Finder

SMB, WebDAV and NFS shares mount through macOS, so Finder and every other app see them as normal volumes. Kayoi can list the shares on an SMB server, checks your password before saving, and leaves system mounts in place when you quit.

### Phones and cameras

Android phones connect over USB debugging or Android 11+ wireless debugging with a pairing code. Kayoi implements the ADB protocol itself, so there's no `adb` to install and nothing to add to the phone. Ricoh GR IV and other USB cameras are read through macOS Image Capture; their photos stay untouched unless the camera allows deleting.

### Built for macOS

Native SwiftUI and AppKit. Light and dark appearance. English and Simplified Chinese. Launch at login and in-app updates.

## Privacy

- Passwords, tokens and cookies are stored in your login Keychain.
- Saved locations live in `~/Library/Application Support/Kayoi/connections.json`, without any secrets. Caches stay in `~/Library/Caches/Kayoi/`, and error logs are kept for 7 days.
- Kayoi has no analytics. Besides looking for phones, cameras and shares on your local network and over USB, it talks only to the devices and services you add, and to Kayoi's GitHub Releases feed for updates.

## Build from source

You need Xcode 27 and XcodeGen (`brew install xcodegen`).

```sh
git clone https://github.com/Seaony/Kayoi.git
cd Kayoi
make build
open build/DerivedData/Build/Products/Debug/Kayoi.app
```

`make` signs with the maintainer's Apple Development identity; pass `SIGN_IDENTITY='Apple Development: you@example.com'` to use your own. `make test` runs the tests, `make release` builds a universal app and `make dev-tool` builds `build/bin/kayoi-dev`. Cloud drives that need app credentials read them from `Config/Secrets.xcconfig`: copy `Config/Secrets.example.xcconfig`, fill it in, and build with `make build KAYOI_BUILD_CONFIG=Config/App.xcconfig` (the default build ignores it). See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for every location type, the demo mode and the command-line tool, and [docs/RELEASING.md](docs/RELEASING.md) for releases.

## Acknowledgements

The panel design takes its cue from [SideMount](https://sidemount.app/). ADB follows [AOSP](https://android.googlesource.com/platform/packages/modules/adb/), wireless pairing uses [BoringSSL](https://boringssl.googlesource.com/boringssl/), and several cloud drive behaviours were checked against [rclone](https://github.com/rclone/rclone). Updates use [Sparkle](https://sparkle-project.org/). See [docs/THIRD_PARTY_NOTICES.md](docs/THIRD_PARTY_NOTICES.md) for the full list.

---

<div align="center">
  <sub>Wherever your files live, one click from the menu bar.</sub>
</div>

// 把演示模式导出的真实面板截图合成为 README 产品图。
// 用法：swift tools/product-shot.swift <面板 PNG> <图标 PNG> <dark|light> <en|zh> <输出 JPEG>
import AppKit
import SwiftUI

let arguments = CommandLine.arguments
guard arguments.count == 6,
  let panel = NSImage(contentsOfFile: arguments[1]),
  let icon = NSImage(contentsOfFile: arguments[2])
else {
  FileHandle.standardError.write(Data("用法：swift tools/product-shot.swift <面板 PNG> <图标 PNG> <dark|light> <en|zh> <输出 JPEG>\n".utf8))
  exit(1)
}
let dark = arguments[3] == "dark"
let english = arguments[4] == "en"
let output = URL(filePath: arguments[5])

// 截图是 2 倍像素，按点数摆放
let panelSize = CGSize(
  width: CGFloat(panel.representations[0].pixelsWide) / 2,
  height: CGFloat(panel.representations[0].pixelsHigh) / 2)
panel.size = panelSize

struct Canvas: View {
  let panel: NSImage
  let icon: NSImage
  let dark: Bool
  let english: Bool

  private let size = CGSize(width: 1040, height: 640)
  private let screen = CGRect(x: 470, y: 52, width: 528, height: 536)
  private var ink: Color { dark ? .white : Color(red: 0.07, green: 0.09, blue: 0.14) }
  // Kayoi 的强调色
  private let accent = Color(red: 0x2A / 255, green: 0x72 / 255, blue: 0xE5 / 255)

  var body: some View {
    ZStack(alignment: .topLeading) {
      background
      copy
        .frame(width: 392, alignment: .leading)
        .offset(x: 64)
        .frame(maxHeight: .infinity, alignment: .center)
      screenView
        .frame(width: screen.width, height: screen.height)
        .offset(x: screen.minX, y: screen.minY)
    }
    .frame(width: size.width, height: size.height)
    .environment(\.colorScheme, dark ? .dark : .light)
  }

  private var background: some View {
    ZStack {
      LinearGradient(
        colors: dark
          ? [Color(red: 0.04, green: 0.06, blue: 0.11), Color(red: 0.06, green: 0.09, blue: 0.17)]
          : [Color(red: 0.94, green: 0.96, blue: 1.0), Color(red: 0.99, green: 0.96, blue: 0.94)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
      Circle().fill(accent.opacity(dark ? 0.34 : 0.24))
        .frame(width: 560, height: 560).blur(radius: 120).offset(x: 260, y: -170)
      // 暖色呼应图标里的花
      Circle().fill(Color(red: 0.96, green: 0.52, blue: 0.36).opacity(dark ? 0.2 : 0.18))
        .frame(width: 480, height: 480).blur(radius: 120).offset(x: -300, y: 230)
    }
    .frame(width: size.width, height: size.height)
    .clipped()
  }

  private var copy: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        // 图标自带圆角和投影
        Image(nsImage: icon).resizable().frame(width: 44, height: 44)
          .padding(-4)
        Text("Kayoi").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(ink)
      }
      .padding(.bottom, 26)
      Text(english ? "Every location.\nOne menu bar." : "手机、共享、网盘，\n都在菜单栏。")
        .font(.system(size: english ? 44 : 40, weight: .heavy, design: .rounded))
        .foregroundStyle(ink).lineSpacing(2)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 18)
      Text(english
        ? "Android phones, cameras, network shares, cloud drives and object storage, saved in one panel."
        : "安卓手机、相机、局域网共享、网盘和对象存储，\n收进同一个面板。")
        .font(.system(size: 16, weight: .medium, design: .rounded))
        .foregroundStyle(ink.opacity(0.62)).lineSpacing(4)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  // 模拟一块屏幕：面板从菜单栏的 Kayoi 图标下弹出，背后是 Finder
  private var screenView: some View {
    ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .fill(LinearGradient(
          colors: dark
            ? [Color(red: 0.11, green: 0.14, blue: 0.23), Color(red: 0.06, green: 0.08, blue: 0.14)]
            : [Color(red: 0.82, green: 0.89, blue: 0.99), Color(red: 0.96, green: 0.9, blue: 0.88)],
          startPoint: .top, endPoint: .bottom))
      finder
        .frame(width: 300, height: 340)
        .offset(x: 8, y: 150)
      Image(nsImage: panel)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(ink.opacity(dark ? 0.14 : 0.1), lineWidth: 1)
        }
        .shadow(color: .black.opacity(dark ? 0.45 : 0.18), radius: 24, y: 10)
        .offset(x: screen.width - panelSize.width - 22, y: 32)
      menuBar
    }
    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .strokeBorder(ink.opacity(dark ? 0.12 : 0.08), lineWidth: 1)
    }
    .shadow(color: .black.opacity(dark ? 0.5 : 0.14), radius: 40, y: 20)
  }

  // 屏幕顶部的菜单栏，只是装饰；Kayoi 图标处于按下状态
  private var menuBar: some View {
    HStack(spacing: 14) {
      Image(systemName: "apple.logo").font(.system(size: 12, weight: .semibold))
      ForEach([34, 28, 40, 30], id: \.self) { width in
        Capsule().frame(width: CGFloat(width), height: 5).opacity(0.45)
      }
      Spacer()
      Image(systemName: "externaldrive.fill").font(.system(size: 11, weight: .semibold))
        .frame(width: 30, height: 18)
        .background(ink.opacity(dark ? 0.18 : 0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
      ForEach([14, 18], id: \.self) { width in
        RoundedRectangle(cornerRadius: 2).frame(width: CGFloat(width), height: 8).opacity(0.45)
      }
      Text("9:41").font(.system(size: 11, weight: .semibold))
    }
    .foregroundStyle(ink.opacity(0.75))
    .padding(.horizontal, 18)
    .frame(height: 24)
    .frame(maxWidth: .infinity)
    .background(dark ? Color.white.opacity(0.05) : Color.white.opacity(0.4))
  }

  // 背景里的 Finder 窗口：侧栏“位置”里是已挂载的共享，降低存在感
  private var finder: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 9) {
        HStack(spacing: 6) {
          ForEach([Color.red, .yellow, .green], id: \.self) { color in
            Circle().fill(color.opacity(0.7)).frame(width: 9, height: 9)
          }
        }
        .padding(.bottom, 14)
        Text(english ? "Locations" : "位置")
          .font(.system(size: 9, weight: .semibold)).foregroundStyle(ink.opacity(0.4))
        ForEach(["Synology NAS", "Nextcloud"], id: \.self) { name in
          HStack(spacing: 5) {
            Image(systemName: "externaldrive.fill").font(.system(size: 9))
              .foregroundStyle(accent)
            Text(name).font(.system(size: 10, weight: .medium)).foregroundStyle(ink.opacity(0.75)).lineLimit(1)
            Spacer(minLength: 0)
          }
        }
        Spacer()
      }
      .padding(10)
      .frame(width: 118)
      .background(ink.opacity(dark ? 0.04 : 0.05))
      VStack(alignment: .leading, spacing: 18) {
        Capsule().fill(ink.opacity(0.18)).frame(width: 90, height: 7).padding(.top, 14)
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 14), count: 3), spacing: 16) {
          ForEach(0..<9, id: \.self) { index in
            VStack(spacing: 6) {
              Image(systemName: "folder.fill").font(.system(size: 26))
                .foregroundStyle(accent.opacity(dark ? 0.55 : 0.45))
              Capsule().fill(ink.opacity(0.18)).frame(width: index % 2 == 0 ? 34 : 26, height: 5)
            }
          }
        }
        Spacer()
      }
      .padding(.horizontal, 14)
      .frame(maxWidth: .infinity)
    }
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(dark ? Color.white.opacity(0.06) : Color.white.opacity(0.55)))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(ink.opacity(0.08), lineWidth: 1))
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
  }
}

MainActor.assumeIsolated {
  let renderer = ImageRenderer(content: Canvas(panel: panel, icon: icon, dark: dark, english: english))
  renderer.scale = 2
  guard let image = renderer.nsImage,
    let tiff = image.tiffRepresentation,
    let rep = NSBitmapImageRep(data: tiff),
    // 质量 0.88 时渐变和文字没有明显压缩痕迹
    let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.88])
  else {
    FileHandle.standardError.write(Data("合成失败\n".utf8))
    exit(1)
  }
  do { try data.write(to: output) } catch {
    FileHandle.standardError.write(Data("写入失败：\(error.localizedDescription)\n".utf8))
    exit(1)
  }
}

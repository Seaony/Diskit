import Core
import SwiftUI

struct ConnectionTypePicker: View {
  @Bindable var editor: ConnectionEditorModel
  @FocusState private var focus: Focus?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  // 只有按方向键在卡片间移动后才画焦点框，鼠标操作和返回后都不显示
  @State private var navigatingByKeyboard = false
  private var gridFocused: Bool { focus == .grid && navigatingByKeyboard }
  private enum Focus { case search, grid }
  private var groups: [ConnectionTypeGroup] { ConnectionTypeCatalog.matching(editor.search) }
  private var discovered: [DiscoveredItem] {
    let query = editor.search.trimmingCharacters(in: .whitespaces).lowercased()
    return editor.model.discoveredItems.filter {
      query.isEmpty || ($0.title + " " + $0.subtitle + " " + $0.kind.title).lowercased().contains(query)
    }
  }

  private func groupTitle(_ title: String) -> some View {
    Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(DiskitTheme.secondaryText)
      .padding(.horizontal, Space.xs)
  }

  private let columns = Array(repeating: GridItem(.flexible(), spacing: Space.sm), count: 4)

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: Space.sm) {
        Image(systemName: "magnifyingglass").foregroundStyle(DiskitTheme.secondaryText)
          .accessibilityHidden(true)
        TextField(L("搜索类型，例如 网盘、SMB、相机"), text: $editor.search)
          .textFieldStyle(.plain).focused($focus, equals: .search)
          .onSubmit { editor.chooseSelected() }
          .onKeyPress(.downArrow) {
            focus = .grid
            navigatingByKeyboard = true
            editor.moveSelection(1)
            return .handled
          }
        if !editor.search.isEmpty {
          Button {
            editor.search = ""
            focus = .search
          } label: {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.plain).pointerStyle(.link).help(L("清除搜索")).accessibilityLabel(L("清除搜索"))
        }
      }
      .padding(.horizontal, Space.md).frame(height: 40)
      .background(
        DiskitTheme.surface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(DiskitTheme.border, lineWidth: 0.5)
      }
      .padding(.horizontal, Space.xxl).padding(.top, Space.xs)
      ScrollView {
        VStack(alignment: .leading, spacing: Space.lg) {
          // 已发现的设备排在最前，选中后第二步带上预填信息
          if !discovered.isEmpty {
            VStack(alignment: .leading, spacing: Space.sm) {
              groupTitle(L("已发现"))
              LazyVGrid(columns: columns, spacing: Space.md) {
                ForEach(discovered) { item in
                  // 点一下直接进入第二步
                  Button {
                    editor.selectedDiscovery = item
                    editor.chooseSelected()
                  } label: {
                    ConnectionTypeTile(kind: item.kind, title: item.title, subtitle: item.subtitle)
                  }
                  .buttonStyle(ConnectionCardStyle())
                  .help(item.title + " · " + item.subtitle)
                  .accessibilityLabel(LF("添加“%@”", item.title)).accessibilityValue(item.subtitle)
                }
              }
            }
          }
          ForEach(groups) { group in
            VStack(alignment: .leading, spacing: Space.sm) {
              groupTitle(group.title)
              LazyVGrid(columns: columns, spacing: Space.md) {
                ForEach(group.kinds, id: \.self) { kind in
                  // 点一下直接进入第二步
                  Button {
                    editor.selectedKind = kind
                    editor.choose(kind)
                  } label: {
                    ConnectionTypeTile(kind: kind)
                      .gridProbe("type-" + kind.rawValue, area: "editor-types", edge: nil)
                  }
                  .buttonStyle(ConnectionCardStyle(
                    focused: ConnectionTypeFocus.isFocused(kind, selection: editor.selectedKind, gridFocused: gridFocused)))
                  .help(kind.title + " · " + ConnectionTypeCatalog.caption(kind))
                  .accessibilityLabel(kind.title).accessibilityValue(
                    ConnectionTypeCatalog.caption(kind)
                  )
                  .accessibilityAddTraits(ConnectionTypeFocus.isFocused(kind, selection: editor.selectedKind, gridFocused: gridFocused) ? .isSelected : [])
                }
              }
            }
          }
          if groups.isEmpty && discovered.isEmpty {
            ContentUnavailableView(
              L("没有匹配的位置类型"), systemImage: "magnifyingglass", description: Text(L("换个关键词试试"))
            )
            .frame(maxWidth: .infinity).padding(.vertical, Space.xl)
          }
        }.padding(.horizontal, Space.xxl).padding(.top, Space.lg).padding(.bottom, Space.xxl)
          .animation(Motion.change(reduceMotion: reduceMotion), value: editor.search)
          .gridArea("editor-types", inset: Space.xl)
      }
      .focusable().focusEffectDisabled().focused($focus, equals: .grid)
      .onMoveCommand { direction in
        navigatingByKeyboard = true
        switch direction {
        case .left: editor.moveSelection(-1)
        case .right: editor.moveSelection(1)
        case .up: editor.moveSelection(-columns.count)
        case .down: editor.moveSelection(columns.count)
        @unknown default: break
        }
      }
      .onKeyPress(.return) {
        editor.chooseSelected()
        return .handled
      }
    }
    .onChange(of: editor.search) { _, _ in
      editor.selectedDiscovery = nil
      editor.selectedKind = groups.flatMap(\.kinds).first
    }
    .task { focus = .search }
  }
}

#Preview("light · 全部") {
  EditorPreview(inForm: false, search: "") { ConnectionTypePicker(editor: $0) }
    .preferredColorScheme(.light)
}

#Preview("light · 空结果") {
  EditorPreview(inForm: false, search: "nothing-matches") { ConnectionTypePicker(editor: $0) }
    .preferredColorScheme(.light)
}

#Preview("light · 搜索") {
  EditorPreview(inForm: false, search: "wp") { ConnectionTypePicker(editor: $0) }
    .preferredColorScheme(.light)
}

#Preview("dark · 全部") {
  EditorPreview(inForm: false, search: "") { ConnectionTypePicker(editor: $0) }
    .preferredColorScheme(.dark)
}

#Preview("dark · 空结果") {
  EditorPreview(inForm: false, search: "nothing-matches") { ConnectionTypePicker(editor: $0) }
    .preferredColorScheme(.dark)
}

#Preview("dark · 搜索") {
  EditorPreview(inForm: false, search: "wp") { ConnectionTypePicker(editor: $0) }
    .preferredColorScheme(.dark)
}

import Core
import SwiftUI

struct ConnectionTypePicker: View {
  @Bindable var editor: ConnectionEditorModel
  @FocusState private var focus: Focus?
  private enum Focus { case search, grid }
  private var groups: [ConnectionTypeGroup] { ConnectionTypeCatalog.matching(editor.search) }
  private var discovered: [DiscoveredItem] {
    let query = editor.search.trimmingCharacters(in: .whitespaces).lowercased()
    return editor.model.discoveredItems.filter {
      query.isEmpty || ($0.title + " " + $0.subtitle + " " + $0.kind.title).lowercased().contains(query)
    }
  }

  private func groupTitle(_ title: String) -> some View {
    Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(KayoiTheme.secondaryText)
      .padding(.horizontal, Space.xs)
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: Space.sm) {
        Image(systemName: "magnifyingglass").foregroundStyle(KayoiTheme.secondaryText)
          .accessibilityHidden(true)
        TextField(L("搜索类型，例如 网盘、SMB、相机"), text: $editor.search)
          .textFieldStyle(.plain).focused($focus, equals: .search)
          .onSubmit { editor.chooseSelected() }
          .onKeyPress(.downArrow) {
            focus = .grid
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
      .padding(.horizontal, 10).frame(height: 32) // grid: ok 设计稿搜索框高 32
      .background(
        KayoiTheme.surface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
      )
      .padding(.horizontal, Space.xxl).padding(.top, Space.xs)
      ScrollView {
        VStack(alignment: .leading, spacing: Space.lg) {
          // 已发现的设备排在最前，选中后第二步带上预填信息
          if !discovered.isEmpty {
            VStack(alignment: .leading, spacing: Space.sm) {
              groupTitle(L("已发现"))
              LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.sm), count: 4), spacing: Space.sm) {
                ForEach(discovered) { item in
                  Button {
                    editor.selectedDiscovery = item
                  } label: {
                    ConnectionTypeTile(kind: item.kind, title: item.title, selected: editor.selectedDiscovery?.id == item.id)
                  }
                  .buttonStyle(ConnectionCardStyle(selected: editor.selectedDiscovery?.id == item.id))
                  .simultaneousGesture(TapGesture(count: 2).onEnded {
                    editor.selectedDiscovery = item
                    editor.chooseSelected()
                  })
                  .disabled(item.connection == nil)
                  .help(item.title + " · " + item.subtitle)
                  .accessibilityLabel(LF("添加“%@”", item.title)).accessibilityValue(item.subtitle)
                  .accessibilityAddTraits(editor.selectedDiscovery?.id == item.id ? .isSelected : [])
                }
              }
            }
          }
          ForEach(groups) { group in
            VStack(alignment: .leading, spacing: Space.sm) {
              groupTitle(group.title)
              LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: Space.sm), count: 4),
                spacing: Space.sm
              ) {
                ForEach(group.kinds, id: \.self) { kind in
                  Button {
                    editor.selectedDiscovery = nil
                    editor.selectedKind = kind
                    focus = .grid
                  } label: {
                    ConnectionTypeTile(kind: kind, marksExperimental: group.title == L("实验性网盘"), selected: editor.selectedKind == kind)
                      .gridProbe("type-" + kind.rawValue, area: "editor-types", edge: nil)
                  }
                  .buttonStyle(ConnectionCardStyle(
                    selected: editor.selectedKind == kind,
                    focused: ConnectionTypeFocus.isFocused(kind, selection: editor.selectedKind, gridFocused: focus == .grid)))
                  .simultaneousGesture(TapGesture(count: 2).onEnded { editor.choose(kind) })
                  .help(kind.title + " · " + ConnectionTypeCatalog.caption(kind))
                  .accessibilityLabel(kind.title).accessibilityValue(
                    ConnectionTypeCatalog.caption(kind)
                  )
                  .accessibilityAddTraits(editor.selectedKind == kind ? .isSelected : [])
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
        }.padding(.horizontal, Space.xxl).padding(.top, 14).padding(.bottom, Space.sm) // grid: ok 设计稿搜索框下 14
          .gridArea("editor-types", inset: Space.xl)
      }
      .focusable().focusEffectDisabled().focused($focus, equals: .grid)
      .onMoveCommand { direction in
        switch direction {
        case .left: editor.moveSelection(-1)
        case .right: editor.moveSelection(1)
        case .up: editor.moveSelection(-4)
        case .down: editor.moveSelection(4)
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

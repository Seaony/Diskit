import Core
import SwiftUI

struct ConnectionTypePicker: View {
  @Bindable var editor: ConnectionEditorModel
  @FocusState private var focus: Focus?
  private enum Focus { case search, grid }
  private var groups: [ConnectionTypeGroup] { ConnectionTypeCatalog.matching(editor.search) }

  var body: some View {
    VStack(spacing: Space.lg) {
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
          .buttonStyle(.plain).help(L("清除搜索")).accessibilityLabel(L("清除搜索"))
        }
      }
      .padding(Space.sm)
      .background(
        KayoiTheme.controlFill, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
      )
      .padding(.horizontal, Space.xl).padding(.top, Space.xl)
      ScrollView {
        VStack(alignment: .leading, spacing: Space.xl) {
          ForEach(groups) { group in
            VStack(alignment: .leading, spacing: Space.sm) {
              Text(group.title).font(.subheadline.weight(.semibold)).foregroundStyle(
                KayoiTheme.secondaryText)
              LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: Space.sm), count: 4),
                spacing: Space.sm
              ) {
                ForEach(group.kinds, id: \.self) { kind in
                  Button {
                    editor.selectedKind = kind
                    focus = .grid
                  } label: {
                    ConnectionTypeTile(kind: kind, marksExperimental: group.title != L("实验性网盘"))
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
          if groups.isEmpty {
            ContentUnavailableView(
              L("没有匹配的位置类型"), systemImage: "magnifyingglass", description: Text(L("换个关键词试试"))
            )
            .frame(maxWidth: .infinity).padding(.vertical, Space.xl)
          }
        }.padding(.horizontal, Space.xl).padding(.bottom, Space.xl)
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
    .onChange(of: editor.search) { _, _ in editor.selectedKind = groups.flatMap(\.kinds).first }
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

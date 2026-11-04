import Core
import SwiftUI

struct HelpView: View {
  @SceneStorage("help.selectedType") private var selectedType = ConnectionKind.androidUSB.rawValue
  @State private var search = ""

  init(search: String = "") { _search = State(initialValue: search) }

  private var filteredGuides: [HelpGuide] {
    HelpGuide.all.filter { $0.matches(search, title: $0.kind.title) }
  }

  private var selection: Binding<ConnectionKind?> {
    Binding(
      get: { ConnectionKind(rawValue: selectedType) },
      set: { if let kind = $0 { selectedType = kind.rawValue } })
  }

  private var selectedGuide: HelpGuide? {
    filteredGuides.first { $0.id == selectedType } ?? filteredGuides.first
  }

  var body: some View {
    NavigationSplitView {
      List(selection: selection) {
        ForEach(HelpGroup.allCases) { group in
          let guides = filteredGuides.filter { $0.group == group }
          if !guides.isEmpty {
            Section(group.title) {
              ForEach(guides) { guide in
                HStack(spacing: Space.sm) {
                  TypeIcon(kind: guide.kind, size: 24)
                  Text(guide.kind.title)
                    .font(.body)
                    .lineLimit(2)
                    .help(guide.kind.title)
                }
                .frame(minHeight: 32)
                .tag(guide.kind)
                .accessibilityLabel(guide.kind.title)
              }
            }
          }
        }
      }
      .listStyle(.sidebar)
      .scrollContentBackground(.hidden)
      .background(KayoiTheme.background)
      .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
      .searchable(text: $search, placement: .sidebar, prompt: L("搜索类型或问题"))
    } detail: {
      if let guide = selectedGuide {
        HelpGuideDetail(guide: guide)
      } else {
        ContentUnavailableView.search(text: search)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(KayoiTheme.background)
      }
    }
    .navigationSplitViewStyle(.balanced)
    .background(KayoiTheme.background)
    .frame(minWidth: 640, minHeight: 480)
    .onChange(of: filteredGuides.map(\.id), initial: true) { _, identifiers in
      if !identifiers.contains(selectedType), let first = identifiers.first { selectedType = first }
    }
  }
}

#Preview("帮助 · 浅色") { HelpView().preferredColorScheme(.light) }
#Preview("帮助 · 深色") { HelpView().preferredColorScheme(.dark) }
#Preview("帮助 · 搜索为空") { HelpView(search: "__no_matching_guide__") }

import SwiftUI
import AppKit

@main
struct AppSweepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = Model.shared
    @AppStorage(Sounds.enabledKey) private var soundEnabled = true

    var body: some Scene {
        Window("AppSweep", id: "main") {
            ContentView().environmentObject(model)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 540, height: 470)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(after: .appInfo) {
                Button("检查更新…") { Task { await Updater.shared.check(userInitiated: true) } }
                Toggle("音效", isOn: $soundEnabled)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in Updater.shared.checkOnLaunchIfNeeded() }
    }
    // Apps dropped onto the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in Model.shared.open(urls) }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: Model
    @ObservedObject private var updater = Updater.shared
    @State private var dropTargeted = false
    @State private var showAppList = false

    var body: some View {
        Group {
            switch model.phase {
            case .idle: DropZoneView(targeted: dropTargeted)
            case .scanning: BusyView(text: "正在查找相关文件…")
            case .results: ResultsView()
            case .removing: BusyView(text: "正在移到废纸篓…")
            case let .done(freed, removed, failed): DoneView(freed: freed, removed: removed, failed: failed)
            }
        }
        .frame(minWidth: 440, idealWidth: 540, maxWidth: .infinity,
               minHeight: 380, idealHeight: 470, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .dropDestination(for: URL.self) { urls, _ in
            model.open(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if updater.isDownloading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在下载更新…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.choose() } label: { Image(systemName: "square.and.arrow.down") }
                    .help("选择应用…")
                Button { showAppList = true } label: { Image(systemName: "list.bullet") }
                    .help("已安装的应用")
            }
        }
        .sheet(isPresented: $showAppList) {
            AppListView { url in
                showAppList = false
                model.open([url])
            }
        }
    }
}

// MARK: - Drop zone

struct DropZoneView: View {
    let targeted: Bool

    var body: some View {
        GeometryReader { geo in
            let box = min(max(min(geo.size.width, geo.size.height) * 0.42, 140), 360)
            content(box: box, scale: box / 190)
                .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func content(box: CGFloat, scale: CGFloat) -> some View {
        VStack(spacing: 28 * scale) {
            ZStack {
                RoundedRectangle(cornerRadius: 30 * scale, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 5 * scale, lineCap: .round, dash: [18 * scale, 12 * scale]))
                    .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.55))
                    .background(
                        RoundedRectangle(cornerRadius: 30 * scale, style: .continuous)
                            .fill(targeted ? Color.accentColor.opacity(0.08) : .clear)
                    )
                Image(systemName: "shippingbox")
                    .font(.system(size: 72 * scale, weight: .light))
                    .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.75))
            }
            .frame(width: box, height: box)
            .scaleEffect(targeted ? 1.05 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: targeted)

            VStack(spacing: 6) {
                (Text("把应用").fontWeight(.light) + Text("拖到这里").fontWeight(.medium))
                    .font(.system(size: 30 * min(scale, 1.4)))
                    .foregroundStyle(.primary.opacity(0.8))
                Text("自动找出它散落在系统各处的所有文件")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct BusyView: View {
    let text: String
    var body: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Results

struct ResultsView: View {
    @EnvironmentObject var model: Model

    private var allSelected: Binding<Bool> {
        Binding(
            get: { !model.items.isEmpty && model.items.allSatisfy(\.selected) },
            set: { v in for i in model.items.indices { model.items[i].selected = v } }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("找到 \(model.items.count) 个项目")
                    .font(.system(size: 24, weight: .regular))
                Text("·").foregroundStyle(.secondary)
                Text(formatBytes(model.selectedSize))
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                    .contentTransition(.numericText())
                Spacer()
                Toggle("全选", isOn: allSelected)
                    .toggleStyle(.checkbox)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .background(Color.primary.opacity(0.03))

            Divider()

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        ItemRow(item: $model.items[index], striped: index % 2 == 1)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            Divider()

            HStack(spacing: 12) {
                Text("将移到废纸篓，可随时恢复")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { model.reset() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                    .frame(minWidth: 90)
                Button("删除 \(model.selectedCount) 项") { model.removeSelected() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.selectedCount == 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }
}

struct ItemRow: View {
    @Binding var item: FoundItem
    let striped: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: $item.selected)
                .toggleStyle(.checkbox)
                .labelsHidden()

            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 14))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(item.displayPath)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(item.url.path)

            Spacer(minLength: 8)

            Text(formatBytes(item.size))
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(.secondary)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            } label: {
                Image(systemName: "magnifyingglass.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("在访达中显示")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? Color.accentColor.opacity(0.08)
                      : striped ? Color.primary.opacity(0.035) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { item.selected.toggle() }
        .onHover { hovering = $0 }
        .opacity(item.selected ? 1 : 0.55)
    }
}

// MARK: - Done

struct DoneView: View {
    @EnvironmentObject var model: Model
    let freed: Int64
    let removed: Int
    let failed: [String]

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(failed.isEmpty ? Color.green : Color.orange)
            Text("已将 \(removed) 个项目移到废纸篓")
                .font(.system(size: 22))
            Text("释放 \(formatBytes(freed))")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
            if !failed.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("以下 \(failed.count) 项未能删除：").font(.callout).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(failed, id: \.self) {
                                Text($0).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                    .frame(maxHeight: 80)
                }
                .padding(.horizontal, 40)
            }
            HStack {
                Button("打开废纸篓") {
                    NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
                }
                Button("完成") { model.reset() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Installed apps list

struct AppListView: View {
    let onPick: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var apps: [URL] = []
    @State private var query = ""

    private var filtered: [URL] {
        query.isEmpty ? apps : apps.filter {
            $0.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索应用", text: $query).textFieldStyle(.plain)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            .padding(12)

            List(filtered, id: \.self) { url in
                Button { onPick(url) } label: {
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable().frame(width: 28, height: 28)
                        Text(url.deletingPathExtension().lastPathComponent)
                        Spacer()
                        Text((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            HStack {
                Text("\(filtered.count) 个应用").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 460, height: 520)
        .task { apps = Scanner.installedApps() }
    }
}

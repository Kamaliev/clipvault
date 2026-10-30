import AppKit
import SwiftUI

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published var query = "" {
        didSet { if query != oldValue { selection = 0; reload() } }
    }
    @Published private(set) var items: [ClipSummary] = []
    @Published var selection = 0
    @Published private(set) var accessibilityGranted = true
    @Published var focusToken = UUID()

    var onChoose: ((Int64) -> Void)?
    private let store: Store
    private let thumbnails = NSCache<NSNumber, NSImage>()

    init(store: Store) {
        self.store = store
    }

    func prepare(accessibilityGranted: Bool) {
        self.accessibilityGranted = accessibilityGranted
        query = ""
        selection = 0
        reload()
        focusToken = UUID()
    }

    func reload() {
        let q = query.trimmingCharacters(in: .whitespaces)
        do {
            items = try store.list(query: q.isEmpty ? nil : q, limit: 300)
        } catch {
            NSLog("clipvault: list failed: \(error)")
            items = []
        }
        selection = min(selection, max(items.count - 1, 0))
    }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selection = min(max(selection + delta, 0), items.count - 1)
    }

    func choose(index: Int) {
        guard items.indices.contains(index) else { return }
        onChoose?(items[index].id)
    }

    func chooseSelected() { choose(index: selection) }

    func deleteSelected() {
        guard items.indices.contains(selection) else { return }
        try? store.delete(id: items[selection].id)
        reload()
    }

    func thumbnail(for item: ClipSummary) -> NSImage? {
        guard item.hasThumbnail else { return nil }
        let key = NSNumber(value: item.id)
        if let cached = thumbnails.object(forKey: key) { return cached }
        guard let data = try? store.thumbnail(id: item.id), let image = NSImage(data: data) else { return nil }
        thumbnails.setObject(image, forKey: key)
        return image
    }
}

struct HistoryView: View {
    @ObservedObject var model: HistoryViewModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search history", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($searchFocused)
            }
            .padding(.horizontal, 14)
            .padding(.top, 30)
            .padding(.bottom, 10)

            Divider()

            if model.items.isEmpty {
                Spacer()
                Text(model.query.isEmpty ? "History is empty" : "No results")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                                HistoryRow(item: item, index: index, selected: index == model.selection,
                                           thumbnail: model.thumbnail(for: item))
                                    .id(item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) { model.choose(index: index) }
                                    .onTapGesture { model.selection = index }
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: model.selection) { _, new in
                        if model.items.indices.contains(new) { proxy.scrollTo(model.items[new].id) }
                    }
                }
            }

            Divider()
            HStack {
                Text("⏎ paste · ⌘1–9 select · ⌘⌫ delete · esc")
                    .lineLimit(1)
                Spacer(minLength: 8)
                if !model.accessibilityGranted {
                    Text("No Accessibility access: copy only")
                        .lineLimit(1)
                        .foregroundStyle(.orange)
                        .help("Grant access from the Clipvault menu to enable auto-paste")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.regularMaterial)
        .onChange(of: model.focusToken) { _, _ in searchFocused = true }
        .onAppear { searchFocused = true }
    }
}

struct HistoryRow: View {
    let item: ClipSummary
    let index: Int
    let selected: Bool
    let thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: icon).font(.system(size: 16)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(2).font(.system(size: 13))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if index < 9 {
                Text("⌘\(index + 1)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.25) : .clear))
    }

    private var icon: String {
        switch item.kind {
        case .text: "doc.plaintext"
        case .rtf: "doc.richtext"
        case .html: "globe"
        case .image: "photo"
        case .files: "folder"
        }
    }

    private var title: String {
        if item.kind == .image { return "Image · " + ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file) }
        return item.preview.isEmpty ? "(no text)" : item.preview
    }

    private var subtitle: String {
        let date = Date(timeIntervalSince1970: TimeInterval(item.createdAt))
        let rel = Date().timeIntervalSince(date) < 60
            ? "just now"
            : Self.relative.localizedString(for: date, relativeTo: Date())
        return [item.sourceApp, rel].compactMap { $0 }.joined(separator: " · ")
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}

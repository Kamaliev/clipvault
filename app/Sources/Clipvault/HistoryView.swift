import AppKit
import SwiftUI

struct ClipPreview: Equatable {
    let id: Int64
    let text: String?
    let image: NSImage?
    let title: String
    let subtitle: String
}

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published var query = "" {
        didSet { if query != oldValue { selection = 0; reload() } }
    }
    @Published private(set) var items: [ClipSummary] = []
    @Published var selection = 0 {
        didSet { if selection != oldValue, preview != nil { loadPreview() } }
    }
    @Published private(set) var accessibilityGranted = true
    @Published private(set) var preview: ClipPreview?
    @Published var focusToken = UUID()

    var onAction: ((ClipAction, Int64) -> Void)?
    var onSequence: (([Int64]) -> Void)?
    private let store: Store
    private let thumbnails = NSCache<NSNumber, NSImage>()

    init(store: Store) {
        self.store = store
    }

    func prepare(accessibilityGranted: Bool) {
        self.accessibilityGranted = accessibilityGranted
        preview = nil
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
        if preview != nil { loadPreview() }
    }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selection = min(max(selection + delta, 0), items.count - 1)
    }

    func choose(index: Int) { perform(.paste, index: index) }

    func perform(_ action: ClipAction, index: Int? = nil) {
        let index = index ?? selection
        guard items.indices.contains(index) else { return }
        onAction?(action, items[index].id)
    }

    /// Pastes the item and then, on each "Paste Next" hotkey press, the next newer one.
    func startSequence(index: Int? = nil) {
        let index = index ?? selection
        guard items.indices.contains(index) else { return }
        var ids = [items[index].id]
        for item in items[..<index].reversed() where !item.pinned { ids.append(item.id) }
        onSequence?(ids)
    }

    func togglePin(index: Int? = nil) {
        let index = index ?? selection
        guard items.indices.contains(index) else { return }
        let item = items[index]
        do {
            try store.setPinned(id: item.id, pinned: !item.pinned)
        } catch {
            NSLog("clipvault: pin failed: \(error)")
        }
        reload()
        if let moved = items.firstIndex(where: { $0.id == item.id }) { selection = moved }
    }

    func delete(index: Int? = nil) {
        let index = index ?? selection
        guard items.indices.contains(index) else { return }
        try? store.delete(id: items[index].id)
        reload()
    }

    func togglePreview() {
        if preview != nil {
            preview = nil
        } else {
            loadPreview()
        }
    }

    func closePreview() -> Bool {
        guard preview != nil else { return false }
        preview = nil
        return true
    }

    private func loadPreview() {
        guard items.indices.contains(selection) else { preview = nil; return }
        let id = items[selection].id
        guard let reps = try? store.get(id: id) else { preview = nil; return }
        let item = items[selection]
        let image = ClipContent.image(reps)
        let text = image == nil ? ClipContent.plainText(reps).map { String($0.prefix(200_000)) } : nil
        var title = Self.kindName(item.kind)
        if let image, let rep = image.representations.first {
            title += " — \(rep.pixelsWide) × \(rep.pixelsHigh)"
        } else if let text {
            title += " — \(text.count.formatted()) characters"
        }
        var subtitle = [ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)]
        if let app = item.sourceApp { subtitle.append(app) }
        subtitle.append(Date(timeIntervalSince1970: TimeInterval(item.createdAt))
            .formatted(date: .abbreviated, time: .shortened))
        if item.pinned { subtitle.append("Pinned") }
        preview = ClipPreview(id: id, text: text, image: image, title: title,
                              subtitle: subtitle.joined(separator: " · "))
    }

    private static func kindName(_ kind: ClipKind) -> String {
        switch kind {
        case .text: "Text"
        case .rtf: "Rich text"
        case .html: "HTML"
        case .image: "Image"
        case .files: "Files"
        }
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
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider().opacity(0.6)

            Group {
                if model.items.isEmpty {
                    VStack {
                        Spacer()
                        Text(model.query.isEmpty ? "History is empty" : "No results")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    list
                }
            }
            .frame(maxHeight: .infinity)

            Divider().opacity(0.6)
            HStack {
                Text(model.preview == nil
                     ? "⏎ paste · ⇧⏎ plain · ⌘⏎ copy · ⌥⏎ sequence · ⌘P pin · space preview"
                     : "↑↓ browse · ⌘+ ⌘− ⌘0 zoom · space/esc close")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help("⏎ paste · ⇧⏎ paste as plain text · ⌘⏎ copy only · ⌥⏎ paste sequentially (then ⌥⇧⌘V) · ⌘P pin · space or ⌘Y preview (⌘+/⌘−/⌘0 zoom) · ⌘⌫ delete · ⌘1–9 paste n-th")
                Spacer(minLength: 8)
                if !model.accessibilityGranted {
                    Text("Copy only")
                        .lineLimit(1)
                        .foregroundStyle(.orange)
                        .help("No Accessibility access. Grant it from the Clipvault menu to enable auto-paste")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        }
        .modifier(GlassScrim())
        // Everything, including the scrim, must follow the glass corners.
        .clipShape(RoundedRectangle(cornerRadius: PopupPanel.cornerRadius, style: .continuous))
        .onChange(of: model.focusToken) { _, _ in searchFocused = true }
        .onAppear { searchFocused = true }
    }

    private var list: some View {
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
                            .contextMenu { menu(for: item, index: index) }
                    }
                }
                .padding(8)
            }
            .onChange(of: model.selection) { _, new in
                if model.items.indices.contains(new) { proxy.scrollTo(model.items[new].id) }
            }
        }
    }

    @ViewBuilder
    private func menu(for item: ClipSummary, index: Int) -> some View {
        Button("Paste") { model.perform(.paste, index: index) }
        if item.kind != .image {
            Button("Paste as Plain Text") { model.perform(.pastePlain, index: index) }
        }
        Button("Copy") { model.perform(.copy, index: index) }
        Button("Paste Sequentially from Here") { model.startSequence(index: index) }
        Divider()
        Button(item.pinned ? "Unpin" : "Pin") { model.togglePin(index: index) }
        Button("Preview") {
            model.selection = index
            model.togglePreview()
        }
        Divider()
        Button("Delete", role: .destructive) { model.delete(index: index) }
    }
}

/// Keeps text readable over busy backgrounds without losing the glass.
private struct GlassScrim: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            content.background(scheme == .dark ? Color.black.opacity(0.22) : Color.white.opacity(0.3))
        } else {
            content
        }
        #else
        content
        #endif
    }
}

struct HistoryRow: View {
    let item: ClipSummary
    let index: Int
    let selected: Bool
    let thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            leading
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(2).font(.system(size: 13))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if item.pinned {
                Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                    .help("Pinned: kept until unpinned")
            }
            if index < 9 {
                Text("⌘\(index + 1)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.primary.opacity(0.1) : .clear)
        )
    }

    @ViewBuilder
    private var leading: some View {
        if let thumbnail {
            Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
        } else if let color = ClipContent.color(in: item.preview) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: color))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.primary.opacity(0.15)))
                .padding(4)
        } else {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(.secondary)
        }
    }

    private var link: URL? {
        item.kind == .files || item.kind == .image ? nil : ClipContent.link(in: item.preview)
    }

    private var icon: String {
        if link != nil { return "link" }
        switch item.kind {
        case .text: return "doc.plaintext"
        case .rtf: return "doc.richtext"
        case .html: return "globe"
        case .image: return "photo"
        case .files: return "folder"
        }
    }

    private var title: String {
        if item.kind == .image {
            let size = "Image · " + ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)
            return item.preview.isEmpty ? size : "\(size) — \(item.preview)"
        }
        return item.preview.isEmpty ? "(no text)" : item.preview
    }

    private var subtitle: String {
        let date = Date(timeIntervalSince1970: TimeInterval(item.createdAt))
        let rel = Date().timeIntervalSince(date) < 60
            ? "just now"
            : Self.relative.localizedString(for: date, relativeTo: Date())
        return [link?.host, item.sourceApp, rel].compactMap { $0 }.joined(separator: " · ")
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}

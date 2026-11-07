// Owner: app/UI track. The Recordings window's content (design.md §10.3): every recording in the
// save folder, newest first, with a thumbnail, its name and "Today at 14:22 · 4:12 · 186 MB".
// Plain values in, callbacks out (the window controller lists the folder and loads thumbnails).
import AppKit
import QuickLook
import SwiftUI

public struct RecordingItem: Identifiable, Equatable {
    public var url: URL
    public var date: Date
    public var bytes: Int64
    /// nil while loading.
    public var duration: TimeInterval?
    /// nil while loading (grey tile with a film glyph).
    public var thumbnail: CGImage?
    /// AVFoundation could not read it: grey tile, "Can't read this file".
    public var unreadable: Bool

    public var id: URL { url }
    /// The file name without its extension: a rename in Finder shows here.
    public var title: String { url.deletingPathExtension().lastPathComponent }

    public init(url: URL, date: Date, bytes: Int64, duration: TimeInterval? = nil, thumbnail: CGImage? = nil, unreadable: Bool = false) {
        self.url = url; self.date = date; self.bytes = bytes; self.duration = duration
        self.thumbnail = thumbnail; self.unreadable = unreadable
    }
}

public struct RecordingsState: Equatable {
    /// "~/Movies/Bubble".
    public var folderPath: String
    public var items: [RecordingItem]
    /// "Today" / "Yesterday" are relative to this.
    public var now: Date

    public init(folderPath: String, items: [RecordingItem], now: Date = Date()) {
        self.folderPath = folderPath; self.items = items; self.now = now
    }

    /// "~/Movies/Bubble · 12 recordings", "· 1 recording", just the folder when empty.
    public var subtitle: String {
        items.isEmpty ? folderPath : "\(folderPath) · \(items.count) recording\(items.count == 1 ? "" : "s")"
    }
}

public struct RecordingsActions {
    public var newRecording: @MainActor @Sendable () -> Void = {}
    public var open: @MainActor @Sendable ([URL]) -> Void = { _ in }
    public var reveal: @MainActor @Sendable ([URL]) -> Void = { _ in }
    public var copy: @MainActor @Sendable ([URL]) -> Void = { _ in }
    public var trash: @MainActor @Sendable ([URL]) -> Void = { _ in }
    /// Opens the editor on one recording, in the browser.
    public var edit: @MainActor @Sendable (URL) -> Void = { _ in }
    public init() {}
}

public enum RecordingFormat {
    /// "Today at 14:22", "Yesterday at 09:10", "Sunday at 17:03" (last 7 days), "6 Nov 2026".
    public static func when(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = Locale(identifier: "en_GB")) -> String {
        let time = date.formatted(Date.FormatStyle(locale: locale).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        if calendar.isDate(date, inSameDayAs: now) { return "Today at \(time)" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return "Yesterday at \(time)" }
        let startToday = calendar.startOfDay(for: now)
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: startToday), date >= weekAgo, date < now {
            return "\(date.formatted(Date.FormatStyle(locale: locale).weekday(.wide))) at \(time)"
        }
        return date.formatted(Date.FormatStyle(locale: locale).day().month(.abbreviated).year())
    }

    /// "4:12", "1:02:03".
    public static func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    public static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    public static func subtitle(_ item: RecordingItem, now: Date) -> String {
        if item.unreadable { return "Can't read this file · \(size(item.bytes))" }
        var parts = [when(item.date, now: now)]
        if let d = item.duration { parts.append(duration(d)) }
        parts.append(size(item.bytes))
        return parts.joined(separator: " · ")
    }
}

public struct RecordingsView: View {
    var state: RecordingsState
    var selection: Binding<Set<URL>>
    var actions: RecordingsActions
    var icon: NSImage?
    @State private var previewURL: URL?

    public init(state: RecordingsState, selection: Binding<Set<URL>>, actions: RecordingsActions = .init(), icon: NSImage? = nil) {
        self.state = state; self.selection = selection; self.actions = actions; self.icon = icon
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if state.items.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Recordings")
                    .font(.system(size: 20, weight: .semibold))
                Text(state.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // Empty: the centered button below is the only one.
            if !state.items.isEmpty { newRecordingButton }
        }
        .frame(minHeight: 28)
        .padding(.horizontal, 20)
        .padding(.top, 34) // under the traffic lights (transparent title bar)
        .padding(.bottom, 12)
    }

    private var newRecordingButton: some View {
        Button(action: actions.newRecording) {
            HStack(spacing: 7) {
                Circle().fill(Color.white).frame(width: 8, height: 8)
                Text("New Recording")
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(red: 0.92, green: 0.23, blue: 0.21)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("New Recording (⌥⇧L)")
    }

    private var list: some View {
        List(selection: selection) {
            ForEach(state.items) { item in
                RecordingRow(item: item, now: state.now, selected: selection.wrappedValue.contains(item.url),
                             edit: { actions.edit(item.url) })
                    .tag(item.url)
                    .onDrag { NSItemProvider(object: item.url as NSURL) }
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: URL.self) { urls in
            if !urls.isEmpty {
                let list = Array(urls)
                if list.count == 1, let one = list.first {
                    Button("Edit") { actions.edit(one) }
                }
                Button("Open") { actions.open(list) }
                Button("Show in Finder") { actions.reveal(list) }
                Button("Copy") { actions.copy(list) }
                Divider()
                Button("Move to Trash") { actions.trash(list) }
            }
        } primaryAction: { urls in
            actions.open(Array(urls))
        }
        .onKeyPress(.space) {
            guard let first = state.items.first(where: { selection.wrappedValue.contains($0.url) && !$0.unreadable }) else { return .ignored }
            previewURL = previewURL == nil ? first.url : nil
            return .handled
        }
        .quickLookPreview($previewURL, in: state.items.filter { selection.wrappedValue.contains($0.url) }.map(\.url))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            if let icon {
                Image(nsImage: icon).resizable().frame(width: 64, height: 64)
            } else {
                AppGlyph(size: 56)
            }
            Text("No recordings yet")
                .font(.system(size: 17, weight: .semibold))
            VStack(spacing: 3) {
                Text("Press ⌥⇧L anywhere, or click New Recording.")
                Text("Your videos are saved in \(state.folderPath).")
            }
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            newRecordingButton.padding(.top, 6)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

struct RecordingRow: View {
    var item: RecordingItem
    var now: Date
    /// The Edit button shows on the selected row and on hover (design.md §10).
    var selected = false
    var edit: @MainActor () -> Void = {}
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
                .frame(width: 96, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(RecordingFormat.subtitle(item, now: now))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if (selected || hovering) && !item.unreadable {
                Button(action: edit) {
                    Label("Edit", systemImage: "pencil")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Edit in your browser  ⌘E")
            }
        }
        .frame(height: 64)
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var thumbnail: some View {
        if let image = item.thumbnail, !item.unreadable {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color.primary.opacity(0.08)
                Image(systemName: item.unreadable ? "exclamationmark.triangle" : "film")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

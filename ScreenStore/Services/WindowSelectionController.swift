import AppKit
import SwiftUI

@MainActor
final class WindowSelectionController: NSObject, NSWindowDelegate {
    static let shared = WindowSelectionController()

    private var panel: NSPanel?
    private var continuation: CheckedContinuation<WindowDescriptor?, Never>?

    private override init() {
        super.init()
    }

    func selectWindow(from windows: [WindowDescriptor]) async -> WindowDescriptor? {
        guard continuation == nil else { return nil }
        guard !windows.isEmpty else { return nil }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            present(windows: windows)
        }
    }

    private func present(windows: [WindowDescriptor]) {
        let pickerView = WindowSelectionView(
            windows: windows,
            onSelect: { [weak self] window in
                self?.finish(with: window)
            },
            onCancel: { [weak self] in
                self?.finish(with: nil)
            }
        )

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = String(localized: "撮影するウインドウを選択")
        panel.minSize = NSSize(width: 440, height: 340)
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentViewController = NSHostingController(rootView: pickerView)
        panel.center()

        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func finish(with window: WindowDescriptor?) {
        guard let continuation else { return }
        self.continuation = nil
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
        continuation.resume(returning: window)
    }

    func windowWillClose(_ notification: Notification) {
        finish(with: nil)
    }
}

private struct WindowSelectionView: View {
    let windows: [WindowDescriptor]
    let onSelect: (WindowDescriptor) -> Void
    let onCancel: () -> Void

    @State private var searchText = ""
    @State private var selectedID: CGWindowID?

    private var filteredWindows: [WindowDescriptor] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return windows }
        return windows.filter {
            $0.appName.localizedCaseInsensitiveContains(query)
                || $0.title.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("撮影するウインドウを選択")
                    .font(.title2.weight(.semibold))
                Text("アプリ名またはウインドウ名で検索できます。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField("ウインドウを検索", text: $searchText)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(20)

            Divider()

            List(filteredWindows, selection: $selectedID) { window in
                WindowSelectionRow(window: window)
                    .tag(window.id)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        onSelect(window)
                    }
            }
            .overlay {
                if filteredWindows.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }

            Divider()

            HStack {
                Text("\(filteredWindows.count)件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("キャンセル", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("撮影") {
                    guard let selectedID,
                          let window = windows.first(where: { $0.id == selectedID }) else { return }
                    onSelect(window)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedID == nil)
            }
            .padding(16)
        }
        .frame(minWidth: 440, minHeight: 340)
        .onChange(of: filteredWindows.map(\.id)) { _, visibleIDs in
            if let selectedID, !visibleIDs.contains(selectedID) {
                self.selectedID = nil
            }
        }
    }
}

private struct WindowSelectionRow: View {
    let window: WindowDescriptor

    var body: some View {
        HStack(spacing: 12) {
            applicationIcon
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(window.title)
                    .lineLimit(1)
                Text(window.appName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var applicationIcon: some View {
        if let bundleIdentifier = window.bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "macwindow")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
                .padding(4)
        }
    }
}

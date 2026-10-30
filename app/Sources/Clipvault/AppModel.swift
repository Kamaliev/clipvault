import AppKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    nonisolated static let ttlSeconds: UInt64 = 24 * 3600
    nonisolated static let maxEntryBytes = 20 * 1024 * 1024

    @Published var paused = false {
        didSet { monitor?.paused = paused }
    }
    @Published var autoPaste: Bool {
        didSet { UserDefaults.standard.set(autoPaste, forKey: "autoPaste") }
    }
    @Published var recognizeText: Bool {
        didSet {
            UserDefaults.standard.set(recognizeText, forKey: "recognizeText")
            monitor?.recognizeText = recognizeText
        }
    }
    /// Show the menu bar icon all the time instead of only while Clipvault is in use.
    @Published var alwaysShowMenuBarIcon: Bool {
        didSet {
            UserDefaults.standard.set(alwaysShowMenuBarIcon, forKey: "alwaysShowMenuBarIcon")
            updateMenuBarIcon()
        }
    }
    @Published private(set) var menuBarIconVisible = true
    /// Items left in the active paste sequence (pasted one by one with ⌥⇧⌘V).
    @Published private(set) var sequenceRemaining = 0
    @Published private(set) var sequenceError: String?
    @Published var hotKey: HotKeySpec {
        didSet { saveHotKey(); registerHotKey() }
    }
    @Published private(set) var hotKeyError: String?
    @Published var launchAtLogin = LaunchAtLogin.isEnabled {
        didSet {
            guard launchAtLogin != LaunchAtLogin.isEnabled else { return }
            do {
                try LaunchAtLogin.set(launchAtLogin)
                launchAtLoginError = nil
            } catch {
                launchAtLoginError = "Could not update login item: \(error.localizedDescription)"
                launchAtLogin = LaunchAtLogin.isEnabled
            }
        }
    }
    @Published private(set) var launchAtLoginError: String?
    @Published private(set) var accessibilityGranted = Paster.isTrusted
    private var askedForAccessibility = false
    @Published private(set) var storageWarning: String?
    @Published private(set) var entryCount: UInt32 = 0

    /// Opened in the background at launch: reading the key may wait on a Keychain prompt.
    private(set) var store: Store?
    private var monitor: PasteboardMonitor?
    /// The popup was requested before the store was ready.
    private var popupRequested = false
    private var hotKeyManager: GlobalHotKey?
    private var nextHotKey: GlobalHotKey?
    private var sequence: [Int64] = []
    private var popup: PopupController?
    private var settingsWindow: NSWindow?
    private var purgeTimer: Timer?
    private var started = false
    private var popupVisible = false
    private var menuTracking = false
    private var hideIconWork: DispatchWorkItem?

    private init() {
        autoPaste = UserDefaults.standard.object(forKey: "autoPaste") as? Bool ?? true
        let recognize = UserDefaults.standard.object(forKey: "recognizeText") as? Bool ?? true
        recognizeText = recognize
        let always = UserDefaults.standard.bool(forKey: "alwaysShowMenuBarIcon")
        alwaysShowMenuBarIcon = always
        menuBarIconVisible = always
        if let data = UserDefaults.standard.data(forKey: "hotKey"),
           let spec = try? JSONDecoder().decode(HotKeySpec.self, from: data) {
            hotKey = spec
        } else {
            hotKey = .default
        }
    }

    func start() {
        guard !started else { return }
        started = true
        // Everything that does not need the store is ready immediately, so the hotkey and the
        // menu respond even while macOS asks for Keychain access.
        // Keep the icon while its menu is open, even if the popup closed meanwhile.
        for (name, tracking) in [(NSMenu.didBeginTrackingNotification, true), (NSMenu.didEndTrackingNotification, false)] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.menuTracking = tracking
                    self?.updateMenuBarIcon()
                }
            }
        }
        hotKeyManager = GlobalHotKey(id: 1) { [weak self] in self?.togglePopup() }
        nextHotKey = GlobalHotKey(id: 2) { [weak self] in self?.pasteNext(into: nil) }
        registerHotKey()
        // Lets scripts/Shortcuts open the popup without the hotkey.
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.kamaliev.clipvault.toggle"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.togglePopup() }
        }
        // Posted when the Accessibility list changes; the new state is readable a moment later.
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                self?.refreshAccessibility()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshAccessibility() }
        }

        Task.detached(priority: .userInitiated) {
            let (store, warning) = Self.openStore()
            await MainActor.run { AppModel.shared.storeOpened(store, warning: warning) }
        }
        // The icon is hidden by default, so show something on the very first launch.
        if !UserDefaults.standard.bool(forKey: "didShowWelcome") {
            UserDefaults.standard.set(true, forKey: "didShowWelcome")
            openSettings()
        }
    }

    private func storeOpened(_ store: Store, warning: String?) {
        self.store = store
        storageWarning = warning
        let monitor = PasteboardMonitor(store: store, maxBytes: Self.maxEntryBytes)
        monitor.recognizeText = recognizeText
        monitor.paused = paused
        self.monitor = monitor
        popup = PopupController(
            store: store,
            onAction: { [weak self] action, id, app in self?.perform(action, id: id, into: app) },
            onSequence: { [weak self] ids, app in self?.startSequence(ids, into: app) }
        )
        popup?.onVisibilityChange = { [weak self] visible in
            self?.popupVisible = visible
            self?.updateMenuBarIcon()
        }
        popup?.onOpenSettings = { [weak self] in self?.openSettings() }
        monitor.onAdded = { [weak self] in
            self?.refreshCount()
            self?.popup?.refreshIfVisible()
        }
        monitor.start()

        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.purge() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        purgeTimer = timer
        purge()
        if popupRequested {
            popupRequested = false
            togglePopup()
        }
    }

    /// The icon is shown while Clipvault is in use: popup, settings, menu or a paste sequence.
    func updateMenuBarIcon() {
        let inUse = alwaysShowMenuBarIcon || popupVisible || menuTracking || sequenceRemaining > 0
            || settingsWindow?.isVisible == true
        hideIconWork?.cancel()
        hideIconWork = nil
        if inUse {
            menuBarIconVisible = true
        } else if menuBarIconVisible {
            // A short delay so a click on the icon right as the popup closes still opens its menu.
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor [weak self] in self?.menuBarIconVisible = false }
            }
            hideIconWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        }
    }

    func togglePopup() {
        refreshAccessibility()
        guard let popup else {
            popupRequested.toggle()
            return
        }
        popup.toggle()
    }

    /// Clears history; pinned items are kept unless `includingPinned` is set.
    func clearHistory(includingPinned: Bool = false) {
        try? store?.clear(keepPinned: !includingPinned)
        refreshCount()
        popup?.refreshIfVisible()
    }

    func pasteNext(into app: NSRunningApplication?) {
        while let id = sequence.first {
            sequence.removeFirst()
            guard let reps = try? store?.get(id: id) else { continue }
            Paster.write(reps)
            monitor?.skipCurrent()
            sendPaste(into: app)
            break
        }
        updateSequence()
    }

    func stopSequence() {
        sequence.removeAll()
        updateSequence()
    }

    private func startSequence(_ ids: [Int64], into app: NSRunningApplication?) {
        sequence = ids
        pasteNext(into: app)
    }

    private func updateSequence() {
        sequenceRemaining = sequence.count
        updateMenuBarIcon()
        if sequence.isEmpty {
            nextHotKey?.unregister()
            sequenceError = nil
        } else if nextHotKey?.register(.pasteNext) == false {
            sequenceError = "\(HotKeySpec.pasteNext.display) is in use; use the menu to paste next"
        } else {
            sequenceError = nil
        }
    }

    func refreshAccessibility() {
        accessibilityGranted = Paster.isTrusted
    }

    /// Re-reads the login item state; the user can change it in System Settings.
    func refreshLaunchAtLogin() {
        let enabled = LaunchAtLogin.isEnabled
        if launchAtLogin != enabled { launchAtLogin = enabled }
        if LaunchAtLogin.requiresApproval {
            launchAtLoginError = "Approve Clipvault in System Settings › General › Login Items."
        }
    }

    func requestAccessibility() {
        Paster.requestAccessibility()
        refreshAccessibility()
        // The prompt does not appear while an outdated Clipvault entry is still in the list.
        if !accessibilityGranted,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: self)))
            window.title = "Clipvault Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    // isVisible is still true during willClose.
                    self?.settingsWindow?.orderOut(nil)
                    self?.updateMenuBarIcon()
                }
            }
            settingsWindow = window
        }
        refreshAccessibility()
        refreshLaunchAtLogin()
        refreshCount()
        settingsWindow?.center()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        updateMenuBarIcon()
    }

    private func perform(_ action: ClipAction, id: Int64, into app: NSRunningApplication?) {
        guard let store else { return }
        let reps: [ClipRep]
        do {
            reps = try store.get(id: id)
        } catch {
            NSLog("clipvault: get failed: \(error)")
            return
        }
        if action == .pastePlain, let text = ClipContent.plainText(reps) {
            Paster.writePlain(text)
        } else {
            Paster.write(reps)
        }
        monitor?.skipCurrent()
        try? store.touch(id: id)
        if action != .copy { sendPaste(into: app) }
    }

    /// Sends ⌘V to `app` (or the frontmost app when `nil`) if auto-paste is enabled and allowed.
    private func sendPaste(into app: NSRunningApplication?) {
        refreshAccessibility()
        guard autoPaste else { return }
        guard accessibilityGranted else {
            // The grant is tied to the code signature, so updates silently revoke it; ask once per launch.
            if !askedForAccessibility {
                askedForAccessibility = true
                Paster.requestAccessibility()
            }
            return
        }
        var delay = 0.05
        if let app, NSApp.isActive || NSWorkspace.shared.frontmostApplication != app {
            app.activate()
            delay = 0.2
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { Paster.sendPasteKeystroke() }
    }

    private func purge() {
        _ = try? store?.purgeExpired()
        refreshCount()
    }

    private func refreshCount() {
        entryCount = (try? store?.count()) ?? 0
    }

    private func registerHotKey() {
        guard let hotKeyManager else { return }
        hotKeyError = hotKeyManager.register(hotKey) ? nil : "Could not register \(hotKey.display): shortcut is already in use"
    }

    private func saveHotKey() {
        if let data = try? JSONEncoder().encode(hotKey) {
            UserDefaults.standard.set(data, forKey: "hotKey")
        }
    }

    nonisolated private static func databasePath() throws -> String {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("Clipvault", isDirectory: true).appendingPathComponent("history.db").path
    }

    /// Opens the encrypted on-disk store. Falls back to an in-memory store if the Keychain is unavailable.
    nonisolated private static func openStore() -> (Store, String?) {
        let ttl = ttlSeconds, max = UInt64(maxEntryBytes)
        do {
            let key = try KeychainKey.loadOrCreate()
            let path = try databasePath()
            do {
                return (try Store.open(path: path, key: key, ttlSecs: ttl, maxBytes: max), nil)
            } catch CoreError.KeyMismatch {
                // Key was reset in the Keychain: old history is unreadable anyway.
                try deleteStoreFiles(path: path)
                return (try Store.open(path: path, key: key, ttlSecs: ttl, maxBytes: max), nil)
            }
        } catch {
            NSLog("clipvault: persistent store unavailable: \(error)")
            let key = (try? KeychainKey.randomKey()) ?? Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            // swiftlint:disable:next force_try
            let store = try! Store.open(path: ":memory:", key: key, ttlSecs: ttl, maxBytes: max)
            return (store, "History is kept in memory only: \(error)")
        }
    }
}

import AppKit
import SwiftUI
import UserNotifications

// The macOS 27 SDK also exports a State macro whose plugin is absent from
// Command Line Tools. An alias explicitly selects the stable property wrapper.
typealias ViewState<Value> = SwiftUI.State<Value>

@main
struct IWiFiYouApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: delegate.model, openSettings: delegate.showSettings, openMainWindow: delegate.showMainWindow)
        } label: {
            Image(nsImage: LogoGeometry.menuBarImage())
                .accessibilityLabel("iwifyou — \(delegate.model.statusText)")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel()
    lazy var scan = ChannelScanModel(demo: model.isDemo)
    let location = LocationAccess()
    lazy var diagnosis = DiagnosisModel(demo: model.isDemo)
    lazy var meter = SignalMeter(demo: model.isDemo)
    lazy var monitor = ConnectionMonitor(model: model)
    private var mainWindow: NSWindowController?
    private var settingsWindow: NSWindowController?
    private var terminationPending = false
    private var terminationReady = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationReady { return .terminateNow }
        if terminationPending { return .terminateLater }
        guard !model.state.isBusy else { return .terminateCancel }
        terminationPending = true
        Task {
            await model.prepareToQuit()
            terminationReady = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        // Use the bundled icon directly so a stale Dock icon cache never shows the old one.
        if let icon = Bundle.main.image(forResource: "AppIcon") { NSApp.applicationIconImage = icon }
        model.startWatchingIfNeeded()
        monitor.start()
        showMainWindow()
        if !model.isDemo && UserDefaults.standard.string(forKey: "routerAddress") == nil {
            showSettings()
        }
    }

    /// The menu bar item keeps the app alive after the window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func showMainWindow() {
        model.noteInteraction()
        if mainWindow == nil {
            let content = MainWindow(
                model: model, scan: scan, location: location, diagnosis: diagnosis, meter: meter, monitor: monitor,
                openSettings: { [weak self] in self?.showSettings() }
            )
            let host = NSHostingController(rootView: content)
            host.sceneBridgingOptions = [.toolbars, .title]
            let window = NSWindow(contentViewController: host)
            window.title = "iwifyou"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 1000, height: 720))
            window.contentMinSize = NSSize(width: 820, height: 560)
            window.center()
            window.setFrameAutosaveName("iwifyou.main")
            mainWindow = NSWindowController(window: window)
        }
        mainWindow?.showWindow(nil)
        NSApplication.shared.activate()
    }

    func showSettings() {
        model.noteInteraction()
        if settingsWindow == nil {
            let content = SettingsView(model: model, close: { [weak self] in self?.settingsWindow?.close() })
            let host = NSHostingController(rootView: content)
            let window = NSWindow(contentViewController: host)
            window.title = "Akun router"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(host.view.fittingSize)
            window.center()
            settingsWindow = NSWindowController(window: window)
        }
        settingsWindow?.showWindow(nil)
        NSApplication.shared.activate()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// A click opens the matching screen; a channel suggestion is only
    /// pre-selected, never applied from the notification.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let channel = response.notification.request.content.userInfo["channel"] as? Int
        let isDevice = response.notification.request.identifier.hasPrefix("device-")
        await MainActor.run {
            if let channel {
                model.openSuggestion(channel)
                UserDefaults.standard.set(MainSection.channel.rawValue, forKey: "mainSection")
            } else if isDevice {
                UserDefaults.standard.set(MainSection.devices.rawValue, forKey: "mainSection")
            }
            showMainWindow()
        }
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === settingsWindow?.window { settingsWindow = nil }
    }
}

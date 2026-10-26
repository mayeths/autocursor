import AppKit
import SwiftUI

final class TopAnchoredWindow: NSWindow {
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var rect = frameRect
        if isVisible, rect.height != frame.height, rect.minY == frame.minY {
            rect.origin.y = frame.maxY - rect.height
        }
        super.setFrame(rect, display: flag)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model: AppModel
    private let bars = FloatingBarController()
    private var timer: Timer?
    private var dashboard: NSWindow!
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?

    init(configuration: Configuration) {
        model = AppModel(configuration: configuration)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = AppIcon.dockImage()
        bars.onOpenDashboard = { [weak self] in self?.showDashboard() }
        installMenu()
        installStatusItem()
        buildDashboard()
        model.requestPermission()

        let timer = Timer(timeInterval: model.configuration.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
        observeDarwinNotifications()
    }

    /// `local.autocursor.status` writes diagnostics. `local.autocursor.wake` starts a short scan window.
    private func observeDarwinNotifications() {
        let callback: CFNotificationCallback = { _, observer, name, _, _ in
            guard let observer, let name else { return }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(observer).takeUnretainedValue()
            let event = name.rawValue as NSString as String
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if event == WakeHook.notificationName {
                        delegate.model.noteWake()
                        delegate.tick()
                    } else {
                        delegate.model.exportDiagnostics(to: AppModel.statusURL) { _ in }
                    }
                }
            }
        }
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        for name in ["local.autocursor.status", WakeHook.notificationName] {
            CFNotificationCenterAddObserver(center, observer, callback, name as CFString, nil, .deliverImmediately)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDashboard()
        return true
    }

    private func tick() {
        model.tick()
        bars.sync(with: model)
    }

    @objc private func exportDiagnostics() {
        model.exportDiagnostics { url in
            if let url {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                let alert = NSAlert()
                alert.messageText = "无法导出诊断"
                alert.informativeText = "请确认已授予辅助功能权限，并且 Cursor 正在运行。"
                alert.runModal()
            }
        }
    }

    @objc private func showDashboard() {
        NSApp.setActivationPolicy(.regular)
        dashboard.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleDashboard() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu()
            return
        }
        if dashboard.isVisible {
            dashboard.orderOut(nil)
            NSApp.setActivationPolicy(.accessory)
        } else {
            showDashboard()
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === dashboard else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "cursorarrow.click.2", accessibilityDescription: "AutoCursor")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(toggleDashboard)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    private func showStatusMenu() {
        let menu = NSMenu()
        menu.addItem(item("打开主窗口", #selector(showDashboard)))
        menu.addItem(item("设置…", #selector(showSettings)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 AutoCursor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        guard let button = statusItem?.button else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
    }

    @objc private func showAbout() {
        AboutPanel.show()
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let host = NSHostingView(rootView: SettingsView(model: model, onExportDiagnostics: { [weak self] in self?.exportDiagnostics() }))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "设置"
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func buildDashboard() {
        let host = NSHostingView(rootView: DashboardView(model: model))
        let size = host.fittingSize
        dashboard = TopAnchoredWindow(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
        dashboard.title = "AutoCursor"
        dashboard.titleVisibility = .hidden
        dashboard.titlebarAppearsTransparent = true
        dashboard.isMovableByWindowBackground = true
        dashboard.isReleasedWhenClosed = false
        dashboard.delegate = self
        dashboard.contentView = host
        dashboard.center()
        showDashboard()
    }

    private func installMenu() {
        let mainMenu = NSMenu()

        let appMenu = submenu(in: mainMenu, title: "AutoCursor")
        appMenu.addItem(item("关于 AutoCursor", #selector(showAbout)))
        appMenu.addItem(.separator())
        appMenu.addItem(item("设置…", #selector(showSettings), key: ","))
        appMenu.addItem(.separator())
        let servicesItem = NSMenuItem(title: "服务", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "服务")
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(servicesItem)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "隐藏 AutoCursor", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(title: "全部显示", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "退出 AutoCursor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        let windowMenu = submenu(in: mainMenu, title: "窗口")
        windowMenu.addItem(item("AutoCursor 主窗口", #selector(showDashboard), key: "0"))
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(title: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        NSApp.windowsMenu = windowMenu

        let helpMenu = submenu(in: mainMenu, title: "帮助")
        helpMenu.addItem(item("打开辅助功能设置", #selector(openAccessibilitySettings)))
        helpMenu.addItem(item("导出辅助功能诊断…", #selector(exportDiagnostics)))
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }

    private func submenu(in mainMenu: NSMenu, title: String) -> NSMenu {
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        menuItem.submenu = menu
        mainMenu.addItem(menuItem)
        return menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = self
        return menuItem
    }
}

func printUsage() {
    print("""
    AutoCursor - click Cursor run confirmations through macOS Accessibility.

    Usage: autocursor [options]

    Options:
      --mode full-access   Confirmation mode (currently the supported mode)
      --app Cursor         Target application name
      --interval 0.35      Scan interval in seconds (minimum 0.05)
      --dry-run            Detect matching buttons without clicking
      --once               Scan once and exit
      --verbose            Print scanned buttons and diagnostic details
      -h, --help           Show this help
    """)
}

let arguments = CommandLine.arguments
if arguments.count == 3, arguments[1] == "--export-iconset" {
    do {
        try AppIcon.exportIconset(to: URL(fileURLWithPath: arguments[2]))
        exit(EXIT_SUCCESS)
    } catch {
        fputs("Error: \(error)\n", stderr)
        exit(EXIT_FAILURE)
    }
}

do {
    let configuration = try Configuration(arguments: arguments)
    if arguments.count == 1 {
        let application = NSApplication.shared
        let delegate = AppDelegate(configuration: configuration)
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    } else {
        AutoClicker(configuration: configuration).run()
    }
} catch {
    fputs("Error: \(error)\n\n", stderr)
    printUsage()
    exit(EXIT_FAILURE)
}

import AppKit
import ApplicationServices
import Combine
import Foundation
import ServiceManagement

enum ScanTrigger: Equatable {
    /// A Cursor hook posted `local.autocursor.wake` and the scan ran inside that window.
    case wake
    /// The periodic scan that runs without a hook notification.
    case active

    var label: String {
        switch self {
        case .wake: return "被动唤醒"
        case .active: return "主动扫描"
        }
    }
}

struct ActivityEvent: Identifiable {
    let id = UUID()
    let date = Date()
    let windowTitle: String
    let buttonTitle: String
    let clicked: Bool
    let trigger: ScanTrigger
}

@MainActor
final class AgentMonitor: ObservableObject, Identifiable {
    let key: String
    nonisolated let id: String
    @Published var enabled = true
    @Published private(set) var detectedCount = 0
    @Published private(set) var clickedCount = 0
    @Published private(set) var subagents: [SubagentInfo] = []
    @Published private(set) var subagentClicks: [String: Int] = [:]
    /// Pane frame in global top-left-origin coordinates.
    var frame: CGRect?

    init(key: String) {
        self.id = key
        self.key = key
    }

    func update(_ info: AgentInfo) {
        frame = info.frame
        if subagents != info.subagents { subagents = info.subagents }
    }

    func record(clicked: Bool, subagent: String?) {
        detectedCount += 1
        if clicked { clickedCount += 1 }
        if clicked, let subagent { subagentClicks[subagent, default: 0] += 1 }
    }
}

@MainActor
final class WindowMonitor: ObservableObject, Identifiable {
    let id: UInt64
    let element: AXUIElement
    @Published private(set) var title: String
    @Published var enabled = true
    @Published private(set) var detectedCount = 0
    @Published private(set) var clickedCount = 0
    @Published private(set) var wakeClicked = 0
    @Published private(set) var activeClicked = 0
    @Published private(set) var lastDetectedTitle: String?
    @Published private(set) var agents: [AgentMonitor] = []
    @Published var expanded = true
    private var agentStore: [String: AgentMonitor] = [:]
    private(set) var frame: CGRect?

    var disabledAgentKeys: Set<String> {
        Set(agentStore.values.filter { !$0.enabled }.map(\.key))
    }

    func updateAgents(_ infos: [AgentInfo]) {
        let next = infos.map { info in
            let agent = agentStore[info.key] ?? AgentMonitor(key: info.key)
            agentStore[info.key] = agent
            agent.update(info)
            return agent
        }
        if next.map(\.key) != agents.map(\.key) { agents = next }
    }

    init(id: UInt64, element: AXUIElement) {
        self.id = id
        self.element = element
        self.title = "未命名窗口"
    }

    /// Cursor titles windows "<active tab> — <workspace>"; only the workspace identifies the window.
    var displayTitle: String {
        let trimmed = title.replacingOccurrences(of: " — Cursor", with: "").replacingOccurrences(of: " - Cursor", with: "")
        let workspace = trimmed.components(separatedBy: " — ").last?.trimmingCharacters(in: .whitespaces) ?? ""
        return workspace.isEmpty ? "未命名窗口" : workspace
    }
    func refresh(using reader: AccessibilityReader) {
        if let value = reader.stringAttribute(element, kAXTitleAttribute), !value.isEmpty, value != title {
            title = value
        }
        frame = reader.frame(of: element)
    }

    func apply(_ hit: ScanHit, trigger: ScanTrigger) -> ActivityEvent {
        detectedCount += 1
        if hit.clicked {
            clickedCount += 1
            switch trigger {
            case .wake: wakeClicked += 1
            case .active: activeClicked += 1
            }
        }
        agentStore[hit.agentKey]?.record(clicked: hit.clicked, subagent: hit.subagent)
        let label = Self.displayLabel(hit.label)
        lastDetectedTitle = label
        let source = hit.subagent.map { "\(hit.agentKey) › \($0)" } ?? hit.agentKey
        return ActivityEvent(windowTitle: "\(displayTitle) · \(source)", buttonTitle: label, clicked: hit.clicked, trigger: trigger)
    }

    private static func displayLabel(_ normalized: String) -> String {
        normalized.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

@MainActor
final class AppModel: ObservableObject {
    enum CursorState: Equatable {
        case notRunning, foreground, background

        var label: String {
            switch self {
            case .notRunning: return "未开启"
            case .foreground: return "前台"
            case .background: return "后台"
            }
        }
    }

    let configuration: Configuration
    @Published private(set) var permissionGranted = false
    /// The Accessibility list still has a grant for an older signature of this app.
    @Published private(set) var accessibilityStale = false
    @Published private(set) var wakeHookPresence: WakeHookPresence = .missing
    @Published private(set) var cursorState: CursorState = .notRunning
    @Published private(set) var windows: [WindowMonitor] = []
    @Published private(set) var totalDetected = 0
    @Published private(set) var totalClicked = 0
    @Published private(set) var wakeClicked = 0
    @Published private(set) var activeClicked = 0
    @Published private(set) var launchAtLogin = false
    @Published private(set) var launchAtLoginNeedsApproval = false
    @Published private(set) var launchAtLoginMessage: String?
    @Published private(set) var events: [ActivityEvent] = []
    @Published var masterEnabled: Bool {
        didSet { UserDefaults.standard.set(masterEnabled, forKey: "masterEnabled") }
    }
    @Published var showFloatingBars: Bool {
        didSet { UserDefaults.standard.set(showFloatingBars, forKey: "showFloatingBars") }
    }
    /// Minimum seconds between two automatic clicks in the same window.
    @Published var clickInterval: Double {
        didSet { UserDefaults.standard.set(clickInterval, forKey: "clickInterval") }
    }
    static let clickIntervalOptions: [Double] = [0.5, 1, 2, 3, 5]

    private let reader = AccessibilityReader()
    private var monitors: [UInt64: WindowMonitor] = [:]
    private var onScreenFrames: [CGRect] = []
    private var manualAccessibilityPID: pid_t?
    private var cachedCursor: NSRunningApplication?
    private let scanner = PromptScanner()
    private let scanQueue = DispatchQueue(label: "autocursor.scan", qos: .userInitiated)
    private var scanInFlight = false
    private var inFlightTrigger: ScanTrigger = .active
    /// Keep scanning until this instant after a wake notification.
    private var scanUntil: Date?
    private var lastHeavyScan: Date?
    private var lastHookCheck: Date?
    private let wakeWindow: TimeInterval = 3
    private let fallbackInterval: TimeInterval = 10

    init(configuration: Configuration) {
        self.configuration = configuration
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["masterEnabled": true, "showFloatingBars": true, "clickInterval": 1.0])
        masterEnabled = defaults.bool(forKey: "masterEnabled")
        showFloatingBars = defaults.bool(forKey: "showFloatingBars")
        clickInterval = defaults.double(forKey: "clickInterval")
        refreshWakeHook()
        refreshLaunchAtLogin()
    }

    var bundlePath: String { Bundle.main.bundlePath }
    func requestPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        permissionGranted = AXIsProcessTrustedWithOptions(options)
        updateAccessibilityIdentity()
    }

    /// `notifyutil -p local.autocursor.wake` extends the active scan window and should be followed by `tick()`.
    func noteWake() {
        let proposed = Date().addingTimeInterval(wakeWindow)
        if let scanUntil {
            self.scanUntil = max(scanUntil, proposed)
        } else {
            scanUntil = proposed
        }
    }

    func refreshWakeHook() {
        let presence = WakeHook.presence()
        if wakeHookPresence != presence { wakeHookPresence = presence }
        lastHookCheck = Date()
    }

    func installWakeHook() throws {
        try WakeHook.install()
        refreshWakeHook()
    }

    func refreshLaunchAtLogin() {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLogin = true
            launchAtLoginNeedsApproval = false
        case .requiresApproval:
            launchAtLogin = true
            launchAtLoginNeedsApproval = true
        default:
            launchAtLogin = false
            launchAtLoginNeedsApproval = false
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginMessage = nil
        } catch {
            launchAtLoginMessage = "无法更改开机启动"
        }
        refreshLaunchAtLogin()
        if launchAtLoginNeedsApproval { Self.openLoginItems() }
    }

    static func openLoginItems() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func tick() {
        refreshWakeHookIfNeeded()
        if !permissionGranted {
            guard AXIsProcessTrusted() else { return }
            permissionGranted = true
            updateAccessibilityIdentity()
        }

        guard let app = currentCursorApplication() else {
            setCursorState(.notRunning)
            if !windows.isEmpty { windows = [] }
            monitors.removeAll()
            onScreenFrames = []
            return
        }

        let pid = app.processIdentifier
        let isFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        setCursorState(isFront ? .foreground : .background)
        guard let trigger = scanTrigger(at: Date()) else { return }

        let root = AXUIElementCreateApplication(pid)
        if manualAccessibilityPID != pid {
            CursorLocator.enableManualAccessibility(root)
            manualAccessibilityPID = pid
        }

        var next: [WindowMonitor] = []
        for element in reader.elementsAttribute(root, kAXWindowsAttribute) where Self.isDocumentWindow(element, reader: reader) {
            let id = UInt64(CFHash(element))
            let monitor = monitors[id] ?? WindowMonitor(id: id, element: element)
            monitor.refresh(using: reader)
            next.append(monitor)
        }
        monitors = Dictionary(uniqueKeysWithValues: next.map { ($0.id, $0) })
        if next.map(\.id) != windows.map(\.id) { windows = next }
        onScreenFrames = Self.onScreenFrames(for: pid)

        guard !scanInFlight else { return }
        inFlightTrigger = trigger
        lastHeavyScan = Date()
        // Disabled windows are still scanned so their agent panes stay listed; they just never click.
        let targets = windows.map {
            (id: $0.id, ref: ElementRef(element: $0.element), clickEnabled: masterEnabled && $0.enabled, disabledAgents: $0.disabledAgentKeys)
        }
        guard !targets.isEmpty else { return }
        scanInFlight = true
        let scanner = scanner
        let dryRun = configuration.dryRun
        let verbose = configuration.verbose
        let clickInterval = clickInterval
        scanQueue.async { [weak self] in
            let results = targets.map {
                scanner.scan(windowID: $0.id, root: $0.ref.element, clickEnabled: $0.clickEnabled, disabledAgents: $0.disabledAgents,
                             clickInterval: clickInterval, dryRun: dryRun, verbose: verbose)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finishScan(results) }
            }
        }
    }

    static let diagnosticsURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/AutoCursor-diagnostics.txt")
    static let statusURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AutoCursor/status.txt")

    var statusSummary: String {
        let wake = scanUntil.map { "until=\($0)" } ?? "idle"
        var lines = ["permission=\(permissionGranted) cursor=\(cursorState.label) master=\(masterEnabled) interval=\(clickInterval)s hook=\(wakeHookPresence) scan=\(wake)",
                     "detected=\(totalDetected) clicked=\(totalClicked) wake=\(wakeClicked) active=\(activeClicked)"]
        for window in windows {
            lines.append("window \(window.displayTitle.debugDescription) title=\(window.title.debugDescription) enabled=\(window.enabled) detected=\(window.detectedCount) clicked=\(window.clickedCount)")
            for agent in window.agents {
                lines.append("  agent \(agent.key.debugDescription) enabled=\(agent.enabled) detected=\(agent.detectedCount) clicked=\(agent.clickedCount) frame=\(agent.frame.map { "\($0)" } ?? "nil")")
                for subagent in agent.subagents {
                    lines.append("    subagent \(subagent.name.debugDescription) awaiting=\(subagent.awaitingApproval) status=\(subagent.status.debugDescription)")
                }
            }
        }
        for event in events.prefix(10) {
            lines.append("event \(event.date) \(event.clicked ? "click" : "detect") \(event.trigger.label) \(event.buttonTitle) @ \(event.windowTitle)")
        }
        return lines.joined(separator: "\n")
    }

    func exportDiagnostics(to url: URL = AppModel.diagnosticsURL, completion: @escaping @MainActor (URL?) -> Void) {
        guard permissionGranted, let app = CursorLocator.application(named: configuration.appName) else {
            completion(nil)
            return
        }
        let root = ElementRef(element: AXUIElementCreateApplication(app.processIdentifier))
        let summary = statusSummary
        scanQueue.async {
            let windows = AccessibilityReader().elementsAttribute(root.element, kAXWindowsAttribute)
            let diagnosticScanner = PromptScanner()
            var report = "AutoCursor diagnostics \(Date())\n\(summary)\n"
            for (index, window) in windows.enumerated() {
                report += "\n===== window \(index) =====\n" + diagnosticScanner.diagnostics(root: window) + "\n"
            }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let written = (try? report.write(to: url, atomically: true, encoding: .utf8)) != nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(written ? url : nil) }
            }
        }
    }

    private func finishScan(_ results: [WindowScan]) {
        let trigger = inFlightTrigger
        scanInFlight = false
        for result in results {
            guard let monitor = monitors[result.windowID] else { continue }
            monitor.updateAgents(result.agents)
            if let hit = result.hit { record(monitor.apply(hit, trigger: trigger)) }
        }
    }

    func isOnScreen(_ frame: CGRect) -> Bool {
        onScreenFrames.contains {
            abs($0.minX - frame.minX) < 4 && abs($0.minY - frame.minY) < 4 &&
            abs($0.width - frame.width) < 4 && abs($0.height - frame.height) < 4
        }
    }

    private func record(_ event: ActivityEvent) {
        totalDetected += 1
        if event.clicked {
            totalClicked += 1
            switch event.trigger {
            case .wake: wakeClicked += 1
            case .active: activeClicked += 1
            }
        }
        events.insert(event, at: 0)
        if events.count > 30 { events.removeLast(events.count - 30) }
    }

    private func updateAccessibilityIdentity() {
        guard let current = CodeIdentity.currentHash() else {
            accessibilityStale = false
            return
        }
        let defaults = UserDefaults.standard
        if permissionGranted {
            defaults.set(current, forKey: CodeIdentity.trustedHashKey)
            accessibilityStale = false
            return
        }
        let previous = defaults.string(forKey: CodeIdentity.trustedHashKey)
        accessibilityStale = previous != nil && previous != current
    }

    /// Reuse the last Cursor process until it exits, so idle ticks do not ask Launch Services.
    private func currentCursorApplication() -> NSRunningApplication? {
        if let cachedCursor, !cachedCursor.isTerminated { return cachedCursor }
        let found = CursorLocator.application(named: configuration.appName)
        cachedCursor = found
        return found
    }

    private func scanTrigger(at now: Date) -> ScanTrigger? {
        if let scanUntil, now < scanUntil { return .wake }
        let elapsed = lastHeavyScan.map { now.timeIntervalSince($0) } ?? .infinity
        if elapsed >= fallbackInterval { return .active }
        return nil
    }

    private func refreshWakeHookIfNeeded() {
        if let lastHookCheck, Date().timeIntervalSince(lastHookCheck) < 2 { return }
        refreshWakeHook()
    }

    private func setCursorState(_ state: CursorState) {
        if cursorState != state { cursorState = state }
    }

    /// Excludes IME candidate panels, popovers and other auxiliary windows Cursor reports.
    private static func isDocumentWindow(_ element: AXUIElement, reader: AccessibilityReader) -> Bool {
        guard reader.stringAttribute(element, kAXSubroleAttribute) == kAXStandardWindowSubrole as String,
              let frame = reader.frame(of: element) else { return false }
        return frame.width >= 400 && frame.height >= 300
    }

    private static func onScreenFrames(for pid: pid_t) -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: bounds)
        }
    }
}

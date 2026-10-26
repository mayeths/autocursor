import AppKit
import ApplicationServices
import SwiftUI

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Small AutoCursor mark placed just to the left of Cursor's Toggle Panel button.
struct WindowBadgeView: View {
    @ObservedObject var window: WindowMonitor
    @ObservedObject var model: AppModel
    let onClick: () -> Void

    static let size: CGFloat = 22

    private var active: Bool { model.masterEnabled && window.enabled }

    var body: some View {
        Button(action: onClick) {
            Image(systemName: "cursorarrow.click.2")
                .font(.system(size: 13, weight: .semibold))
                .symbolRenderingMode(active ? .palette : .monochrome)
                .foregroundStyle(active ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.white.opacity(0.35)))
                .frame(width: Self.size, height: Self.size)
        }
        .buttonStyle(.plain)
        .help("单击打开主窗口")
    }
}

@MainActor
final class FloatingBarController {
    /// Toggle Panel is pinned to the window's top-right, so these insets survive moves and resizes.
    private struct Anchor {
        var fromRight: CGFloat
        var fromTop: CGFloat
        var buttonHeight: CGFloat
    }

    private struct Badge {
        let panel: NSPanel
        var anchor: Anchor?
        var lastLookup = Date.distantPast
    }

    private let reader = AccessibilityReader()
    private var badges: [UInt64: Badge] = [:]
    private var observer: AXObserver?
    private var observedPID: pid_t?
    private var observedWindows: [UInt64: AXUIElement] = [:]
    private let lookupInterval: TimeInterval = 2
    private let gap: CGFloat = 6
    var onOpenDashboard: (() -> Void)?

    func sync(with model: AppModel) {
        let cursorFocused = model.cursorState == .foreground || (NSApp.isActive && model.cursorState != .notRunning)
        let shouldShow = model.permissionGranted && model.showFloatingBars && cursorFocused
        let now = Date()

        var live = Set<UInt64>()
        for window in model.windows {
            live.insert(window.id)
            guard shouldShow, let windowFrame = reader.frame(of: window.element), isOnAnyScreen(windowFrame) else {
                badges[window.id]?.panel.orderOut(nil)
                continue
            }
            var badge = badges[window.id] ?? makeBadge(for: window, model: model)
            if badge.anchor == nil || now.timeIntervalSince(badge.lastLookup) >= lookupInterval {
                if let button = togglePanelFrame(in: window.element) {
                    badge.anchor = Anchor(
                        fromRight: windowFrame.maxX - button.minX,
                        fromTop: button.minY - windowFrame.minY,
                        buttonHeight: button.height
                    )
                }
                badge.lastLookup = now
            }
            badges[window.id] = badge
            guard let anchor = badge.anchor else {
                badge.panel.orderOut(nil)
                continue
            }
            badge.panel.setFrameOrigin(origin(anchor: anchor, windowFrame: windowFrame))
            if !badge.panel.isVisible { badge.panel.orderFrontRegardless() }
            observe(window)
        }

        for id in badges.keys where !live.contains(id) {
            if let element = observedWindows[id], let observer {
                AXObserverRemoveNotification(observer, element, kAXMovedNotification as CFString)
                AXObserverRemoveNotification(observer, element, kAXResizedNotification as CFString)
            }
            badges[id]?.panel.orderOut(nil)
            badges.removeValue(forKey: id)
            observedWindows.removeValue(forKey: id)
        }
    }

    /// Move and resize notifications. Reapplies the cached corner inset; it does not walk the tree.
    func repositionAnchoredBadges() {
        for (id, badge) in badges {
            guard let anchor = badge.anchor, let element = observedWindows[id], let windowFrame = reader.frame(of: element) else { continue }
            guard badge.panel.isVisible || isOnAnyScreen(windowFrame) else { continue }
            badge.panel.setFrameOrigin(origin(anchor: anchor, windowFrame: windowFrame))
            if !badge.panel.isVisible { badge.panel.orderFrontRegardless() }
        }
    }

    private func makeBadge(for window: WindowMonitor, model: AppModel) -> Badge {
        let side = WindowBadgeView.size
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: side, height: side),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let host = FirstMouseHostingView(rootView: WindowBadgeView(window: window, model: model, onClick: { [weak self] in
            self?.onOpenDashboard?()
        }))
        host.frame = NSRect(x: 0, y: 0, width: side, height: side)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = host

        let badge = Badge(panel: panel)
        badges[window.id] = badge
        return badge
    }

    private func origin(anchor: Anchor, windowFrame: CGRect) -> CGPoint {
        let side = WindowBadgeView.size
        let buttonX = windowFrame.maxX - anchor.fromRight
        let buttonY = windowFrame.minY + anchor.fromTop
        let badgeX = buttonX - gap - side
        let badgeY = buttonY + (anchor.buttonHeight - side) / 2
        return CGPoint(x: badgeX, y: primaryTop - (badgeY + side))
    }

    private func observe(_ window: WindowMonitor) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(window.element, &pid) == .success else { return }
        if observedPID != pid {
            if let observer {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
            observer = nil
            observedWindows.removeAll()
            observedPID = pid
            var created: AXObserver?
            guard AXObserverCreate(pid, floatingBarMoved, &created) == .success, let created else { return }
            observer = created
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        }
        guard let observer, observedWindows[window.id] == nil else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, window.element, kAXMovedNotification as CFString, refcon)
        AXObserverAddNotification(observer, window.element, kAXResizedNotification as CFString, refcon)
        observedWindows[window.id] = window.element
    }

    /// Cursor draws Toggle Panel inside the web content, about 16 levels down, as an AXCheckBox named "Toggle Panel (⌘J)".
    private func togglePanelFrame(in window: AXUIElement) -> CGRect? {
        let attributes = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXChildrenAttribute] as CFArray
        var stack: [(element: AXUIElement, depth: Int)] = [(window, 0)]
        var visited = 0
        while let item = stack.popLast(), visited < 2_000 {
            visited += 1
            var raw: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(item.element, attributes, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
                  let values = raw as? [Any], values.count == 5 else { continue }
            let role = values[0] as? String ?? ""
            let text = [values[1] as? String, values[2] as? String, values[3] as? String]
                .compactMap { $0 }
                .joined(separator: " ")
                .lowercased()
            if text.contains("toggle panel") || text.contains("切换面板"),
               role == "AXButton" || role == "AXCheckBox" || role == "AXPopUpButton" || role == "AXMenuButton",
               let frame = reader.frame(of: item.element), frame.width <= 220, frame.height <= 80 {
                return frame
            }
            guard item.depth < 24, role != "AXTextArea", role != "AXOutline" else { continue }
            let children = (values[4] as? [AXUIElement] ?? []).reversed()
            for child in children { stack.append((child, item.depth + 1)) }
        }
        return nil
    }

    private var primaryTop: CGFloat {
        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
        return primary?.frame.maxY ?? 0
    }

    private func isOnAnyScreen(_ topLeftFrame: CGRect) -> Bool {
        let rect = CGRect(x: topLeftFrame.minX, y: primaryTop - topLeftFrame.maxY, width: topLeftFrame.width, height: topLeftFrame.height)
        return NSScreen.screens.contains { $0.frame.intersects(rect) }
    }
}

private func floatingBarMoved(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let controller = Unmanaged<FloatingBarController>.fromOpaque(refcon).takeUnretainedValue()
    DispatchQueue.main.async {
        MainActor.assumeIsolated { controller.repositionAnchoredBadges() }
    }
}

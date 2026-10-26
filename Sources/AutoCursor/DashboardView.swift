import AppKit
import SwiftUI

struct DashboardView: View {
    @ObservedObject var model: AppModel

    static let width: CGFloat = 440
    private static let maxVisibleWindows = 4
    private static let visibleActivityRows = 4
    private static let activityRowHeight: CGFloat = 34

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if !model.permissionGranted {
                PermissionCard(bundlePath: model.bundlePath, stale: model.accessibilityStale)
            }
            if model.permissionGranted, model.wakeHookPresence != .installed {
                WakeHookCard(presence: model.wakeHookPresence, install: { try model.installWakeHook() })
            }
            section("Cursor 窗口", trailing: model.windows.isEmpty ? nil : "\(model.windows.count)") {
                windowsList
            }
            section("最近活动", trailing: nil) {
                activityList
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 20)
        .frame(width: Self.width, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .background(VisualEffectBackground().ignoresSafeArea())
    }

    private var isRunning: Bool { model.permissionGranted && model.wakeHookPresence == .installed && model.masterEnabled }

    private var statusText: String {
        if !model.permissionGranted { return "等待授权" }
        if model.wakeHookPresence == .missing { return "Hook 未配置" }
        if model.wakeHookPresence == .unreadable { return "Hook 无法读取" }
        return model.masterEnabled ? "运行中" : "已暂停"
    }

    private var statusColor: Color {
        if isRunning { return Theme.success }
        if model.permissionGranted, model.wakeHookPresence != .installed { return Theme.warning }
        return .secondary
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: AppIcon.image(size: 128))
                .resizable()
                .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text("AutoCursor")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                HStack(spacing: 3) {
                    StatusDot(color: statusColor)
                        .scaleEffect(0.8)
                    Text(statusText)
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                }
                .padding(.leading, -3)
            }
            Spacer(minLength: 8)
            HeaderStat(title: "被动唤醒", value: model.wakeClicked, highlighted: true)
            HeaderStat(title: "主动扫描", value: model.activeClicked)
            HeaderStat(title: "合计", value: model.totalClicked)
            Toggle("", isOn: $model.masterEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!model.permissionGranted)
                .padding(.leading, 6)
        }
    }

    @ViewBuilder
    private var windowsList: some View {
        if model.windows.isEmpty {
            Placeholder(text: !model.permissionGranted ? "授权后将自动发现 Cursor 窗口"
                        : model.cursorState == .notRunning ? "打开 Cursor 后，窗口会自动出现在这里"
                        : "暂未发现可访问的 Cursor 窗口")
        } else {
            let rows = VStack(spacing: 0) {
                ForEach(Array(model.windows.enumerated()), id: \.element.id) { index, monitor in
                    if index > 0 { Divider() }
                    WindowSection(monitor: monitor, masterEnabled: model.masterEnabled)
                }
            }
            if model.windows.count > Self.maxVisibleWindows {
                ScrollView { rows }
                    .frame(height: 380)
            } else {
                rows
            }
        }
    }

    @ViewBuilder
    private var activityList: some View {
        if model.events.isEmpty {
            Placeholder(text: "暂无活动")
        } else {
            let rows = VStack(spacing: 0) {
                ForEach(Array(model.events.enumerated()), id: \.element.id) { index, event in
                    if index > 0 { Divider().padding(.leading, 34) }
                    ActivityRow(event: event).frame(height: Self.activityRowHeight)
                }
            }
            if model.events.count > Self.visibleActivityRows {
                ScrollView(.vertical, showsIndicators: true) { rows }
                    .frame(height: Self.activityRowHeight * CGFloat(Self.visibleActivityRows))
            } else {
                rows
            }
        }
    }

    private func section<Content: View>(_ title: String, trailing: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 4)
            Card { content() }
        }
    }
}

private struct HeaderStat: View {
    let title: String
    let value: Int
    var highlighted = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text("\(value)")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(highlighted ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.primary))
            Text(title)
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
        }
        .frame(minWidth: 30, alignment: .trailing)
    }
}

private struct Placeholder: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
    }
}

private struct WindowSection: View {
    @ObservedObject var monitor: WindowMonitor
    let masterEnabled: Bool

    var body: some View {
        VStack(spacing: 0) {
            WindowRow(monitor: monitor, masterEnabled: masterEnabled)
                .frame(height: 52)
            if !monitor.expanded {
                EmptyView()
            } else if monitor.agents.isEmpty {
                Text("未发现 Agent 面板")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 70)
                    .padding(.bottom, 10)
            } else {
                VStack(spacing: 0) {
                    ForEach(monitor.agents) { agent in
                        AgentSection(agent: agent, parentActive: masterEnabled && monitor.enabled)
                    }
                }
                .padding(.bottom, 6)
            }
        }
    }
}

private struct AgentSection: View {
    @ObservedObject var agent: AgentMonitor
    let parentActive: Bool

    var body: some View {
        VStack(spacing: 0) {
            AgentRow(agent: agent, parentActive: parentActive)
                .frame(height: 34)
            ForEach(agent.subagents) { subagent in
                SubagentRow(subagent: subagent, clicks: agent.subagentClicks[subagent.name] ?? 0,
                            active: parentActive && agent.enabled)
                    .frame(height: 30)
            }
        }
    }
}

private struct SubagentRow: View {
    let subagent: SubagentInfo
    let clicks: Int
    let active: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(subagent.name)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !subagent.status.isEmpty {
                    Text(subagent.status)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            if subagent.awaitingApproval {
                Text("等待确认")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Theme.warning)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Theme.warning.opacity(0.15)))
            } else if clicks > 0 {
                Text("合计 \(clicks)")
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.leading, 92)
        .padding(.trailing, 12)
        .opacity(active ? 1 : 0.55)
        .help(subagent.status.isEmpty ? subagent.name : "\(subagent.name)\n\(subagent.status)")
    }
}

private struct AgentRow: View {
    @ObservedObject var agent: AgentMonitor
    let parentActive: Bool

    private var active: Bool { parentActive && agent.enabled }

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $agent.enabled)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .labelsHidden()
                .disabled(!parentActive)
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(active ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.secondary))
            Text(agent.key)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(agent.enabled ? "合计 \(agent.clickedCount)" : "已停用")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
        .padding(.leading, 70)
        .padding(.trailing, 12)
        .opacity(active ? 1 : 0.55)
    }
}

private struct WindowRow: View {
    @ObservedObject var monitor: WindowMonitor
    let masterEnabled: Bool

    private var active: Bool { masterEnabled && monitor.enabled }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { monitor.expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(monitor.expanded ? 90 : 0))
                        .animation(.easeInOut(duration: 0.15), value: monitor.expanded)
                        .frame(width: 12)
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(active ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.primary.opacity(0.08)))
                        Image(systemName: "macwindow")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(active ? .white : .secondary)
                    }
                    .frame(width: 30, height: 30)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(monitor.displayTitle)
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(monitor.expanded ? "收起 Agent" : "展开 Agent")

            Toggle("", isOn: $monitor.enabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(!masterEnabled)
        }
        .padding(.horizontal, 12)
        .opacity(active ? 1 : 0.6)
    }

    private var subtitle: String {
        if !masterEnabled { return "已暂停" }
        if !monitor.enabled { return "已停用" }
        let agents = monitor.agents.isEmpty ? "" : "\(monitor.agents.count) 个 Agent · "
        return "\(agents)被动唤醒 \(monitor.wakeClicked) · 主动扫描 \(monitor.activeClicked) · 合计 \(monitor.clickedCount)"
    }
}

private struct ActivityRow: View {
    let event: ActivityEvent

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: event.clicked ? "checkmark.circle.fill" : "eye.circle.fill")
                .font(.system(size: 13))
                .foregroundColor(event.clicked ? Theme.success : Theme.warning)
                .frame(width: 16)
            Text(event.clicked ? "点击「\(event.buttonTitle)」" : "检测到「\(event.buttonTitle)」")
                .font(.system(size: 12, weight: .medium))
            Text(event.trigger.label)
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
            Text(event.windowTitle)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(Self.formatter.string(from: event.date))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
    }
}

private struct WakeHookCard: View {
    let presence: WakeHookPresence
    let install: () throws -> Void

    var body: some View {
        Card(tint: Theme.warning) {
            VStack(alignment: .leading, spacing: 9) {
                Label(presence == .unreadable ? "Cursor Hook 无法读取" : "未配置 Cursor Hook", systemImage: "bell.slash.fill")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(Theme.warning)
                Text(presence == .unreadable
                     ? "~/.cursor/hooks.json 不是合法的 JSON，AutoCursor 没有改动它。现在只会大约每 10 秒扫描一次。"
                     : "没有用户级 Hook 时，Cursor 不会在命令执行前叫醒 AutoCursor，确认按钮要等到大约每 10 秒的兜底扫描。")
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(WakeHook.hooksFile.path)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    if presence == .missing {
                        Button("安装 Hook", action: installHook)
                            .keyboardShortcut(.defaultAction)
                    }
                    Button("在 Finder 中显示") {
                        let file = WakeHook.hooksFile
                        let url = FileManager.default.fileExists(atPath: file.path) ? file : file.deletingLastPathComponent()
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                .controlSize(.small)
            }
            .padding(14)
        }
    }

    private func installHook() {
        do {
            try install()
        } catch let error as WakeHookError {
            let alert = NSAlert()
            alert.messageText = "无法安装 Hook"
            alert.informativeText = error.description
            alert.runModal()
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法安装 Hook"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

private struct PermissionCard: View {
    let bundlePath: String
    var stale = false

    var body: some View {
        Card(tint: Theme.warning) {
            VStack(alignment: .leading, spacing: 9) {
                Label(stale ? "辅助功能授权是旧的" : "需要辅助功能权限", systemImage: "lock.shield.fill")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(Theme.warning)
                Text(stale
                     ? "系统设置里的 AutoCursor 是上一份签名的授权，勾选它不会作用于现在这个程序。请先退出，删掉列表中的 AutoCursor，再重新打开，然后勾选新出现的条目。"
                     : "在「系统设置 → 隐私与安全性 → 辅助功能」中开启 AutoCursor，授权后自动开始。")
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(bundlePath)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    Button("打开辅助功能设置") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: bundlePath)])
                    }
                }
                .controlSize(.small)
            }
            .padding(14)
        }
    }
}

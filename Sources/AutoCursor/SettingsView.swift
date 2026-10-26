import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    let onExportDiagnostics: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            group("启动") {
                SettingRow(title: "开机启动", detail: launchAtLoginDetail) {
                    HStack(spacing: 8) {
                        if model.launchAtLoginNeedsApproval {
                            Button("去允许") { AppModel.openLoginItems() }
                                .controlSize(.small)
                        }
                        Toggle("", isOn: Binding(
                            get: { model.launchAtLogin },
                            set: { model.setLaunchAtLogin($0) }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                    }
                }
            }

            group("自动点击") {
                SettingRow(title: "点击间隔", detail: "两次自动点击的最短间隔") {
                    Picker("", selection: $model.clickInterval) {
                        ForEach(AppModel.clickIntervalOptions, id: \.self) { value in
                            Text(value < 1 ? "\(value, specifier: "%.1f")s" : "\(Int(value))s").tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 200)
                }
            }

            group("界面") {
                SettingRow(title: "窗口标志", detail: "显示在 Toggle Panel 左边，单击可开关该窗口") {
                    Toggle("", isOn: $model.showFloatingBars)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
            }

            group("权限与诊断") {
                VStack(spacing: 0) {
                    SettingRow(title: "辅助功能权限", detail: accessibilityDetail) {
                        Button("打开系统设置") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                    }
                    Divider().padding(.leading, 14)
                    SettingRow(title: "Cursor Hook", detail: wakeHookDetail) {
                        Button(model.wakeHookPresence == .missing ? "安装" : "显示") {
                            if model.wakeHookPresence == .missing {
                                installWakeHook()
                            } else {
                                NSWorkspace.shared.activateFileViewerSelecting([WakeHook.hooksFile])
                            }
                        }
                        .controlSize(.small)
                    }
                    Divider().padding(.leading, 14)
                    SettingRow(title: "导出诊断", detail: "识别失败时，将 Cursor 的辅助功能树导出到桌面") {
                        Button("导出…", action: onExportDiagnostics)
                            .controlSize(.small)
                            .disabled(!model.permissionGranted)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .background(VisualEffectBackground().ignoresSafeArea())
        .onAppear {
            model.refreshWakeHook()
            model.refreshLaunchAtLogin()
        }
    }

    private var launchAtLoginDetail: String {
        if let message = model.launchAtLoginMessage { return message }
        if model.launchAtLoginNeedsApproval { return "已加入登录项，需在系统设置里允许" }
        if model.launchAtLogin { return "登录后自动打开 AutoCursor" }
        return "登录后不自动打开"
    }

    private var accessibilityDetail: String {
        if model.permissionGranted { return "已授权" }
        if model.accessibilityStale { return "系统设置里为旧授权，需删掉旧授权后重启应用授权" }
        return "未授权，无法检测和点击"
    }

    private var wakeHookDetail: String {
        switch model.wakeHookPresence {
        case .installed: return "已配置，命令执行前会叫醒 AutoCursor"
        case .missing: return "未配置，确认出现时不会被叫醒"
        case .unreadable: return "hooks.json 无法解析，未改动"
        }
    }

    private func installWakeHook() {
        do {
            try model.installWakeHook()
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

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 4)
            Card { content() }
        }
    }
}

struct SettingRow<Control: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
    }
}

enum AboutPanel {
    @MainActor
    static func show() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 6
        let credits = NSAttributedString(
            string: """
            自动确认 Cursor Agent 的运行请求。
            通过 macOS 辅助功能识别 Run、Always Run 等确认按钮，并按设定的间隔自动点击；每个 Cursor 窗口都可以单独停用。
            """,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]
        )
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationIcon: AppIcon.image(size: 256),
            .applicationName: "AutoCursor",
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "本地构建 · 仅供个人使用",
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
}

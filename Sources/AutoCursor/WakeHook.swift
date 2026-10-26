import Foundation

enum WakeHookPresence: Equatable {
    case installed
    case missing
    case unreadable
}

enum WakeHookError: Error, CustomStringConvertible {
    case unreadable
    case writeFailed

    var description: String {
        switch self {
        case .unreadable: return "hooks.json 无法解析，未改动"
        case .writeFailed: return "无法写入 ~/.cursor/hooks.json"
        }
    }
}

/// User-level Cursor hook that posts `notificationName` and then allows the command.
enum WakeHook {
    static let notificationName = "local.autocursor.wake"
    static let scriptCommand = "./hooks/autocursor-wake.sh"
    private static let events = ["beforeShellExecution", "beforeMCPExecution"]

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cursor")
    }

    static var hooksFile: URL {
        directory.appendingPathComponent("hooks.json")
    }

    private static var scriptFile: URL {
        directory.appendingPathComponent("hooks/autocursor-wake.sh")
    }

    static func presence() -> WakeHookPresence {
        guard FileManager.default.fileExists(atPath: hooksFile.path) else { return .missing }
        guard let hooks = hookTable() else { return .unreadable }
        let present = events.allSatisfy { event in
            commands(in: hooks, event: event).contains { isWakeCommand($0) }
        }
        return present ? .installed : .missing
    }

    /// Adds the wake script and the two event entries. Leaves an unreadable hooks.json untouched.
    static func install() throws {
        let hooks: [String: Any]
        if FileManager.default.fileExists(atPath: hooksFile.path) {
            guard let existing = hookTable() else { throw WakeHookError.unreadable }
            hooks = existing
        } else {
            hooks = [:]
        }

        try FileManager.default.createDirectory(at: scriptFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try scriptSource.write(to: scriptFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptFile.path)

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: hooksFile),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = parsed
        }
        if root["version"] == nil { root["version"] = 1 }

        var next = hooks
        let entry: [String: Any] = ["command": scriptCommand, "timeout": 5]
        for event in events {
            var list = next[event] as? [[String: Any]] ?? []
            let already = list.contains { command in
                guard let text = command["command"] as? String else { return false }
                return isWakeCommand(text)
            }
            if !already { list.append(entry) }
            next[event] = list
        }
        root["hooks"] = next

        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted]) else {
            throw WakeHookError.writeFailed
        }
        do {
            try data.write(to: hooksFile, options: .atomic)
        } catch {
            throw WakeHookError.writeFailed
        }
    }

    /// `nil` means the file exists but is not a JSON object. A missing `hooks` key is an empty table.
    private static func hookTable() -> [String: Any]? {
        guard let data = try? Data(contentsOf: hooksFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return root["hooks"] as? [String: Any] ?? [:]
    }

    private static func commands(in hooks: [String: Any], event: String) -> [String] {
        guard let list = hooks[event] as? [[String: Any]] else { return [] }
        return list.compactMap { $0["command"] as? String }
    }

    private static func isWakeCommand(_ command: String) -> Bool {
        command.contains("autocursor-wake.sh") || command.contains(notificationName)
    }

    private static let scriptSource = """
    #!/bin/bash
    cat > /dev/null
    echo '{ "permission": "allow" }'
    /usr/bin/notifyutil -p \(notificationName)
    exit 0

    """
}

import ApplicationServices
import Foundation

struct ElementRef: @unchecked Sendable {
    let element: AXUIElement
}

struct SubagentInfo: Sendable, Equatable, Identifiable {
    let name: String
    let status: String
    let awaitingApproval: Bool
    var id: String { name }
}

struct AgentInfo: Sendable {
    let key: String
    let name: String
    /// Pane frame in global top-left-origin coordinates.
    let frame: CGRect?
    var subagents: [SubagentInfo] = []
}

struct ScanHit: Sendable {
    let agentKey: String
    let subagent: String?
    let label: String
    let clicked: Bool
}

struct WindowScan: Sendable {
    let windowID: UInt64
    let agents: [AgentInfo]
    let hit: ScanHit?
}

/// Finds Cursor's run-confirmation controls, restricted to Agent panes.
/// An Agent pane is located from its composer (a text area next to the model picker) and extends
/// upwards until the next ancestor would also contain an editor tab bar.
/// Not thread-safe: use from a single serial queue.
final class PromptScanner: @unchecked Sendable {
    private struct Node {
        let element: AXUIElement
        let role: String
        let text: String
        let selected: Bool
        let parent: Int
        var end = 0
    }

    private struct Pane {
        let root: Int
        var info: AgentInfo
        var cards: [(root: Int, name: String)] = []
    }

    private struct Match {
        let index: Int
        let label: String
        let agentKey: String
    }

    /// Ordered by click preference when several controls of one prompt are visible.
    static let unconditionalLabels = ["always run", "run command", "run", "execute"]
    static let conditionalLabels = ["always allow", "allow", "allow once", "approve", "confirm"]
    private static let priority = Dictionary(uniqueKeysWithValues: (unconditionalLabels + conditionalLabels).enumerated().map { ($1, $0) })
    private static let promptMarkers: Set<String> = Set(unconditionalLabels + conditionalLabels)
        .union(["skip", "reject", "cancel", "deny", "decline"])
    private static let contextMarkers = ["terminal", "command", "agent", "shell", "permission", "workspace", "full access", "mcp", "tool"]
    private static let matchableRoles: Set<String> = ["AXButton", "AXStaticText", "AXGroup", "AXLink", "AXMenuItem", "AXCell"]
    private static let opaqueRoles: Set<String> = ["AXTextArea", "AXTextField", "AXOutline", "AXMenuBar", "AXImage"]
    /// Strips the editor-group suffix and the unread badge, e.g. "(1) Name, Chat Editors: Editor Group 1" → "Name".
    private static let tabSuffixPattern = "^\\(\\d+\\) |, (Chat Editors: )?Editor Group \\d+$"
    private static let toolOptionsLabel = "Shell command options"
    /// Button rows only hold short labels such as "Always Run⇧⏎"; chat prose containing the same words is longer.
    private static let maxButtonRowTextLength = 24

    private let attributes = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXChildrenAttribute] as CFArray
    private let reader = AccessibilityReader()
    private let maxNodes = 25_000
    private let maxDepth = 120
    private var lastClickByWindow: [UInt64: Date] = [:]
    private var pressed: [(element: AXUIElement, date: Date)] = []
    private var muted: [AXUIElement] = []

    func scan(windowID: UInt64, root: AXUIElement, clickEnabled: Bool, disabledAgents: Set<String>,
              clickInterval: TimeInterval, dryRun: Bool, verbose: Bool) -> WindowScan {
        let nodes = buildTree(root)
        let panes = findPanes(in: nodes)
        let agents = panes.map(\.info)
        if verbose { print("[scan] \(nodes.count) nodes, agents=\(agents.map(\.name))") }

        if !clickEnabled { return WindowScan(windowID: windowID, agents: agents, hit: nil) }
        if let last = lastClickByWindow[windowID], Date().timeIntervalSince(last) < clickInterval {
            return WindowScan(windowID: windowID, agents: agents, hit: nil)
        }

        let candidates = panes
            .filter { !disabledAgents.contains($0.info.key) }
            .flatMap { matches(in: nodes, pane: $0) }
            .filter { !isMuted(nodes[$0.index].element) && isConfirmedPrompt($0, nodes: nodes) }
            .sorted { (Self.priority[$0.label] ?? .max) < (Self.priority[$1.label] ?? .max) }
        guard let match = candidates.first else { return WindowScan(windowID: windowID, agents: agents, hit: nil) }

        let element = nodes[match.index].element
        if let previous = pressed.first(where: { CFEqual($0.element, element) }) {
            // A real confirmation disappears once pressed; anything still here is not a prompt button.
            if Date().timeIntervalSince(previous.date) > 0.8 {
                muted.append(element)
                if verbose { print("[mute] \(match.label.debugDescription) still present after press") }
            }
            return WindowScan(windowID: windowID, agents: agents, hit: nil)
        }

        lastClickByWindow[windowID] = Date()
        let clicked: Bool
        if dryRun {
            print("[dry-run] would press \(match.label.debugDescription) in \(match.agentKey)")
            clicked = false
        } else {
            clicked = press(match, nodes: nodes)
            pressed.append((element, Date()))
            if pressed.count > 50 { pressed.removeFirst(pressed.count - 50) }
            print("[\(clicked ? "click" : "fail")] \(match.label.debugDescription) in \(match.agentKey)")
        }
        let subagent = panes.first { $0.info.key == match.agentKey }?.cards
            .first { contains($0.root, match.index, in: nodes) }?.name
        return WindowScan(windowID: windowID, agents: agents,
                          hit: ScanHit(agentKey: match.agentKey, subagent: subagent, label: match.label, clicked: clicked))
    }

    func diagnostics(root: AXUIElement) -> String {
        let nodes = buildTree(root)
        let panes = findPanes(in: nodes)
        let candidates = panes.flatMap { matches(in: nodes, pane: $0) }.map { match in
            "\(match.label)#\(match.index)@\(match.agentKey):\(isConfirmedPrompt(match, nodes: nodes) ? "prompt" : "ignored")"
        }
        var lines = ["agents=\(panes.map { "\($0.info.name)@\($0.root)" })", "candidates=\(candidates)"]
        lines += panes.flatMap { pane in pane.cards.map { "subagent \(pane.info.name) › \($0.name)@\($0.root)" } }
        var depths = [Int](repeating: 0, count: nodes.count)
        for (index, node) in nodes.enumerated() {
            if node.parent >= 0 { depths[index] = depths[node.parent] + 1 }
            let actions = actionNames(node.element)
            guard !node.text.isEmpty || actions.contains(kAXPressAction as String) else { continue }
            let indent = String(repeating: " ", count: min(depths[index], 60))
            lines.append("\(indent)#\(index) d=\(depths[index]) \(node.role) \(String(node.text.prefix(80)).debugDescription)\(node.selected ? " selected" : "") actions=\(actions)")
        }
        lines.append("visited=\(nodes.count)")
        return lines.joined(separator: "\n")
    }

    // MARK: - Tree

    /// Flattens the accessibility tree in pre-order; `end` marks the exclusive end of each subtree.
    private func buildTree(_ root: AXUIElement) -> [Node] {
        var nodes: [Node] = []
        var stack: [(element: AXUIElement, parent: Int, depth: Int)] = [(root, -1, 0)]
        while let item = stack.popLast(), nodes.count < maxNodes {
            guard let (role, text, selected, children) = read(item.element) else { continue }
            let index = nodes.count
            nodes.append(Node(element: item.element, role: role, text: text, selected: selected, parent: item.parent))
            guard item.depth < maxDepth, !Self.opaqueRoles.contains(role) else { continue }
            for child in children.reversed() { stack.append((child, index, item.depth + 1)) }
        }
        for index in nodes.indices.reversed() {
            nodes[index].end = max(nodes[index].end, index + 1)
            let parent = nodes[index].parent
            if parent >= 0 { nodes[parent].end = max(nodes[parent].end, nodes[index].end) }
        }
        return nodes
    }

    private func ancestors(of index: Int, in nodes: [Node], limit: Int) -> [Int] {
        var result: [Int] = []
        var current = nodes[index].parent
        while current >= 0, result.count < limit {
            result.append(current)
            current = nodes[current].parent
        }
        return result
    }

    private func contains(_ ancestor: Int, _ index: Int, in nodes: [Node]) -> Bool {
        index >= ancestor && index < nodes[ancestor].end
    }

    // MARK: - Agent panes

    private func findPanes(in nodes: [Node]) -> [Pane] {
        let composers = findComposers(in: nodes)
        let boundaries = nodes.indices.filter { nodes[$0].role == "AXRadioButton" && nodes[$0].text.contains("Editor Group") }

        var panes: [Pane] = []
        var usedKeys = Set<String>()
        for composer in composers {
            var root = nodes[composer].parent
            guard root >= 0 else { continue }
            while nodes[root].parent >= 0 {
                let parent = nodes[root].parent
                let otherComposer = composers.contains { $0 != composer && contains(parent, $0, in: nodes) }
                let tabBar = boundaries.contains { contains(parent, $0, in: nodes) }
                if otherComposer || tabBar { break }
                root = parent
            }

            // Tab bars precede their editor content in pre-order, so the closest selected tab before the composer names it.
            var name = "Agent"
            if let tab = boundaries.last(where: { $0 < composer && nodes[$0].selected }) {
                let title = nodes[tab].text.replacingOccurrences(of: Self.tabSuffixPattern, with: "", options: .regularExpression)
                if !title.isEmpty { name = title }
            }
            var key = name
            var suffix = 2
            while usedKeys.contains(key) { key = "\(name) #\(suffix)"; suffix += 1 }
            usedKeys.insert(key)
            panes.append(Pane(root: root, info: AgentInfo(key: key, name: key, frame: reader.frame(of: nodes[root].element))))
        }

        // Subagent chats open as composer-less chat editors; the selected tab's editor group is their pane.
        for tab in boundaries where nodes[tab].selected && nodes[tab].text.contains("Chat Editors") {
            guard let root = editorGroupRoot(of: tab, in: nodes),
                  !panes.contains(where: { contains(root, $0.root, in: nodes) || contains($0.root, root, in: nodes) })
            else { continue }
            let title = nodes[tab].text.replacingOccurrences(of: Self.tabSuffixPattern, with: "", options: .regularExpression)
            let name = title.isEmpty ? "Subagent" : title
            var key = name
            var suffix = 2
            while usedKeys.contains(key) { key = "\(name) #\(suffix)"; suffix += 1 }
            usedKeys.insert(key)
            panes.append(Pane(root: root, info: AgentInfo(key: key, name: key, frame: reader.frame(of: nodes[root].element))))
        }
        for index in panes.indices {
            let cards = findSubagentCards(in: nodes, pane: panes[index])
            panes[index].cards = cards.map { ($0.root, $0.info.name) }
            panes[index].info.subagents = cards.map(\.info)
        }
        return panes.sorted { $0.root < $1.root }
    }

    /// Running subagents appear in the parent chat as a button card: "<task>" "<model>" "<status>" with a Stop
    /// (and, while waiting, an Allow) button inside.
    private func findSubagentCards(in nodes: [Node], pane: Pane) -> [(root: Int, info: SubagentInfo)] {
        var cards: [(root: Int, info: SubagentInfo)] = []
        var names = Set<String>()
        var index = pane.root
        while index < nodes[pane.root].end {
            let card = index
            index += 1
            guard nodes[card].role == "AXButton", nodes[card].end - card > 1 else { continue }
            let range = (card + 1)..<nodes[card].end
            let buttons = Set(range.filter { nodes[$0].role == "AXButton" }.map { Self.normalize(nodes[$0].text) })
            guard buttons.contains("stop") || buttons.contains("allow"),
                  let title = range.first(where: { nodes[$0].role == "AXStaticText" && !nodes[$0].text.isEmpty }) else { continue }
            let name = nodes[title].text.trimmingCharacters(in: .whitespaces)
            let status = range.last {
                $0 != title && nodes[$0].parent == nodes[title].parent && nodes[$0].role == "AXStaticText" && !nodes[$0].text.isEmpty
            }.map { nodes[$0].text.trimmingCharacters(in: .whitespaces) } ?? ""
            guard !name.isEmpty, names.insert(name).inserted else { continue }
            cards.append((card, SubagentInfo(name: name, status: status, awaitingApproval: buttons.contains("allow"))))
            index = nodes[card].end
        }
        return cards
    }

    /// The closest ancestor of the tab strip that also holds editor content (anything outside the tabs and toolbars).
    private func editorGroupRoot(of tab: Int, in nodes: [Node]) -> Int? {
        guard let strip = ancestors(of: tab, in: nodes, limit: 4).first(where: { nodes[$0].role == "AXTabGroup" }) else { return nil }
        for ancestor in ancestors(of: strip, in: nodes, limit: 4) {
            let hasContent = (ancestor..<nodes[ancestor].end).contains { index in
                guard !contains(strip, index, in: nodes), nodes[index].role == "AXStaticText",
                      nodes[index].text.contains(where: { $0.isLetter || $0.isNumber }) else { return false }
                return !ancestors(of: index, in: nodes, limit: 4).contains { nodes[$0].role == "AXToolbar" }
            }
            if hasContent { return ancestor }
        }
        return nil
    }

    /// Each model picker belongs to exactly one composer: the closest text area sharing a nearby ancestor.
    /// Starting from the picker avoids treating the edit boxes of earlier chat messages as composers.
    private func findComposers(in nodes: [Node]) -> [Int] {
        let pickers = nodes.indices.filter {
            nodes[$0].role == "AXPopUpButton" && !nodes[$0].text.isEmpty && nodes[$0].text != Self.toolOptionsLabel
        }
        var composers = Set<Int>()
        for picker in pickers {
            for ancestor in ancestors(of: picker, in: nodes, limit: 6) {
                let areas = (ancestor..<nodes[ancestor].end).filter { nodes[$0].role == "AXTextArea" }
                if let closest = areas.min(by: { abs($0 - picker) < abs($1 - picker) }) {
                    composers.insert(closest)
                    break
                }
            }
        }
        return composers.sorted()
    }

    // MARK: - Matching

    private func matches(in nodes: [Node], pane: Pane) -> [Match] {
        (pane.root..<nodes[pane.root].end).compactMap { index in
            let node = nodes[index]
            guard Self.matchableRoles.contains(node.role), !node.text.isEmpty, node.text.count <= Self.maxButtonRowTextLength else { return nil }
            let label = Self.normalize(node.text)
            guard Self.priority[label] != nil else { return nil }
            return Match(index: index, label: label, agentKey: pane.info.key)
        }
    }

    private func isConfirmedPrompt(_ match: Match, nodes: [Node]) -> Bool {
        let isUnconditional = Self.unconditionalLabels.contains(match.label)
        if isUnconditional, nodes[match.index].role == "AXButton" { return true }

        let lineage = ancestors(of: match.index, in: nodes, limit: 8)
        if isSubagentApproval(match, lineage: lineage, nodes: nodes) { return true }
        for (level, ancestor) in lineage.prefix(5).enumerated() {
            let texts = subtreeTexts(of: ancestor, in: nodes, limit: 120)
            let labels = Set(texts.map(Self.normalize)).subtracting(["", match.label])
            guard !labels.isDisjoint(with: Self.promptMarkers) else { continue }

            // The closest ancestor holding a sibling option is the button row; prose means chat content.
            guard texts.count <= 10, texts.allSatisfy(Self.isButtonLabel) else { return false }
            if isUnconditional { return true }

            guard let context = lineage.dropFirst(level + 1).prefix(3).last else { return false }
            let joined = subtreeTexts(of: context, in: nodes, limit: 600).map(Self.normalize).joined(separator: " ")
            return Self.contextMarkers.contains { joined.contains($0) }
        }
        return false
    }

    /// Background subagent cards in the parent chat ask inline: "<task> <model> <status>" followed by [Allow] [Stop],
    /// where the status is "Run <command>" or "Waiting for approval" depending on the Cursor version.
    private func isSubagentApproval(_ match: Match, lineage: [Int], nodes: [Node]) -> Bool {
        guard match.label == "allow" else { return false }
        func buttons(under ancestor: Int) -> Set<String> {
            Set(((ancestor + 1)..<nodes[ancestor].end).filter { nodes[$0].role == "AXButton" }.map { Self.normalize(nodes[$0].text) })
        }
        guard let rowLevel = lineage.prefix(3).firstIndex(where: { buttons(under: $0).contains("stop") }),
              buttons(under: lineage[rowLevel]).isSubset(of: ["allow", "stop"]) else { return false }
        return lineage.dropFirst(rowLevel).prefix(3).contains { card in
            (card..<nodes[card].end).contains { index in
                guard nodes[index].role == "AXStaticText" else { return false }
                let text = Self.normalize(nodes[index].text)
                return nodes[index].text.hasPrefix("Run ") || text.contains("waiting for approval")
            }
        }
    }

    private func press(_ match: Match, nodes: [Node]) -> Bool {
        let element = nodes[match.index].element
        if nodes[match.index].role == "AXButton" {
            return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
        }
        for ancestor in ancestors(of: match.index, in: nodes, limit: 3) {
            // Shortcut hints such as "⌃C" or "⇧⏎" normalize to at most one character.
            let labels = Set(subtreeTexts(of: ancestor, in: nodes, limit: 20).map(Self.normalize)).filter { $0.count > 1 }
            guard labels == [match.label] else { break }
            if actionNames(nodes[ancestor].element).contains(kAXPressAction as String),
               AXUIElementPerformAction(nodes[ancestor].element, kAXPressAction as CFString) == .success {
                return true
            }
        }
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    private func subtreeTexts(of index: Int, in nodes: [Node], limit: Int) -> [String] {
        (index..<min(nodes[index].end, index + limit)).compactMap { i in
            let node = nodes[i]
            let isLeaf = i + 1 == node.end
            return (node.role == "AXStaticText" || isLeaf) && !node.text.isEmpty ? node.text : nil
        }
    }

    private func isMuted(_ element: AXUIElement) -> Bool {
        muted.contains { CFEqual($0, element) }
    }

    // MARK: - Accessibility I/O

    private func read(_ element: AXUIElement) -> (String, String, Bool, [AXUIElement])? {
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributes, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
              let values = raw as? [Any], values.count == 5 else { return nil }
        let role = values[0] as? String ?? ""
        let title = values[1] as? String ?? ""
        let description = values[2] as? String ?? ""
        let value = values[3] as? String ?? ""
        let selected = role == "AXRadioButton" && (values[3] as? NSNumber)?.boolValue == true
        let text = [title, description, value].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return (role, text, selected, values[4] as? [AXUIElement] ?? [])
    }

    private func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    private static func isButtonLabel(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count <= maxButtonRowTextLength else { return false }
        return !trimmed.unicodeScalars.contains { (0x3000...0x9FFF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) }
    }

    static func normalize(_ string: String) -> String {
        string
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

import Foundation
import MCP

// `logic_system list_menus` / `click_menu` — the part of the menu-bar surface that does not touch AX.
//
// Everything here is pure: parameter parsing, title normalisation, the path walk over an abstract
// menu tree, the leaf safety verdict and the JSON the read emits. The Accessibility adapter
// (`AccessibilityChannel+MenuBar.swift`) only reads the live tree and hands it to these functions,
// so the decisions that make a press safe can be tested without Logic.
//
// NO LOCALIZED LITERAL IS COMPARED HERE. Every title a walk matches comes from the caller, and every
// title it is matched against comes from Logic's live AX tree. That is what lets the command work in
// every language Logic ships without a `LabelSet`: the caller read the titles with `list_menus`
// first, in whatever language Logic is running.

/// One AX title read, keeping "the element has no title" apart from "the title could not be read".
/// A separator publishes an empty or absent title; an unreadable one is a failed observation.
enum MenuTitleRead: Sendable, Equatable {
    case title(String)
    case absent
    case unreadable(String)
}

/// What sits below one menu item: the items of its submenu, nothing, or a read that failed.
enum MenuChildrenRead<Node> {
    case items([Node])
    case noSubmenu
    case unreadable(String)
}

/// The submenu of one node in a `list_menus` snapshot.
enum MenuSubmenuSnapshot: Sendable, Equatable {
    /// The item has no submenu.
    case leaf
    /// The submenu was read to the requested depth.
    case expanded([MenuBarNode])
    /// The item has a submenu, but `max_depth` stopped the walk above it.
    case notExpanded
    /// Whether the item has a submenu could not be read.
    case unreadable(String)
}

/// A read-only snapshot of one menu-bar item or menu item, as `list_menus` reports it.
struct MenuBarNode: Sendable, Equatable {
    var title: MenuTitleRead
    /// `nil` when `AXEnabled` could not be read — never folded into `false`.
    var enabled: Bool?
    var submenu: MenuSubmenuSnapshot
    var commandCharacter: String?
    var commandModifiers: Int?

    init(
        title: MenuTitleRead,
        enabled: Bool?,
        submenu: MenuSubmenuSnapshot = .leaf,
        commandCharacter: String? = nil,
        commandModifiers: Int? = nil
    ) {
        self.title = title
        self.enabled = enabled
        self.submenu = submenu
        self.commandCharacter = commandCharacter
        self.commandModifiers = commandModifiers
    }
}

enum MenuBarModel {
    /// `list_menus` depth: how many item levels below the menu bar are read. 1 lists each top-level
    /// menu's own items; every further level expands one more rank of submenus.
    static let defaultListDepth = 3
    static let maxListDepth = 5
    /// `click_menu` accepts at most this many titles, menu-bar title included.
    static let maxClickPathLength = 6
    /// The separator a single-string `path` is split on: `"Track > New Tracks..."`.
    static let pathSeparator = " > "
    /// The channel parameter carrying the path, JSON-encoded, because channel params are strings.
    static let channelPathKey = "path"

    /// `AXMenuItemCmdModifiers` bits (`kAXMenuItemModifier*`): Shift 1, Option 2, Control 4, and 8
    /// when the shortcut carries NO Command key. 0 therefore means plain Command.
    static let shiftModifierBit = 1
    static let optionModifierBit = 2
    static let controlModifierBit = 4
    static let noCommandModifierBit = 8
    /// The key equivalent of Logic's Quit item. Matched against `AXMenuItemCmdChar`, never against
    /// the item's localized title.
    static let quitKeyEquivalent = "Q"

    // MARK: - Normalisation

    /// The comparison form of a menu title: trimmed, U+00A0 read as a space, U+2026 read as three
    /// periods, case-folded. Logic's own titles carry `…` while a caller typing on a keyboard writes
    /// `...`; both name the same item.
    static func normalize(_ title: String) -> String {
        title
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{2026}", with: "...")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    // MARK: - Parameters

    enum PathParse: Sendable, Equatable {
        case path([String])
        case invalid(String)
    }

    /// `path` as an array of titles, or as one string separated by `" > "`.
    static func parsePath(_ value: Value?) -> PathParse {
        guard let value else {
            return .invalid(
                "requires 'path': the menu titles from the menu bar down, as an array of strings "
                    + "or as one string separated by \" > \""
            )
        }
        var raw: [String] = []
        if let array = value.arrayValue {
            for element in array {
                guard let segment = element.stringValue else {
                    return .invalid("'path' must contain only strings")
                }
                raw.append(segment)
            }
        } else if let string = value.stringValue {
            raw = string.components(separatedBy: pathSeparator)
        } else {
            return .invalid("'path' must be an array of strings or one string separated by \" > \"")
        }
        return validatePath(raw)
    }

    /// Non-empty, at most `maxClickPathLength` segments, and no segment that normalises to nothing.
    static func validatePath(_ raw: [String]) -> PathParse {
        let segments = raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !segments.isEmpty else {
            return .invalid("'path' is empty")
        }
        guard segments.count <= maxClickPathLength else {
            return .invalid(
                "'path' has \(segments.count) segments; at most \(maxClickPathLength) are accepted"
            )
        }
        guard segments.allSatisfy({ !normalize($0).isEmpty }) else {
            return .invalid("'path' contains an empty segment")
        }
        return .path(segments)
    }

    enum ChannelParams: Sendable, Equatable {
        case params([String: String])
        case invalid(String)
    }

    /// `list_menus` params, validated and flattened for the channel.
    static func listChannelParams(_ params: [String: Value]) -> ChannelParams {
        var channelParams: [String: String] = [:]
        if let raw = params["menu"] {
            guard let menu = raw.stringValue, !normalize(menu).isEmpty else {
                return .invalid("list_menus 'menu' must be a non-empty string naming one top-level menu")
            }
            channelParams["menu"] = menu
        }
        if params["max_depth"] != nil {
            guard let depth = intParamOrNil(params, "max_depth"), (1...maxListDepth).contains(depth) else {
                return .invalid("list_menus 'max_depth' must be an integer in 1...\(maxListDepth)")
            }
            channelParams["max_depth"] = String(depth)
        }
        return .params(channelParams)
    }

    /// `click_menu`'s `path`, validated and JSON-encoded for the channel.
    static func clickChannelParams(_ params: [String: Value]) -> ChannelParams {
        switch parsePath(params["path"]) {
        case .invalid(let why):
            return .invalid("click_menu \(why)")
        case .path(let path):
            guard let encoded = encodeChannelPath(path) else {
                return .invalid("click_menu could not encode 'path'")
            }
            return .params([channelPathKey: encoded])
        }
    }

    static func encodeChannelPath(_ path: [String]) -> String? {
        guard let data = try? JSONEncoder().encode(path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeChannelPath(_ raw: String?) -> [String]? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    // MARK: - Matching one level

    enum SegmentResolution: Sendable, Equatable {
        case matched(index: Int, title: String)
        case notFound(available: [String])
        case ambiguous(candidates: [String])
        case unreadable(stage: String)
    }

    /// Which sibling a caller's title names. Separators (empty or absent titles) are skipped and never
    /// listed. Two siblings that normalise alike are ambiguous, not "the first one". One sibling whose
    /// title could not be read makes the answer unreadable: that sibling could be the match, or the
    /// second match that makes it ambiguous.
    static func resolve(segment: String, among titles: [MenuTitleRead]) -> SegmentResolution {
        let wanted = normalize(segment)
        var available: [String] = []
        var matchIndices: [Int] = []
        var matchTitles: [String] = []
        var unreadableStage: String?
        for (index, read) in titles.enumerated() {
            switch read {
            case .title(let title):
                let normalized = normalize(title)
                if normalized.isEmpty { continue }
                available.append(title)
                if normalized == wanted {
                    matchIndices.append(index)
                    matchTitles.append(title)
                }
            case .absent:
                continue
            case .unreadable(let stage):
                if unreadableStage == nil { unreadableStage = stage }
            }
        }
        if matchIndices.count > 1 {
            return .ambiguous(candidates: matchTitles)
        }
        if let unreadableStage {
            return .unreadable(stage: unreadableStage)
        }
        guard !wanted.isEmpty, matchIndices.count == 1 else {
            return .notFound(available: available)
        }
        return .matched(index: matchIndices[0], title: matchTitles[0])
    }

    // MARK: - Walking a path

    enum WalkOutcome<Node> {
        /// The last segment resolved to exactly one item; `matched` is the live titles walked.
        case found(Node, matched: [String])
        /// The first segment named the menu-bar item at index 0, which is macOS's Apple menu.
        case appleMenu(matched: [String])
        case notFound(depth: Int, segment: String, available: [String], matched: [String])
        case ambiguous(depth: Int, segment: String, candidates: [String], matched: [String])
        /// A segment before the last named an item with no submenu to continue into.
        case notASubmenu(depth: Int, matched: [String])
        case unreadable(depth: Int, stage: String, matched: [String])
        case invalidPath(String)
    }

    /// Walk `path` from the menu bar down. Generic over the node so the same walk runs over live AX
    /// elements and over a test's value tree. `topLevel` is the menu bar's children in AX order.
    static func walk<Node>(
        path: [String],
        topLevel: [Node],
        title: (Node) -> MenuTitleRead,
        submenuItems: (Node) -> MenuChildrenRead<Node>
    ) -> WalkOutcome<Node> {
        if case .invalid(let why) = validatePath(path) {
            return .invalidPath(why)
        }
        var candidates = topLevel
        var matched: [String] = []
        for (depth, segment) in path.enumerated() {
            let titles = candidates.map { title($0) }
            switch resolve(segment: segment, among: titles) {
            case .notFound(let available):
                return .notFound(depth: depth, segment: segment, available: available, matched: matched)
            case .ambiguous(let found):
                return .ambiguous(depth: depth, segment: segment, candidates: found, matched: matched)
            case .unreadable(let stage):
                return .unreadable(depth: depth, stage: stage, matched: matched)
            case .matched(let index, let matchedTitle):
                matched.append(matchedTitle)
                if depth == 0, index == 0 {
                    return .appleMenu(matched: matched)
                }
                let node = candidates[index]
                if depth == path.count - 1 {
                    return .found(node, matched: matched)
                }
                switch submenuItems(node) {
                case .items(let children):
                    candidates = children
                case .noSubmenu:
                    return .notASubmenu(depth: depth, matched: matched)
                case .unreadable(let stage):
                    return .unreadable(depth: depth, stage: stage, matched: matched)
                }
            }
        }
        return .invalidPath("'path' is empty")
    }

    // MARK: - The item about to be pressed

    enum LeafVerdict: Sendable, Equatable {
        case pressable
        /// The item's shortcut is Command-Q (or its modifiers could not be read): Logic's Quit.
        case quitShortcut
        /// The shortcut attributes failed to read, so the Quit denylist cannot be applied.
        case shortcutUnreadable
        case hasSubmenu
        case submenuUnreadable
        case disabled
        case enabledUnreadable
    }

    /// Whether a shortcut is Logic's Quit. Identified by the key equivalent, not the title: the title
    /// is localized and the shortcut is not. Any Q shortcut that carries Command counts — Option-Q is
    /// "Quit and Keep Windows" — and so does a Q whose modifiers could not be read.
    static func isQuitShortcut(character: String?, modifiers: Int?) -> Bool {
        guard let character,
              character.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == quitKeyEquivalent
        else {
            return false
        }
        guard let modifiers else { return true }
        return modifiers & noCommandModifierBit == 0
    }

    /// Whether the resolved item may be pressed. The Quit denylist is checked first and regardless of
    /// the enabled state; an item that opens a submenu is not an action; and an item whose `AXEnabled`
    /// does not read `true` is refused, because pressing a disabled item reports success and does
    /// nothing (#606).
    static func leafVerdict(
        enabled: Bool?,
        hasSubmenu: Bool?,
        commandCharacter: String?,
        commandModifiers: Int?,
        shortcutReadable: Bool
    ) -> LeafVerdict {
        if isQuitShortcut(character: commandCharacter, modifiers: commandModifiers) {
            return .quitShortcut
        }
        guard shortcutReadable else { return .shortcutUnreadable }
        guard let hasSubmenu else { return .submenuUnreadable }
        if hasSubmenu { return .hasSubmenu }
        guard let enabled else { return .enabledUnreadable }
        return enabled ? .pressable : .disabled
    }

    // MARK: - list_menus payload

    /// The shortcut as `list_menus` reports it, or nil when the item has none.
    static func shortcutPayload(character: String?, modifiers: Int?) -> [String: Any]? {
        guard let character, !character.isEmpty else { return nil }
        var payload: [String: Any] = ["key": character]
        guard let modifiers else {
            payload["modifiers"] = NSNull()
            payload["raw_modifiers"] = NSNull()
            return payload
        }
        var names: [String] = []
        var glyphs = ""
        if modifiers & controlModifierBit != 0 {
            names.append("control")
            glyphs += "\u{2303}"
        }
        if modifiers & optionModifierBit != 0 {
            names.append("option")
            glyphs += "\u{2325}"
        }
        if modifiers & shiftModifierBit != 0 {
            names.append("shift")
            glyphs += "\u{21E7}"
        }
        if modifiers & noCommandModifierBit == 0 {
            names.append("command")
            glyphs += "\u{2318}"
        }
        payload["modifiers"] = names
        payload["raw_modifiers"] = modifiers
        payload["display"] = glyphs + character
        return payload
    }

    struct ListAccumulator {
        var entryCount = 0
        var truncated = false
        var unreadable: [[String: Any]] = []
    }

    /// The JSON entries for one level of the snapshot. Separators are skipped; an unreadable title is
    /// recorded under `unreadable` instead of being reported as an item nobody can name.
    static func itemPayloads(
        _ nodes: [MenuBarNode],
        parentPath: [String],
        accumulator: inout ListAccumulator
    ) -> [[String: Any]] {
        var entries: [[String: Any]] = []
        for node in nodes {
            let title: String
            switch node.title {
            case .title(let value):
                if normalize(value).isEmpty { continue }
                title = value
            case .absent:
                continue
            case .unreadable(let stage):
                accumulator.unreadable.append(["path": parentPath, "stage": stage])
                continue
            }
            let path = parentPath + [title]
            accumulator.entryCount += 1
            var entry: [String: Any] = ["title": title, "path": path]
            if let enabled = node.enabled {
                entry["enabled"] = enabled
            } else {
                entry["enabled"] = NSNull()
            }
            switch node.submenu {
            case .leaf:
                entry["has_submenu"] = false
            case .expanded(let children):
                entry["has_submenu"] = true
                entry["items"] = itemPayloads(children, parentPath: path, accumulator: &accumulator)
            case .notExpanded:
                entry["has_submenu"] = true
                entry["items_truncated_at_max_depth"] = true
                accumulator.truncated = true
            case .unreadable(let stage):
                entry["has_submenu"] = NSNull()
                accumulator.unreadable.append(["path": path, "stage": stage])
            }
            if let shortcut = shortcutPayload(character: node.commandCharacter, modifiers: node.commandModifiers) {
                entry["shortcut"] = shortcut
            }
            entries.append(entry)
        }
        return entries
    }

    /// One top-level menu's entry, carrying its menu-bar index. Index 0 is the Apple menu, which
    /// `click_menu` refuses, so it is listed as not clickable.
    static func menuPayload(
        index: Int,
        node: MenuBarNode,
        accumulator: inout ListAccumulator
    ) -> [String: Any]? {
        guard var entry = itemPayloads([node], parentPath: [], accumulator: &accumulator).first else {
            return nil
        }
        entry["menu_bar_index"] = index
        entry["clickable"] = index != 0
        return entry
    }

    /// The UI locale the menu-bar titles identify, through the product's one locale detector. Kept
    /// here, off the AX adapter, because it reads nothing: it classifies titles already read.
    static func uiLocale(menuTitles: [MenuTitleRead]) -> String? {
        var titles: [String] = []
        for read in menuTitles {
            if case .title(let title) = read { titles.append(title) }
        }
        return AXLogicProElements.logicUILocaleIdentifier(menuTitles: titles)
    }
}

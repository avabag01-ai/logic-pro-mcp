@preconcurrency import ApplicationServices
import Foundation
import MCP
import Testing
@testable import LogicProMCP

// `logic_system list_menus` / `click_menu`. Three layers, each tested on its own:
//   * registry and dispatcher wiring (confirmation, params, routing);
//   * the pure `MenuBarModel` (normalisation, path parsing, the walk, the leaf verdict, the payload);
//   * the Accessibility adapter over a fake AX menu bar, so the adapter's reads are exercised
//     end to end without Logic.

// MARK: - Fixtures

private struct FakeMenuItem {
    let title: String
    var enabled: Bool? = true
    var key: String?
    var modifiers: Int?
    var submenu: [FakeMenuItem] = []
}

/// A fake AX menu bar: the app's `AXMenuBar`, each top-level `AXMenuBarItem` carrying one `AXMenu`
/// child whose children are the items, and a submenu hung under an item the same way.
private final class FakeMenuBarFixture: @unchecked Sendable {
    let builder = FakeAXRuntimeBuilder()
    let app: AXUIElement
    let menuBar: AXUIElement
    private var nextID = 6000
    private var topLevel: [AXUIElement] = []
    private(set) var elementsByTitle: [String: AXUIElement] = [:]

    init() {
        app = builder.element(5990)
        menuBar = builder.element(5991)
        builder.setAttribute(app, kAXMenuBarAttribute as String, menuBar)
    }

    private func newElement() -> AXUIElement {
        nextID += 1
        return builder.element(nextID)
    }

    func addMenu(_ title: String, items: [FakeMenuItem]) {
        let barItem = newElement()
        builder.setAttribute(barItem, kAXTitleAttribute as String, title)
        builder.setAttribute(barItem, kAXRoleAttribute as String, "AXMenuBarItem")
        builder.setAttribute(barItem, kAXEnabledAttribute as String, true)
        topLevel.append(barItem)
        builder.setChildren(menuBar, topLevel)
        elementsByTitle[title] = barItem
        attachMenu(to: barItem, items: items)
    }

    private func attachMenu(to parent: AXUIElement, items: [FakeMenuItem]) {
        let menu = newElement()
        builder.setAttribute(menu, kAXRoleAttribute as String, kAXMenuRole as String)
        var elements: [AXUIElement] = []
        for item in items {
            let element = newElement()
            builder.setAttribute(element, kAXRoleAttribute as String, kAXMenuItemRole as String)
            builder.setAttribute(element, kAXTitleAttribute as String, item.title)
            if let enabled = item.enabled {
                builder.setAttribute(element, kAXEnabledAttribute as String, enabled)
            }
            if let key = item.key {
                builder.setAttribute(element, "AXMenuItemCmdChar", key)
            }
            if let modifiers = item.modifiers {
                builder.setAttribute(element, "AXMenuItemCmdModifiers", modifiers)
            }
            if !item.submenu.isEmpty {
                attachMenu(to: element, items: item.submenu)
            }
            if !item.title.isEmpty {
                elementsByTitle[item.title] = element
            }
            elements.append(element)
        }
        builder.setChildren(menu, elements)
        builder.setChildren(parent, [menu])
    }

    var runtime: AXLogicProElements.Runtime {
        builder.makeLogicRuntime(appElement: app)
    }

    var pressedTitles: [String] {
        let pressedIDs = builder.actionCalls
            .filter { $0.action == (kAXPressAction as String) }
            .map { $0.elementID }
        return pressedIDs.compactMap { id in
            elementsByTitle.first { builder.elementID($0.value) == id }?.key
        }
    }

    /// An English Logic menu bar: Apple, Logic Pro, File, Edit, Track.
    static func english() -> FakeMenuBarFixture {
        let fixture = FakeMenuBarFixture()
        fixture.addMenu("Apple", items: [FakeMenuItem(title: "About This Mac")])
        fixture.addMenu("Logic Pro", items: [
            FakeMenuItem(title: "Settings", submenu: [FakeMenuItem(title: "General\u{2026}")]),
            FakeMenuItem(title: ""),
            FakeMenuItem(title: "Quit Logic Pro", key: "Q", modifiers: 0),
        ])
        fixture.addMenu("File", items: [
            FakeMenuItem(title: "Save", key: "S", modifiers: 0),
            FakeMenuItem(title: "Revert", enabled: false),
            FakeMenuItem(title: "Mystery", enabled: nil),
        ])
        fixture.addMenu("Edit", items: [
            FakeMenuItem(title: "Undo", key: "Z", modifiers: 0),
            FakeMenuItem(title: "Twin"),
            FakeMenuItem(title: "twin"),
        ])
        fixture.addMenu("Track", items: [
            FakeMenuItem(title: "New Tracks\u{2026}", key: "N", modifiers: 2),
            FakeMenuItem(title: ""),
            FakeMenuItem(title: "Other", submenu: [
                FakeMenuItem(title: "Deep", submenu: [FakeMenuItem(title: "Deeper")]),
            ]),
        ])
        return fixture
    }
}

private func menuJSON(_ result: ChannelResult) throws -> [String: Any] {
    try #require(sharedJSONObject(result.message), Comment(rawValue: result.message))
}

private func requireBool(_ value: Any?) throws -> Bool {
    try #require(value as? Bool)
}

/// A pure value tree walked by `MenuBarModel.walk`, the same walk the AX adapter runs.
private func walkSnapshot(_ path: [String], _ menus: [MenuBarNode]) -> MenuBarModel.WalkOutcome<MenuBarNode> {
    MenuBarModel.walk(
        path: path,
        topLevel: menus,
        title: { $0.title },
        submenuItems: { (item: MenuBarNode) -> MenuChildrenRead<MenuBarNode> in
            switch item.submenu {
            case .leaf:
                return .noSubmenu
            case .expanded(let children):
                return .items(children)
            case .notExpanded:
                return .unreadable("not expanded")
            case .unreadable(let stage):
                return .unreadable(stage)
            }
        }
    )
}

private func node(_ title: String, _ children: [MenuBarNode]? = nil, enabled: Bool? = true) -> MenuBarNode {
    MenuBarNode(
        title: .title(title),
        enabled: enabled,
        submenu: children.map { MenuSubmenuSnapshot.expanded($0) } ?? MenuSubmenuSnapshot.leaf
    )
}

private let koreanSnapshot: [MenuBarNode] = [
    node("Apple", [node("이 Mac에 관하여")]),
    node("Logic Pro", [node("종료")]),
    node("파일", [node("저장")]),
    node("편집", [node("실행 취소")]),
    node("트랙", [
        node("새로운 트랙\u{2026}"),
        MenuBarNode(title: .title(""), enabled: false),
        node("기타", [node("하위\u{00A0}항목")]),
    ]),
]

@Suite("logic_system list_menus / click_menu")
struct MenuBarCommandsTests {
    // MARK: - Registry and routing

    @Test func registryDeclaresBothCommandsWithTheirParams() throws {
        let list = try #require(OperationRegistry.spec(tool: "logic_system", command: "list_menus"))
        #expect(list.id == .systemListMenus)
        #expect(list.mutability == .readOnly)
        #expect(list.confirmation == ConfirmationPolicy.none)
        #expect(list.verification == VerificationPolicy.none)
        #expect(list.deadline == .medium)
        #expect(list.allowedParams == ["max_depth", "menu"])

        let click = try #require(OperationRegistry.spec(tool: "logic_system", command: "click_menu"))
        #expect(click.id == .systemClickMenu)
        #expect(click.mutability == .mutating)
        #expect(click.confirmation == .l2)
        #expect(DestructivePolicy.level(of: click.confirmation) == .l2)
        #expect(click.target == TargetPolicy.none)
        #expect(click.indexBinding == nil)
        #expect(click.verification == VerificationPolicy.none)
        #expect(click.allowedParams == ["confirmed", "path"])

        #expect(SystemDispatcher.handledCommands.isSuperset(of: ["list_menus", "click_menu"]))
        #expect(OperationHandlerRegistry.handler(for: .systemListMenus) != nil)
        #expect(OperationHandlerRegistry.handler(for: .systemClickMenu) != nil)
        #expect(ChannelRouter.routingTable["menu.list"] == [.accessibility])
        #expect(ChannelRouter.routingTable["menu.click"] == [.accessibility])
        #expect(SemanticOracleTable.byOperationID[.systemListMenus] != nil)
        #expect(SemanticOracleTable.structurallyUnverifiedMutatingOperationIDs[.systemClickMenu] != nil)
    }

    @Test func strictParamsRejectUnknownKeysForBothCommands() throws {
        for command in ["list_menus", "click_menu"] {
            let result = try #require(LogicProServer.strictParamValidationResult(
                tool: "logic_system",
                command: command,
                params: ["__unknown": .bool(true)]
            ))
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(body["error"] as? String == "invalid_params")
        }
    }

    // MARK: - Dispatcher: click_menu confirmation and routing

    private static func dispatch(
        _ command: String,
        _ params: [String: Value],
        channel: MockChannel
    ) async -> CallTool.Result {
        let router = ChannelRouter()
        await router.register(channel)
        return await SystemDispatcher.handle(
            command: command,
            params: params,
            router: router,
            cache: StateCache()
        )
    }

    @Test func clickMenuRefusesWithoutConfirmedTrueAndRoutesNothing() async throws {
        let refusals: [[String: Value]] = [
            ["path": .array([.string("Track"), .string("New Tracks...")])],
            ["path": .array([.string("Track"), .string("New Tracks...")]), "confirmed": .bool(false)],
        ]
        for params in refusals {
            let channel = MockChannel(id: .accessibility)
            let result = await Self.dispatch("click_menu", params, channel: channel)
            let isError = try #require(result.isError)
            #expect(isError)
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(body["state"] as? String == "C")
            #expect(body["error"] as? String == "invalid_params")
            #expect(body["hint"] as? String == SystemDispatcher.clickMenuConfirmationHint)
            #expect(await channel.executedOps.isEmpty)
        }

        // A string "true" is not a literal boolean, exactly as for clear_traces.
        let channel = MockChannel(id: .accessibility)
        let stringly = await Self.dispatch(
            "click_menu",
            ["path": .string("Track > New Tracks..."), "confirmed": .string("true")],
            channel: channel
        )
        let body = try #require(sharedJSONObject(sharedToolText(stringly)))
        #expect(body["error"] as? String == "invalid_params")
        #expect((body["hint"] as? String)?.contains("literal boolean") == Optional(true))
        #expect(await channel.executedOps.isEmpty)
    }

    @Test func clickMenuRoutesTheParsedPathOnce() async throws {
        let stateB = HonestContract.encodeStateB(reason: .readbackUnavailable, extras: ["path_matched": ["Track"]])
        let inputs: [(Value, [String])] = [
            (.array([.string("트랙"), .string("새로운 트랙...")]), ["트랙", "새로운 트랙..."]),
            (.string("트랙 > 새로운 트랙..."), ["트랙", "새로운 트랙..."]),
            (.string("  File  >  Save  "), ["File", "Save"]),
        ]
        for (raw, expected) in inputs {
            let channel = MockChannel(id: .accessibility, successEnvelope: stateB)
            let result = await Self.dispatch(
                "click_menu",
                ["path": raw, "confirmed": .bool(true)],
                channel: channel
            )
            let isError = try #require(result.isError)
            #expect(!isError)
            let ops = await channel.executedOps
            #expect(ops.count == 1)
            #expect(ops.first?.0 == "menu.click")
            let decoded = MenuBarModel.decodeChannelPath(ops.first?.1[MenuBarModel.channelPathKey])
            #expect(decoded == expected)
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(body["state"] as? String == "B")
        }
    }

    @Test func clickMenuRefusesAMalformedPathBeforeRouting() async throws {
        let tooLong = Value.array((1...7).map { Value.string("Level \($0)") })
        let malformed: [Value?] = [
            nil,
            .array([]),
            .string("   "),
            .array([.string("Track"), .int(3)]),
            .array([.string("Track"), .string("  ")]),
            .int(1),
            tooLong,
        ]
        for raw in malformed {
            var params: [String: Value] = ["confirmed": .bool(true)]
            if let raw { params["path"] = raw }
            let channel = MockChannel(id: .accessibility)
            let result = await Self.dispatch("click_menu", params, channel: channel)
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(body["error"] as? String == "invalid_params", "\(String(describing: raw))")
            #expect(await channel.executedOps.isEmpty)
        }
    }

    @Test func listMenusValidatesItsParamsAndRoutesARead() async throws {
        for bad: [String: Value] in [
            ["max_depth": .int(0)], ["max_depth": .int(6)], ["max_depth": .string("deep")],
            ["menu": .int(1)], ["menu": .string("  ")],
        ] {
            let channel = MockChannel(id: .accessibility)
            let result = await Self.dispatch("list_menus", bad, channel: channel)
            let body = try #require(sharedJSONObject(sharedToolText(result)))
            #expect(body["error"] as? String == "invalid_params")
            #expect(await channel.executedOps.isEmpty)
        }

        let channel = MockChannel(id: .accessibility, successEnvelope: HonestContract.encodeStateA())
        let result = await Self.dispatch(
            "list_menus",
            ["menu": .string("트랙"), "max_depth": .int(2)],
            channel: channel
        )
        let isError = try #require(result.isError)
        #expect(!isError)
        let ops = await channel.executedOps
        #expect(ops.count == 1)
        #expect(ops.first?.0 == "menu.list")
        #expect(ops.first?.1 == ["menu": "트랙", "max_depth": "2"])
    }

    // MARK: - MenuBarModel: normalisation and matching

    @Test func normalisationFoldsEllipsisNonBreakingSpaceAndCase() {
        #expect(MenuBarModel.normalize("New Tracks\u{2026}") == MenuBarModel.normalize("new tracks..."))
        #expect(MenuBarModel.normalize("새로운 트랙\u{2026}") == MenuBarModel.normalize("  새로운 트랙...  "))
        #expect(MenuBarModel.normalize("Show\u{00A0}Mixer") == MenuBarModel.normalize("show mixer"))
        #expect(MenuBarModel.normalize("\u{00A0}Save\u{00A0}") == "save")
        #expect(MenuBarModel.normalize("Save") != MenuBarModel.normalize("Save As"))
        #expect(MenuBarModel.normalize("   ").isEmpty)
    }

    @Test func resolveSkipsSeparatorsAndRefusesAmbiguityAndUnreadableSiblings() {
        let titles: [MenuTitleRead] = [.title("Save"), .title(""), .absent, .title("Save As\u{2026}")]
        #expect(MenuBarModel.resolve(segment: "save as...", among: titles)
            == .matched(index: 3, title: "Save As\u{2026}"))
        #expect(MenuBarModel.resolve(segment: "Open", among: titles)
            == .notFound(available: ["Save", "Save As\u{2026}"]))
        #expect(MenuBarModel.resolve(segment: "twin", among: [.title("Twin"), .title("twin ")])
            == .ambiguous(candidates: ["Twin", "twin "]))
        #expect(MenuBarModel.resolve(segment: "Save", among: [.title("Save"), .unreadable("AXTitle -25204")])
            == .unreadable(stage: "AXTitle -25204"))
    }

    // MARK: - MenuBarModel: path parsing

    @Test func pathParsingAcceptsAnArrayOrOneSeparatedString() {
        #expect(MenuBarModel.parsePath(.array([.string("트랙"), .string("새로운 트랙...")]))
            == .path(["트랙", "새로운 트랙..."]))
        #expect(MenuBarModel.parsePath(.string("트랙 > 새로운 트랙..."))
            == .path(["트랙", "새로운 트랙..."]))
        #expect(MenuBarModel.parsePath(.string("Mix>Bounce")) == .path(["Mix>Bounce"]))
        #expect(MenuBarModel.parsePath(Value.array((1...6).map { Value.string("L\($0)") }))
            == .path((1...6).map { "L\($0)" }))
        for bad: Value? in [nil, .array([]), Value.array((1...7).map { Value.string("L\($0)") }), .bool(true),
                            .array([.string("A"), .null]), .string("A >  > B")] {
            if case .path = MenuBarModel.parsePath(bad) {
                Issue.record("accepted a malformed path: \(String(describing: bad))")
            }
        }
    }

    @Test func channelPathRoundTripsThroughJSON() {
        let path = ["트랙", "새로운 트랙\u{2026}", "a \"quoted\" > title"]
        let encoded = MenuBarModel.encodeChannelPath(path)
        #expect(MenuBarModel.decodeChannelPath(encoded) == path)
        #expect(MenuBarModel.decodeChannelPath("not json") == nil)
        #expect(MenuBarModel.decodeChannelPath(nil) == nil)
    }

    // MARK: - MenuBarModel: the walk over a value tree

    @Test func walkFindsTheLeafByLiveTitlesAndReportsThem() {
        switch walkSnapshot(["트랙", "새로운 트랙..."], koreanSnapshot) {
        case .found(let found, let matched):
            #expect(found.title == .title("새로운 트랙\u{2026}"))
            #expect(matched == ["트랙", "새로운 트랙\u{2026}"])
        default:
            Issue.record("the leaf was not found")
        }
        switch walkSnapshot(["트랙", "기타", "하위 항목"], koreanSnapshot) {
        case .found(_, let matched):
            #expect(matched == ["트랙", "기타", "하위\u{00A0}항목"])
        default:
            Issue.record("the nested leaf was not found")
        }
    }

    @Test func walkRefusesAMissingSegmentWithTheSiblingTitles() {
        switch walkSnapshot(["트랙", "없는 항목"], koreanSnapshot) {
        case .notFound(let depth, let segment, let available, let matched):
            #expect(depth == 1)
            #expect(segment == "없는 항목")
            #expect(available == ["새로운 트랙\u{2026}", "기타"])
            #expect(matched == ["트랙"])
        default:
            Issue.record("a missing segment was not refused as notFound")
        }
    }

    @Test func walkRefusesTheAppleMenuAmbiguityAndALeafInTheMiddle() {
        if case .appleMenu = walkSnapshot(["apple", "이 Mac에 관하여"], koreanSnapshot) {} else {
            Issue.record("the Apple menu (menu-bar index 0) was not refused")
        }
        let twins = [node("Apple"), node("Edit", [node("Twin"), node("twin")])]
        if case .ambiguous(_, _, let candidates, _) = walkSnapshot(["Edit", "TWIN"], twins) {
            #expect(candidates == ["Twin", "twin"])
        } else {
            Issue.record("two matching siblings were not refused as ambiguous")
        }
        if case .notASubmenu(let depth, _) = walkSnapshot(["파일", "저장", "더"], koreanSnapshot) {
            #expect(depth == 1)
        } else {
            Issue.record("a path continuing below a leaf was not refused")
        }
        if case .invalidPath = walkSnapshot([], koreanSnapshot) {} else {
            Issue.record("an empty path was not refused")
        }
        if case .invalidPath = walkSnapshot((1...7).map { "L\($0)" }, koreanSnapshot) {} else {
            Issue.record("a seven-segment path was not refused")
        }
    }

    // MARK: - MenuBarModel: the leaf verdict and the Quit denylist

    @Test func quitShortcutIsIdentifiedByKeyEquivalentNotTitle() {
        #expect(MenuBarModel.isQuitShortcut(character: "Q", modifiers: 0))
        #expect(MenuBarModel.isQuitShortcut(character: "q", modifiers: 0))
        #expect(MenuBarModel.isQuitShortcut(character: "Q", modifiers: 2))   // Option-Command-Q
        #expect(MenuBarModel.isQuitShortcut(character: "Q", modifiers: nil))  // unreadable: fail closed
        #expect(!MenuBarModel.isQuitShortcut(character: "Q", modifiers: 8))  // no Command key
        #expect(!MenuBarModel.isQuitShortcut(character: "W", modifiers: 0))
        #expect(!MenuBarModel.isQuitShortcut(character: nil, modifiers: 0))
    }

    @Test func leafVerdictChecksQuitSubmenuAndEnabledInThatOrder() {
        func verdict(
            enabled: Bool?, hasSubmenu: Bool?, key: String? = nil, modifiers: Int? = nil,
            readable: Bool = true
        ) -> MenuBarModel.LeafVerdict {
            MenuBarModel.leafVerdict(
                enabled: enabled, hasSubmenu: hasSubmenu,
                commandCharacter: key, commandModifiers: modifiers, shortcutReadable: readable
            )
        }
        #expect(verdict(enabled: true, hasSubmenu: false) == .pressable)
        #expect(verdict(enabled: false, hasSubmenu: false, key: "Q", modifiers: 0) == .quitShortcut)
        #expect(verdict(enabled: true, hasSubmenu: false, readable: false) == .shortcutUnreadable)
        #expect(verdict(enabled: true, hasSubmenu: true) == .hasSubmenu)
        #expect(verdict(enabled: true, hasSubmenu: nil) == .submenuUnreadable)
        #expect(verdict(enabled: false, hasSubmenu: false) == .disabled)
        #expect(verdict(enabled: nil, hasSubmenu: false) == .enabledUnreadable)
    }

    // MARK: - MenuBarModel: the list payload

    @Test func shortcutPayloadDecodesTheModifierMask() throws {
        let optionCommand = try #require(MenuBarModel.shortcutPayload(character: "N", modifiers: 2))
        #expect(optionCommand["modifiers"] as? [String] == ["option", "command"])
        #expect(optionCommand["display"] as? String == "\u{2325}\u{2318}N")
        let shiftCommand = try #require(MenuBarModel.shortcutPayload(character: "Z", modifiers: 1))
        #expect(shiftCommand["display"] as? String == "\u{21E7}\u{2318}Z")
        let noCommand = try #require(MenuBarModel.shortcutPayload(character: "K", modifiers: 8))
        #expect(noCommand["modifiers"] as? [String] == [])
        #expect(MenuBarModel.shortcutPayload(character: nil, modifiers: 0) == nil)
        #expect(MenuBarModel.shortcutPayload(character: "", modifiers: 0) == nil)
    }

    @Test func itemPayloadsSkipSeparatorsAndRecordWhatDidNotRead() throws {
        var accumulator = MenuBarModel.ListAccumulator()
        let nodes: [MenuBarNode] = [
            node("Save"),
            MenuBarNode(title: .title(""), enabled: false),
            MenuBarNode(title: .absent, enabled: nil),
            MenuBarNode(title: .unreadable("AXTitle -25204"), enabled: nil),
            MenuBarNode(title: .title("Recent"), enabled: true, submenu: .notExpanded),
            MenuBarNode(title: .title("Odd"), enabled: nil, submenu: .unreadable("AXChildren -25204")),
        ]
        let entries = MenuBarModel.itemPayloads(nodes, parentPath: ["File"], accumulator: &accumulator)
        #expect(entries.map { $0["title"] as? String } == ["Save", "Recent", "Odd"])
        #expect(entries.first?["path"] as? [String] == ["File", "Save"])
        #expect(entries.last?["enabled"] is NSNull)
        #expect(entries.last?["has_submenu"] is NSNull)
        #expect(accumulator.entryCount == 3)
        #expect(accumulator.truncated)
        #expect(accumulator.unreadable.count == 2)
    }

    // MARK: - Accessibility adapter over a fake menu bar

    @Test func listMenusReadsTheWholeBarWithoutPressingAnything() throws {
        let fixture = FakeMenuBarFixture.english()
        let result = AccessibilityChannel.defaultListMenus(params: [:], runtime: fixture.runtime)
        #expect(result.isSuccess)
        let body = try menuJSON(result)
        #expect(body["state"] as? String == "A")
        #expect(body["ui_locale"] as? String == "en-US")
        let stale = try requireBool(body["titles_may_be_stale_until_opened"])
        #expect(stale)
        let complete = try requireBool(body["complete"])
        #expect(complete)
        #expect(body["max_depth"] as? Int == 3)
        let menus = try #require(body["menus"] as? [[String: Any]])
        #expect(menus.map { $0["title"] as? String } == ["Apple", "Logic Pro", "File", "Edit", "Track"])
        let appleClickable = try requireBool(menus[0]["clickable"])
        #expect(!appleClickable)
        let track = menus[4]
        #expect(track["menu_bar_index"] as? Int == 4)
        let trackItems = try #require(track["items"] as? [[String: Any]])
        // The separator is skipped.
        #expect(trackItems.map { $0["title"] as? String } == ["New Tracks\u{2026}", "Other"])
        let shortcut = try #require(trackItems[0]["shortcut"] as? [String: Any])
        #expect(shortcut["display"] as? String == "\u{2325}\u{2318}N")
        let file = try #require(menus[2]["items"] as? [[String: Any]])
        let revertEnabled = try requireBool(file[1]["enabled"])
        #expect(!revertEnabled)
        #expect(file[2]["enabled"] is NSNull)
        #expect(fixture.pressedTitles.isEmpty)
    }

    @Test func listMenusHonoursTheMenuFilterAndTheDepthLimit() throws {
        let fixture = FakeMenuBarFixture.english()
        let result = AccessibilityChannel.defaultListMenus(
            params: ["menu": "track", "max_depth": "1"],
            runtime: fixture.runtime
        )
        let body = try menuJSON(result)
        let menus = try #require(body["menus"] as? [[String: Any]])
        #expect(menus.count == 1)
        #expect(menus.first?["menu_bar_index"] as? Int == 4)
        let truncated = try requireBool(body["truncated_at_max_depth"])
        #expect(truncated)
        let items = try #require(menus.first?["items"] as? [[String: Any]])
        let otherTruncated = try requireBool(items[1]["items_truncated_at_max_depth"])
        #expect(otherTruncated)
        #expect(items[1]["items"] == nil)

        let missing = AccessibilityChannel.defaultListMenus(params: ["menu": "Window"], runtime: fixture.runtime)
        #expect(!missing.isSuccess)
        let refusal = try menuJSON(missing)
        #expect(refusal["error"] as? String == "element_not_found")
        #expect(refusal["available_titles"] as? [String] == ["Apple", "Logic Pro", "File", "Edit", "Track"])
    }

    @Test func clickMenuPressesTheResolvedLeafAndAnswersStateB() throws {
        let fixture = FakeMenuBarFixture.english()
        let path = try #require(MenuBarModel.encodeChannelPath(["track", "new tracks..."]))
        let result = AccessibilityChannel.defaultClickMenu(
            params: [MenuBarModel.channelPathKey: path],
            runtime: fixture.runtime
        )
        #expect(result.isSuccess)
        let body = try menuJSON(result)
        #expect(body["state"] as? String == "B")
        #expect(body["reason"] as? String == "readback_unavailable")
        #expect(body["path_matched"] as? [String] == ["Track", "New Tracks\u{2026}"])
        #expect(body["ui_locale"] as? String == "en-US")
        #expect(fixture.pressedTitles == ["New Tracks\u{2026}"])
    }

    @Test func clickMenuRefusesEveryUnsafeTargetAndPressesNothing() throws {
        let cases: [([String], String)] = [
            (["Track", "Missing"], "element_not_found"),
            (["Edit", "twin"], "ambiguous_target_name"),
            (["File", "Revert"], "unsupported_state"),
            (["File", "Mystery"], "readback_unavailable"),
            (["Track", "Other"], "invalid_params"),
            (["Apple", "About This Mac"], "not_supported"),
            (["Logic Pro", "Quit Logic Pro"], "not_supported"),
            (["File", "Save", "Deeper"], "element_not_found"),
        ]
        for (path, expectedError) in cases {
            let fixture = FakeMenuBarFixture.english()
            let encoded = try #require(MenuBarModel.encodeChannelPath(path))
            let result = AccessibilityChannel.defaultClickMenu(
                params: [MenuBarModel.channelPathKey: encoded],
                runtime: fixture.runtime
            )
            #expect(!result.isSuccess, "\(path)")
            let body = try menuJSON(result)
            #expect(body["state"] as? String == "C", "\(path)")
            #expect(body["error"] as? String == expectedError, "\(path): \(result.message)")
            let writeAttempted = try requireBool(body["write_attempted"])
            #expect(!writeAttempted, "\(path)")
            #expect(fixture.pressedTitles.isEmpty, "\(path) pressed \(fixture.pressedTitles)")
        }

        let fixture = FakeMenuBarFixture.english()
        let encoded = try #require(MenuBarModel.encodeChannelPath(["Track", "Missing"]))
        let body = try menuJSON(AccessibilityChannel.defaultClickMenu(
            params: [MenuBarModel.channelPathKey: encoded],
            runtime: fixture.runtime
        ))
        #expect(body["available_titles"] as? [String] == ["New Tracks\u{2026}", "Other"])
        let quitFixture = FakeMenuBarFixture.english()
        let quit = try #require(MenuBarModel.encodeChannelPath(["Logic Pro", "Quit Logic Pro"]))
        let quitBody = try menuJSON(AccessibilityChannel.defaultClickMenu(
            params: [MenuBarModel.channelPathKey: quit],
            runtime: quitFixture.runtime
        ))
        #expect((quitBody["hint"] as? String)?.contains("logic_project quit") == Optional(true))
    }
}

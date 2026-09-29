@preconcurrency import ApplicationServices
import Foundation

// `logic_system list_menus` / `click_menu` — the Accessibility adapter.
//
// This file only READS the live menu bar and PRESSES one item. Every decision — which sibling a
// caller's title names, whether a path is ambiguous, whether the resolved item may be pressed, what
// the read reports — is made by `MenuBarModel`, which is pure and tested without Logic.
//
// The titles are read WITHOUT opening any menu. That is deliberate and it has a cost the response
// states: Logic rewrites some titles only when their menu opens (#864 measured `Undo` becoming
// `Undo Insert Plug-in in Channel Strip` once the Edit menu was open), so a title read here can be
// the unopened form. Opening every menu to refresh them would mean pressing every menu-bar item and
// escaping out of each, which is a UI drive, not a read. `list_menus` says so in
// `titles_may_be_stale_until_opened`, and `click_menu` matches the same unopened titles it lists, so
// a path copied from `list_menus` resolves.

extension AccessibilityChannel {
    // MARK: - list_menus

    static func defaultListMenus(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production
    ) -> ChannelResult {
        let operation = OperationID.systemListMenus.rawValue
        let depthLimit: Int
        if let rawDepth = params["max_depth"] {
            guard let parsed = Int(rawDepth), (1...MenuBarModel.maxListDepth).contains(parsed) else {
                let hint = "list_menus 'max_depth' must be an integer in 1...\(MenuBarModel.maxListDepth)"
                return .error(HonestContract.encodeStateC(
                    error: .invalidParams,
                    hint: hint,
                    extras: ["operation": operation]
                ))
            }
            depthLimit = parsed
        } else {
            depthLimit = MenuBarModel.defaultListDepth
        }

        let topLevel: [AXUIElement]
        switch readMenuBarItems(runtime: runtime) {
        case .items(let items):
            topLevel = items
        case .unavailable(let stage, let status):
            return .error(menuBarUnreadableResult(operation: operation, stage: stage, status: status))
        }

        let ax = runtime.ax
        let topLevelTitles = topLevel.map { menuTitleRead($0, runtime: ax) }
        var selected: [(index: Int, element: AXUIElement)] = topLevel.enumerated().map {
            (index: $0.offset, element: $0.element)
        }
        let menuFilter = params["menu"]
        if let menuFilter {
            switch MenuBarModel.resolve(segment: menuFilter, among: topLevelTitles) {
            case .matched(let index, _):
                selected = [(index: index, element: topLevel[index])]
            case .notFound(let available):
                let hint = "No top-level menu matches '\(menuFilter)'. Retry with one of the titles "
                    + "in available_titles."
                return .error(HonestContract.encodeStateC(
                    error: .elementNotFound,
                    hint: hint,
                    extras: ["operation": operation, "menu": menuFilter, "available_titles": available]
                ))
            case .ambiguous(let candidates):
                let hint = "More than one top-level menu matches '\(menuFilter)'."
                return .error(HonestContract.encodeStateC(
                    error: .ambiguousTargetName,
                    hint: hint,
                    extras: ["operation": operation, "menu": menuFilter, "matching_titles": candidates]
                ))
            case .unreadable(let stage):
                return .error(menuBarUnreadableResult(operation: operation, stage: stage, status: "unreadable"))
            }
        }

        var accumulator = MenuBarModel.ListAccumulator()
        var menus: [[String: Any]] = []
        for entry in selected {
            let node = menuSnapshot(entry.element, depthRemaining: depthLimit, runtime: ax)
            if let payload = MenuBarModel.menuPayload(index: entry.index, node: node, accumulator: &accumulator) {
                menus.append(payload)
            }
        }

        var extras: [String: Any] = [
            "operation": operation,
            "source": "ax_menu_bar",
            "menus": menus,
            "max_depth": depthLimit,
            "entry_count": accumulator.entryCount,
            "truncated_at_max_depth": accumulator.truncated,
            "complete": accumulator.unreadable.isEmpty,
            "titles_may_be_stale_until_opened": true,
        ]
        if let locale = MenuBarModel.uiLocale(menuTitles: topLevelTitles) {
            extras["ui_locale"] = locale
        } else {
            extras["ui_locale"] = NSNull()
        }
        if let menuFilter {
            extras["menu_filter"] = menuFilter
        }
        guard accumulator.unreadable.isEmpty else {
            // Part of the tree did not read. What did read is still reported, but not as a complete,
            // verified reading of the menu bar.
            extras["unreadable"] = accumulator.unreadable
            return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: extras))
        }
        return .success(HonestContract.encodeStateA(extras: extras))
    }

    /// Snapshot one menu-bar item or menu item, expanding its submenu while depth remains.
    private static func menuSnapshot(
        _ element: AXUIElement,
        depthRemaining: Int,
        runtime: AXHelpers.Runtime
    ) -> MenuBarNode {
        let title = menuTitleRead(element, runtime: runtime)
        let enabled = menuEnabledRead(element, runtime: runtime)
        let shortcut = menuShortcutRead(element, runtime: runtime)
        let submenu: MenuSubmenuSnapshot
        switch menuSubmenuItemsRead(of: element, runtime: runtime) {
        case .noSubmenu:
            submenu = .leaf
        case .unreadable(let stage):
            submenu = .unreadable(stage)
        case .items(let children):
            if depthRemaining <= 0 {
                submenu = .notExpanded
            } else {
                var expanded: [MenuBarNode] = []
                for child in children {
                    expanded.append(menuSnapshot(child, depthRemaining: depthRemaining - 1, runtime: runtime))
                }
                submenu = .expanded(expanded)
            }
        }
        return MenuBarNode(
            title: title,
            enabled: enabled,
            submenu: submenu,
            commandCharacter: shortcut.character,
            commandModifiers: shortcut.modifiers
        )
    }

    // MARK: - click_menu

    static func defaultClickMenu(
        params: [String: String],
        runtime: AXLogicProElements.Runtime = .production
    ) -> ChannelResult {
        let operation = OperationID.systemClickMenu.rawValue
        guard let path = MenuBarModel.decodeChannelPath(params[MenuBarModel.channelPathKey]) else {
            return .error(HonestContract.encodeStateC(
                error: .invalidParams,
                hint: "click_menu reached the Accessibility channel without a decodable 'path'",
                extras: ["operation": operation, "write_attempted": false]
            ))
        }

        let topLevel: [AXUIElement]
        switch readMenuBarItems(runtime: runtime) {
        case .items(let items):
            topLevel = items
        case .unavailable(let stage, let status):
            return .error(menuBarUnreadableResult(operation: operation, stage: stage, status: status))
        }

        let ax = runtime.ax
        let topLevelTitles = topLevel.map { menuTitleRead($0, runtime: ax) }
        let uiLocale: Any
        if let locale = MenuBarModel.uiLocale(menuTitles: topLevelTitles) {
            uiLocale = locale
        } else {
            uiLocale = NSNull()
        }
        let outcome = MenuBarModel.walk(
            path: path,
            topLevel: topLevel,
            title: { menuTitleRead($0, runtime: ax) },
            submenuItems: { menuSubmenuItemsRead(of: $0, runtime: ax) }
        )

        var refusal: [String: Any] = [
            "operation": operation,
            "path_requested": path,
            "ui_locale": uiLocale,
            "write_attempted": false,
        ]
        let element: AXUIElement
        let matched: [String]
        switch outcome {
        case .found(let found, let titles):
            element = found
            matched = titles
        case .invalidPath(let why):
            return .error(HonestContract.encodeStateC(error: .invalidParams, hint: "click_menu \(why)", extras: refusal))
        case .appleMenu(let titles):
            refusal["path_matched"] = titles
            let hint = "The first menu-bar item is macOS's Apple menu, not Logic's; click_menu refuses it."
            return .error(HonestContract.encodeStateC(error: .notSupported, hint: hint, extras: refusal))
        case .notFound(let depth, let segment, let available, let titles):
            refusal["path_matched"] = titles
            refusal["failed_depth"] = depth
            refusal["failed_segment"] = segment
            refusal["available_titles"] = available
            let hint = "No menu item matches '\(segment)' at depth \(depth). Retry with one of the titles "
                + "in available_titles (read them with list_menus)."
            return .error(HonestContract.encodeStateC(error: .elementNotFound, hint: hint, extras: refusal))
        case .ambiguous(let depth, let segment, let candidates, let titles):
            refusal["path_matched"] = titles
            refusal["failed_depth"] = depth
            refusal["failed_segment"] = segment
            refusal["matching_titles"] = candidates
            let hint = "More than one menu item matches '\(segment)' at depth \(depth); nothing was pressed."
            return .error(HonestContract.encodeStateC(error: .ambiguousTargetName, hint: hint, extras: refusal))
        case .notASubmenu(let depth, let titles):
            refusal["path_matched"] = titles
            refusal["failed_depth"] = depth
            let hint = "'\(titles.last ?? "")' has no submenu, so the path cannot continue below it."
            return .error(HonestContract.encodeStateC(error: .elementNotFound, hint: hint, extras: refusal))
        case .unreadable(let depth, let stage, let titles):
            refusal["path_matched"] = titles
            refusal["failed_depth"] = depth
            refusal["failed_stage"] = stage
            let hint = "The menu level at depth \(depth) could not be read completely (\(stage)), so the "
                + "path could not be resolved to exactly one item."
            return .error(HonestContract.encodeStateC(error: .readbackUnavailable, hint: hint, extras: refusal))
        }
        refusal["path_matched"] = matched

        let enabled = menuEnabledRead(element, runtime: ax)
        let shortcut = menuShortcutRead(element, runtime: ax)
        let hasSubmenu: Bool?
        switch menuSubmenuItemsRead(of: element, runtime: ax) {
        case .items:
            hasSubmenu = true
        case .noSubmenu:
            hasSubmenu = false
        case .unreadable:
            hasSubmenu = nil
        }
        let verdict = MenuBarModel.leafVerdict(
            enabled: enabled,
            hasSubmenu: hasSubmenu,
            commandCharacter: shortcut.character,
            commandModifiers: shortcut.modifiers,
            shortcutReadable: shortcut.readable
        )
        switch verdict {
        case .pressable:
            break
        case .quitShortcut:
            let hint = "This item's shortcut is Command-Q: it quits Logic. click_menu refuses it; use "
                + "logic_project quit, which confirms and checks for unsaved documents."
            return .error(HonestContract.encodeStateC(error: .notSupported, hint: hint, extras: refusal))
        case .shortcutUnreadable:
            let hint = "The item's shortcut could not be read, so the Quit denylist cannot be applied; "
                + "nothing was pressed."
            return .error(HonestContract.encodeStateC(error: .readbackUnavailable, hint: hint, extras: refusal))
        case .hasSubmenu:
            let hint = "'\(matched.last ?? "")' opens a submenu; name one of its items as the last path segment."
            return .error(HonestContract.encodeStateC(error: .invalidParams, hint: hint, extras: refusal))
        case .submenuUnreadable:
            let hint = "Whether '\(matched.last ?? "")' opens a submenu could not be read; nothing was pressed."
            return .error(HonestContract.encodeStateC(error: .readbackUnavailable, hint: hint, extras: refusal))
        case .disabled:
            refusal["enabled"] = false
            let hint = "'\(matched.last ?? "")' is disabled (AXEnabled false); pressing it would report "
                + "success and do nothing, so it was not pressed."
            return .error(HonestContract.encodeStateC(error: .unsupportedState, hint: hint, extras: refusal))
        case .enabledUnreadable:
            refusal["enabled"] = NSNull()
            let hint = "AXEnabled of '\(matched.last ?? "")' could not be read; an unreadable item is refused "
                + "for the same reason a disabled one is."
            return .error(HonestContract.encodeStateC(error: .readbackUnavailable, hint: hint, extras: refusal))
        }

        switch AXHelpers.performActionResult(element, kAXPressAction, runtime: ax) {
        case .success:
            var extras: [String: Any] = [
                "operation": operation,
                "path_requested": path,
                "path_matched": matched,
                "ui_locale": uiLocale,
                "write_attempted": true,
                "write_source": "ax_press_menu_item",
                "effect_read_back": false,
            ]
            if let shortcutPayload = MenuBarModel.shortcutPayload(
                character: shortcut.character, modifiers: shortcut.modifiers
            ) {
                extras["shortcut"] = shortcutPayload
            }
            return .success(HonestContract.encodeStateB(reason: .readbackUnavailable, extras: extras))
        case .failure(let error):
            refusal["write_attempted"] = true
            refusal["ax_action_status"] = error.diagnosticLabel
            let hint = "AXPress on '\(matched.last ?? "")' was not accepted (\(error.diagnosticLabel))."
            return .error(HonestContract.encodeStateC(error: .axWriteFailed, hint: hint, extras: refusal))
        }
    }

    // MARK: - AX reads

    private enum MenuBarItemsRead {
        case items([AXUIElement])
        case unavailable(stage: String, status: String)
    }

    /// The menu bar's children, with a failed read kept apart from an empty bar.
    private static func readMenuBarItems(runtime: AXLogicProElements.Runtime) -> MenuBarItemsRead {
        guard let app = AXLogicProElements.appRoot(runtime: runtime) else {
            return .unavailable(stage: "app_root", status: "unavailable")
        }
        let menuBar: AXUIElement
        switch AXHelpers.getAttributeResult(
            app, kAXMenuBarAttribute as String, runtime: runtime.ax
        ) as Result<AXUIElement?, AXHelpers.AXStatusError> {
        case .success(.some(let bar)):
            menuBar = bar
        case .success(.none):
            return .unavailable(stage: "AXMenuBar", status: "absent")
        case .failure(let error):
            return .unavailable(stage: "AXMenuBar", status: error.diagnosticLabel)
        }
        switch AXHelpers.childrenResult(menuBar, runtime: runtime.ax) {
        case .success(let items) where !items.isEmpty:
            return .items(items)
        case .success:
            return .unavailable(stage: "AXMenuBar.AXChildren", status: "empty")
        case .failure(let error):
            return .unavailable(stage: "AXMenuBar.AXChildren", status: error.diagnosticLabel)
        }
    }

    private static func menuBarUnreadableResult(operation: String, stage: String, status: String) -> String {
        HonestContract.encodeStateC(
            error: .readbackUnavailable,
            hint: "Logic's menu bar could not be read (\(stage): \(status)). Is Logic Pro running with a window open?",
            extras: [
                "operation": operation,
                "failed_stage": stage,
                "ax_status": status,
                "write_attempted": false,
            ]
        )
    }

    private static func menuTitleRead(_ element: AXUIElement, runtime: AXHelpers.Runtime) -> MenuTitleRead {
        switch AXHelpers.getAttributeResult(
            element, kAXTitleAttribute as String, runtime: runtime
        ) as Result<String?, AXHelpers.AXStatusError> {
        case .success(.some(let text)):
            return .title(text)
        case .success(.none):
            return .absent
        case .failure(let error) where error.isDefinitiveAbsence:
            return .absent
        case .failure(let error):
            return .unreadable("AXTitle \(error.diagnosticLabel)")
        }
    }

    /// `AXEnabled`, or nil when it did not read as a Bool. Never folded into `false`.
    private static func menuEnabledRead(_ element: AXUIElement, runtime: AXHelpers.Runtime) -> Bool? {
        switch AXHelpers.getAttributeResult(
            element, kAXEnabledAttribute as String, runtime: runtime
        ) as Result<Bool?, AXHelpers.AXStatusError> {
        case .success(let state):
            return state
        case .failure:
            return nil
        }
    }

    private struct MenuShortcutRead {
        let character: String?
        let modifiers: Int?
        /// False when either attribute failed to read (as opposed to being absent).
        let readable: Bool
    }

    /// `AXMenuItemCmdChar` + `AXMenuItemCmdModifiers`, decoded as `editStackEntry` decodes them.
    private static func menuShortcutRead(_ element: AXUIElement, runtime: AXHelpers.Runtime) -> MenuShortcutRead {
        var readable = true
        let character: String?
        switch AXHelpers.getAttributeResult(
            element, "AXMenuItemCmdChar", runtime: runtime
        ) as Result<String?, AXHelpers.AXStatusError> {
        case .success(let key):
            character = key
        case .failure(let error) where error.isDefinitiveAbsence:
            character = nil
        case .failure:
            character = nil
            readable = false
        }
        let modifiers: Int?
        switch AXHelpers.getAttributeResult(
            element, "AXMenuItemCmdModifiers", runtime: runtime
        ) as Result<NSNumber?, AXHelpers.AXStatusError> {
        case .success(let mask):
            modifiers = mask?.intValue
        case .failure(let error) where error.isDefinitiveAbsence:
            modifiers = nil
        case .failure:
            modifiers = nil
            readable = false
        }
        return MenuShortcutRead(character: character, modifiers: modifiers, readable: readable)
    }

    /// The items of the submenu below `element`: the children of its one `AXMenu` child. A menu-bar
    /// item and a menu item that opens a submenu both carry exactly one; a leaf carries none.
    private static func menuSubmenuItemsRead(
        of element: AXUIElement,
        runtime: AXHelpers.Runtime
    ) -> MenuChildrenRead<AXUIElement> {
        let children: [AXUIElement]
        switch AXHelpers.childrenResult(element, runtime: runtime) {
        case .success(let kids):
            children = kids
        case .failure(let error) where error.isDefinitiveAbsence:
            return .noSubmenu
        case .failure(let error):
            return .unreadable("AXChildren \(error.diagnosticLabel)")
        }
        var menus: [AXUIElement] = []
        for child in children {
            switch AXHelpers.getAttributeResult(
                child, kAXRoleAttribute as String, runtime: runtime
            ) as Result<String?, AXHelpers.AXStatusError> {
            case .success(let childRole):
                if childRole == (kAXMenuRole as String) {
                    menus.append(child)
                }
            case .failure(let error) where error.isDefinitiveAbsence:
                continue
            case .failure(let error):
                return .unreadable("AXRole \(error.diagnosticLabel)")
            }
        }
        if menus.isEmpty {
            return .noSubmenu
        }
        if menus.count > 1 {
            return .unreadable("more than one AXMenu child")
        }
        switch AXHelpers.childrenResult(menus[0], runtime: runtime) {
        case .success(let items):
            return .items(items)
        case .failure(let error) where error.isDefinitiveAbsence:
            return .items([])
        case .failure(let error):
            return .unreadable("AXMenu.AXChildren \(error.diagnosticLabel)")
        }
    }
}

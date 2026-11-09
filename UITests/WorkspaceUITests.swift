import XCTest

final class WorkspaceUITests: XCTestCase {
    func testStoreEntryAndLoginCancellation() {
        let app = XCUIApplication(); app.launch()
        let entry = app.buttons["library.decryption"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10)); entry.tap()
        let login = app.buttons["decryption.store.login"]
        XCTAssertTrue(login.waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["decryption.store.searchField"].exists)
        XCTAssertTrue(app.buttons["decryption.store.installed"].exists)
        capture("StoreDecryptionEntry",app: app)
        login.tap()
        XCTAssertTrue(app.navigationBars["商店账号"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["密码"].exists)
        XCTAssertFalse(app.buttons["登录 App Store"].isEnabled)
        capture("StoreLogin",app: app)
        app.buttons["取消"].tap()
        XCTAssertTrue(app.navigationBars["应用砸壳"].waitForExistence(timeout: 5))
        app.buttons["decryption.store.installed"].tap()
        XCTAssertTrue(app.navigationBars["本机应用"].waitForExistence(timeout: 5))
        app.buttons["取消"].tap()
    }
    func testDecryptionEntryAndLocalFilePickerCancellation() {
        let app = XCUIApplication(); app.launch()
        let entry = app.buttons["library.decryption"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10)); entry.tap()
        XCTAssertTrue(app.navigationBars["应用砸壳"].waitForExistence(timeout: 5))
        let select = app.buttons["decryption.import"]
        XCTAssertTrue(select.exists); XCTAssertTrue(select.isEnabled)
        XCTAssertFalse(app.buttons["decryption.install"].exists)
        capture("DecryptionLocalImport", app: app)
        scrollToMiddle(select,in: app); select.tap()
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["取消","Cancel"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5)); cancel.tap()
        XCTAssertTrue(select.waitForExistence(timeout: 5)); XCTAssertTrue(select.isEnabled)
    }
    /// 二级页面会隐藏标签栏，返回后标签栏有出现动画；等它可点击后再点，避免点空。
    private func tapTab(_ name: String, in app: XCUIApplication) {
        let tab = app.tabBars.buttons[name]
        let deadline = Date().addingTimeInterval(5)
        while !(tab.exists && tab.isHittable), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        tab.tap()
    }
    /// 把元素滚到屏幕中部，避开底部固定按钮栏，防止点击落到底栏按钮上。
    private func scrollToMiddle(_ element: XCUIElement, in app: XCUIApplication) {
        let limit = app.frame.height - 200
        for _ in 0..<10 where !(element.exists && element.isHittable && element.frame.maxY < limit) { app.swipeUp(velocity: .slow) }
    }
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !(element.exists && element.isHittable) { app.swipeUp(velocity: .slow) }
    }
    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testRespringConfirmationAndSimulatorExclusion() {
        let app = XCUIApplication(); app.launchArguments = ["-RetoolsRespringMethod", "webKit"]; app.launch()
        XCTAssertTrue(app.buttons["library.import"].waitForExistence(timeout: 10))
        tapTab("设置", in: app)
        app.swipeDown(); app.swipeDown()
        let tools = app.buttons["settings.deviceTools"]
        scrollToMiddle(tools, in: app); tools.tap()
        XCTAssertTrue(app.navigationBars["设备工具"].waitForExistence(timeout: 5))
        let respring = app.buttons["deviceTools.respring"]
        scrollTo(respring, in: app)
        XCTAssertTrue(respring.isEnabled)
        XCTAssertFalse(app.descendants(matching: .any)["deviceTools.respringMethod"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["网页方式（实验）"].exists)
        respring.tap()
        let confirmation = app.alerts.firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        XCTAssertTrue(confirmation.staticTexts["注销并重启桌面？"].exists)
        XCTAssertTrue(confirmation.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "设备服务")).firstMatch.exists)
        XCTAssertTrue(confirmation.buttons["取消"].exists)
        XCTAssertGreaterThan(confirmation.frame.midY, app.frame.height * 0.25)
        XCTAssertLessThan(confirmation.frame.midY, app.frame.height * 0.75)
        capture("RespringConfirmation", app: app)
        confirmation.buttons["取消"].tap()
        XCTAssertFalse(app.staticTexts["respring.status"].exists)
        XCTAssertEqual(app.webViews.count, 0)
        respring.tap()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        confirmation.buttons["注销"].tap()
        let status = app.staticTexts["respring.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        XCTAssertEqual(status.label, "请在真机上使用")
        XCTAssertEqual(app.webViews.count, 0)
        capture("RespringSimulatorExcluded", app: app)
        app.buttons["respring.close"].tap()
        XCTAssertTrue(respring.waitForExistence(timeout: 3))
        let unlocked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: respring)
        XCTAssertEqual(XCTWaiter.wait(for: [unlocked], timeout: 3), .completed, "Closing the attempt must release the workspace lock")
    }
    private func openUTMProcess(in app: XCUIApplication, rowTimeout: TimeInterval = 10) -> XCUIElement {
        XCTAssertTrue(app.buttons["library.import"].waitForExistence(timeout: 10))
        tapTab("设置", in: app)
        let tools = app.buttons["settings.deviceTools"]
        scrollToMiddle(tools, in: app); tools.tap()
        let processes = app.buttons["deviceTools.processes"]
        scrollToMiddle(processes, in: app); processes.tap()
        let row = app.buttons["deviceTools.process.101"]
        XCTAssertTrue(row.waitForExistence(timeout: rowTimeout))
        return row
    }
    func testProcessListAppearsBeforeSlowUsage() {
        let app = XCUIApplication(); app.launchArguments = ["--process-review-slow-usage"]; app.launch()
        let row = openUTMProcess(in: app, rowTimeout: 2)
        XCTAssertTrue(app.descendants(matching: .any)["processes.loadingUsage"].firstMatch.exists)
        capture("ProcessListWhileSampling", app: app)
        row.tap()
        XCTAssertTrue(app.navigationBars["UTM"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["process.status"].label.hasSuffix("运行中"))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(row.waitForExistence(timeout: 2))
    }
    func testProcessTerminationConfirmationAndVerifiedResult() {
        let app = XCUIApplication(); app.launch()
        let row = openUTMProcess(in: app)
        row.swipeLeft()
        app.buttons["结束"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        XCTAssertTrue(alert.buttons["取消"].exists)
        capture("ProcessListTerminationConfirmation", app: app)
        alert.buttons["取消"].tap()
        row.tap()
        let terminate = app.buttons["process.terminate"]
        scrollTo(terminate, in: app); terminate.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(alert.frame.midY, app.frame.height * 0.25)
        XCTAssertLessThan(alert.frame.midY, app.frame.height * 0.75)
        capture("ProcessDetailTerminationConfirmation", app: app)
        alert.buttons["取消"].tap()
        XCTAssertTrue(app.staticTexts["process.status"].label.hasSuffix("运行中"))
        terminate.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.buttons["结束进程"].tap()
        let exited = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label ENDSWITH %@", "已退出"), object: app.staticTexts["process.status"])
        XCTAssertEqual(XCTWaiter.wait(for: [exited], timeout: 8), .completed)
        XCTAssertFalse(app.buttons["process.terminate"].exists)
        app.swipeDown(); app.swipeDown()
        capture("ProcessTerminationVerified", app: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertFalse(app.buttons["deviceTools.process.101"].exists)
    }
    func testProcessTerminationFailureStaysOnDetail() {
        let app = XCUIApplication(); app.launchArguments = ["--process-review-deny-termination"]; app.launch()
        openUTMProcess(in: app).tap()
        let terminate = app.buttons["process.terminate"]
        scrollTo(terminate, in: app); terminate.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.buttons["结束进程"].tap()
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "设备拒绝")).firstMatch.waitForExistence(timeout: 5))
        capture("ProcessTerminationFailure", app: app)
        alert.buttons["好"].tap()
        XCTAssertTrue(app.navigationBars["UTM"].exists)
        XCTAssertTrue(app.staticTexts["process.status"].label.hasSuffix("运行中"))
        XCTAssertTrue(terminate.exists)
    }
    func testDevelopmentSigningShowsOptionalAppGroupWithoutAnAccount() {
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.buttons["library.import"].waitForExistence(timeout: 10))
        tapTab("设置", in: app)
        let entry = app.buttons["settings.developmentSigning"]
        scrollTo(entry, in: app); entry.tap()
        let toggle = app.switches["development.appGroup"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertFalse(app.buttons["准备 Apple ID 开发签名"].isEnabled)
        XCTAssertTrue(app.staticTexts["development.appGroupStatus"].label.contains("未配置"))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let switchedOff = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "0"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [switchedOff], timeout: 3), .completed)
        XCTAssertFalse(app.buttons["准备 Apple ID 开发签名"].isEnabled)
        capture("DevelopmentSigningAppGroup", app: app)
    }
    func testLocalFileSwitchUsesExistingAppFileBrowser() {
        let app = XCUIApplication(); app.launch()
        func reveal(_ item: XCUIElement) {
            for _ in 0..<6 {
                if item.exists, !item.frame.isEmpty, item.frame.minY > 100, item.frame.maxY < app.frame.height - 80 { return }
                app.swipeUp()
            }
        }
        func openTools() {
            tapTab("设置", in: app)
            let tools = app.buttons["settings.deviceTools"]
            reveal(tools); tools.tap()
            XCTAssertTrue(app.switches["deviceTools.localFiles"].waitForExistence(timeout: 5))
        }
        func openUTMFiles() {
            let apps = app.buttons["deviceTools.apps"]
            reveal(apps); apps.tap()
            let utm = app.buttons["deviceTools.app.com.utmapp.UTM"]
            XCTAssertTrue(utm.waitForExistence(timeout: 10)); reveal(utm); utm.tap()
            XCTAssertFalse(app.buttons["本机读取应用文件（实验）"].exists)
            let files = app.buttons["deviceTools.files"]
            reveal(files); XCTAssertTrue(files.isEnabled); files.tap()
        }
        XCTAssertTrue(app.buttons["library.import"].waitForExistence(timeout: 10))
        openTools()
        let toggle = app.switches["deviceTools.localFiles"]
        if toggle.value as? String == "1" { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        capture("LocalFileSwitchOff", app: app)
        openUTMFiles()
        XCTAssertTrue(app.buttons["deviceTools.files.add"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Documents")).firstMatch.waitForExistence(timeout: 5))
        capture("ExistingDeviceFileBrowser", app: app)
        for _ in 0..<3 { app.navigationBars.buttons.element(boundBy: 0).tap() }
        app.swipeDown()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        capture("LocalFileSwitchOn", app: app)
        app.terminate(); app.launch()
        openTools()
        XCTAssertEqual(app.switches["deviceTools.localFiles"].value as? String, "1")
        defer {
            for _ in 0..<3 { app.navigationBars.buttons.element(boundBy: 0).tap() }
            app.swipeDown()
            let setting = app.switches["deviceTools.localFiles"]
            if setting.exists, setting.value as? String == "1" { setting.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        }
        openUTMFiles()
        let failure = app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "deviceTools.files.failure", "模拟器")).firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["本机访问 · 只读"].exists)
        XCTAssertFalse(app.buttons["deviceTools.files.add"].exists)
        XCTAssertFalse(app.textFields["localFiles.path"].exists)
        capture("IntegratedLocalFileBrowser", app: app)
    }
    func testLibraryDeletionFromContextAndProjectMenu() throws {
        let app = XCUIApplication(); app.launch()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'library.package.' AND label CONTAINS %@", "测试应用")).firstMatch
        guard row.waitForExistence(timeout: 5) else { throw XCTSkip("Requires a disposable synthetic review workspace") }
        row.press(forDuration: 0.7)
        app.buttons["从应用库移除"].tap()
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"])).firstMatch
        let confirm = app.buttons["移除 IPA 和签名输出"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3)); capture("LibraryDeletionConfirmation", app: app)
        if cancel.exists { cancel.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)).tap() }
        XCTAssertTrue(row.exists); row.tap()
        app.buttons["签名操作"].tap(); app.buttons["从应用库移除"].tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        if cancel.exists { cancel.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)).tap() }
        XCTAssertTrue(app.navigationBars["签名配置"].exists)
        app.buttons["签名操作"].tap(); app.buttons["从应用库移除"].tap()
        app.buttons["移除 IPA 和签名输出"].tap()
        XCTAssertTrue(app.navigationBars["应用库"].waitForExistence(timeout: 5))
        XCTAssertFalse(row.exists); capture("LibraryDeletionCompleted", app: app)
        app.terminate(); app.launch(); XCTAssertFalse(row.exists)
    }
    func testFloatingControlsDragPassthroughAndActions() {
        let app = XCUIApplication(); app.launchArguments = ["--preview-controls"]; app.launch()
        let handle = app.buttons["container.controls.handle"]
        XCTAssertTrue(handle.waitForExistence(timeout: 10))
        capture("DockCollapsed", app: app)
        let originalY = handle.frame.midY
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.7)))
        XCTAssertGreaterThan(handle.frame.midY, originalY)
        handle.tap()
        XCTAssertTrue(app.buttons["container.controls.workbench"].waitForExistence(timeout: 3))
        capture("FloatingControls", app: app)
        let icons = app.scrollViews.containing(.button, identifier: "container.controls.app.22222222-2222-2222-2222-222222222222").firstMatch
        icons.swipeUp()
        XCTAssertTrue(app.buttons["container.controls.app.00000000-0000-0000-0000-000000000008"].isHittable)
        capture("DockScrolled", app: app)
        icons.swipeDown()
        let swipeOrigin = icons.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
        swipeOrigin.press(forDuration: 0.1, thenDragTo: swipeOrigin.withOffset(CGVector(dx: 45, dy: 0)))
        XCTAssertTrue(handle.waitForExistence(timeout: 3))
        handle.tap()
        app.buttons["library.import"].tap()
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10)); cancel.tap()
        XCTAssertTrue(handle.exists)
        XCTAssertFalse(app.buttons["container.controls.workbench"].exists)
        handle.tap()
        app.buttons["container.controls.app.22222222-2222-2222-2222-222222222222"].tap()
        XCTAssertTrue(app.staticTexts["已请求切换到另一个应用"].exists)
        XCTAssertTrue(handle.exists)
        handle.tap()
        app.buttons["container.controls.workbench"].tap()
        XCTAssertTrue(app.staticTexts["已请求返回 Retools"].exists)
        handle.tap()
        app.buttons["container.controls.workbench"].press(forDuration: 0.7)
        app.buttons["退出当前容器"].tap()
        XCTAssertTrue(app.staticTexts["已请求退出容器"].waitForExistence(timeout: 3))
        XCTAssertTrue(handle.exists)
    }
    func testCollapsedHandleMovesInBothAxesWithoutExpanding() {
        let app = XCUIApplication(); app.launchArguments = ["--preview-controls"]; app.launch()
        let handle = app.buttons["container.controls.handle"]
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.7)))
        XCTAssertLessThan(handle.frame.minX, 5)
        XCTAssertGreaterThan(handle.frame.midY, app.frame.height * 0.6)
        XCTAssertFalse(app.buttons["container.controls.workbench"].exists)
        capture("CollapsedHandleFreeDragLeft", app: app)
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.35)))
        XCTAssertGreaterThan(handle.frame.minX, app.frame.width - 55)
        XCTAssertLessThan(handle.frame.midY, app.frame.height * 0.45)
        XCTAssertFalse(app.buttons["container.controls.workbench"].exists)
        handle.tap()
        XCTAssertTrue(app.buttons["container.controls.workbench"].waitForExistence(timeout: 3))
    }
    func testLibraryOpensAppExpiryList() throws {
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.buttons["library.import"].waitForExistence(timeout: 10))
        // 入口是「Apple ID 签名」区块标题，只在用到 Apple ID 签名时出现。
        let entry = app.descendants(matching: .any)["library.expiry"].firstMatch
        guard entry.waitForExistence(timeout: 5) else { throw XCTSkip("Seed demo Apple ID renewal data first") }
        entry.tap()
        XCTAssertTrue(app.navigationBars["应用有效期"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["expiry.badge.host"].firstMatch.exists)
        XCTAssertTrue(app.buttons["expiry.refreshAll"].exists)
        capture("AppExpiry", app: app)
        app.buttons["完成"].tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 3))
    }
    func testRenewalPageReview() {
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.buttons["library.import"].waitForExistence(timeout: 10))
        tapTab("设置", in: app)
        let entry = app.buttons["settings.renewal"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5)); entry.tap()
        XCTAssertTrue(app.navigationBars["Apple ID 自动续签"].waitForExistence(timeout: 5))
        capture("Renewal1", app: app)
        for index in 2...5 { app.swipeUp(); capture("Renewal\(index)", app: app) }
        for _ in 0..<5 { app.swipeDown() }
        scrollTo(app.buttons["renewal.expiry"], in: app)
        app.buttons["renewal.expiry"].tap()
        XCTAssertTrue(app.navigationBars["应用有效期"].waitForExistence(timeout: 3))
        capture("RenewalExpiry", app: app)
    }
    /// 仅用于界面评审截图；依赖模拟器中预置的演示续签数据。
    func testDesignReview() {
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.buttons["library.import"].waitForExistence(timeout: 10))
        capture("ReviewLibrary", app: app)
        let package = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'library.package.' AND label CONTAINS %@", "测试应用")).firstMatch
        tapTab("容器", in: app)
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "容器管理")).firstMatch
        if !card.waitForExistence(timeout: 2) {
            tapTab("应用库", in: app)
            if package.waitForExistence(timeout: 3) {
                package.press(forDuration: 1.0)
                let importButton = app.buttons["导入到容器"]
                if importButton.waitForExistence(timeout: 3) { importButton.tap() }
            }
            tapTab("容器", in: app)
        }
        if card.waitForExistence(timeout: 8) {
            capture("ReviewContainers", app: app)
            card.tap()
            if app.navigationBars["容器管理"].waitForExistence(timeout: 3) {
                capture("ReviewContainerDetail", app: app)
                app.buttons["完成"].tap()
            }
        }
        tapTab("设置", in: app)
        let renewalEntry = app.buttons["settings.renewal"]
        XCTAssertTrue(renewalEntry.waitForExistence(timeout: 5))
        capture("ReviewSettings", app: app)
        let shortcuts = app.buttons["settings.shortcuts"]
        scrollTo(shortcuts, in: app); shortcuts.tap()
        XCTAssertTrue(app.navigationBars["快捷指令"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["每天自动续签"].exists || app.staticTexts["每天自动续签".uppercased()].exists)
        capture("ReviewShortcuts", app: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        for _ in 0..<4 { app.swipeDown() }
        XCTAssertTrue(renewalEntry.waitForExistence(timeout: 3))
        renewalEntry.tap()
        XCTAssertTrue(app.navigationBars["Apple ID 自动续签"].waitForExistence(timeout: 5))
        capture("ReviewRenewal", app: app)
        app.swipeUp(); capture("ReviewRenewal2", app: app)
        scrollTo(app.buttons["renewal.connection"], in: app)
        app.buttons["renewal.connection"].tap()
        XCTAssertTrue(app.navigationBars["连接与验证服务"].waitForExistence(timeout: 3))
        capture("ReviewConnection", app: app)
    }
    func testPluginManagerOpensImporterAndCancels() {
        let app = XCUIApplication(); app.launch()
        tapTab("设置", in: app)
        app.buttons["settings.plugins"].tap()
        XCTAssertTrue(app.navigationBars["插件管理"].waitForExistence(timeout: 3))
        app.buttons["plugins.import"].tap()
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10)); cancel.tap()
        XCTAssertTrue(app.buttons["plugins.import"].exists)
    }
    func testDockPositionDragCrossesEdgesAndDoesNotStickAfterClamping() {
        let app = XCUIApplication(); app.launchArguments = ["--preview-controls"]; app.launch()
        let handle = app.buttons["container.controls.handle"]
        XCTAssertTrue(handle.waitForExistence(timeout: 5)); handle.tap()
        let grip = app.buttons["container.controls.close"]
        XCTAssertTrue(grip.waitForExistence(timeout: 3))
        grip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.85)))
        XCTAssertEqual(grip.frame.minX, 8, accuracy: 2)
        let previousY = grip.frame.midY
        let origin = grip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        origin.press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: 0, dy: -22)))
        XCTAssertEqual(grip.frame.midY, previousY - 22, accuracy: 5)
        capture("DockPositionDrag", app: app)
        grip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.3)))
        XCTAssertGreaterThan(grip.frame.minX, app.frame.width - 90)
    }
    /// Run Scripts/seed-plugin-review.py before this optional fixture review.
    func testDetailedPluginSelectionAndWeakModePersist() throws {
        let app = XCUIApplication(); app.launch()
        let package = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "测试应用")).firstMatch
        guard package.waitForExistence(timeout: 5) else { throw XCTSkip("Seed the synthetic review workspace first") }
        package.tap()
        app.buttons["package.plugins"].tap()
        XCTAssertTrue(app.navigationBars["签名注入插件"].waitForExistence(timeout: 3))
        let archive = app.staticTexts["FixturePlugin"].firstMatch
        guard archive.waitForExistence(timeout: 3) else { throw XCTSkip("Run Scripts/seed-plugin-review.py before this fixture review") }
        archive.tap()
        app.buttons["plugins.select.FixturePlugin.dylib"].tap()
        let ordered = app.buttons["plugins.order.33333333-3333-3333-3333-333333333333:Library/MobileSubstrate/DynamicLibraries/FixturePlugin.dylib"]
        ordered.tap()
        XCTAssertTrue(app.staticTexts["动态库信息"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "arm64")).firstMatch.exists)
        app.buttons["plugins.entry.kind"].tap()
        app.buttons["可选加载（弱链接）"].tap()
        capture("PluginLibraryDetails", app: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        capture("PluginInjection", app: app)
        app.buttons["plugins.save"].tap()
        XCTAssertTrue(app.navigationBars["签名配置"].waitForExistence(timeout: 3))
        app.buttons["package.plugins"].tap()
        XCTAssertTrue(app.staticTexts["FixturePlugin · 可选加载（弱链接）"].waitForExistence(timeout: 3))
    }
    func testIPAFilePickerOpensAndCancels() {
        let app = XCUIApplication(); app.launch()
        app.buttons["library.import"].tap()
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), app.debugDescription)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.lifetime = .keepAlways
        add(screenshot)
        cancel.tap()
        XCTAssertTrue(app.buttons["library.import"].waitForExistence(timeout: 3))
    }
    func testSigningProjectEditingPersistenceAndWorkspaceBrowser() throws {
        let app = XCUIApplication(); app.launch()
        let package = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "测试应用")).firstMatch
        guard package.waitForExistence(timeout: 5) else { throw XCTSkip("Seed the synthetic review workspace first") }
        capture("LibrarySimplified", app: app)
        package.tap()
        XCTAssertTrue(app.navigationBars["签名配置"].waitForExistence(timeout: 3))
        capture("SigningProjectTop", app: app)
        app.buttons["project.outputName"].tap()
        let name = app.textFields["project.editor.value"]
        XCTAssertTrue(name.waitForExistence(timeout: 3)); name.tap(); name.typeText("Review Output")
        app.buttons["project.editor.save"].tap()
        app.segmentedControls["project.format"].buttons["TIPA"].tap()
        XCTAssertTrue(app.staticTexts["Review Output.tipa"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["package.confirmSign"].label.contains("签名并导出"))
        let sharing = app.switches["project.fileSharing"]
        scrollToMiddle(sharing, in: app)
        XCTAssertTrue(sharing.isHittable); sharing.tap()
        capture("SigningProjectOptions", app: app)
        let advanced = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "更多选项")).firstMatch
        scrollToMiddle(advanced, in: app)
        XCTAssertTrue(advanced.isHittable); advanced.tap()
        XCTAssertTrue(app.switches["project.whiteIcon"].waitForExistence(timeout: 3))
        capture("SigningProjectAdvancedOptions", app: app)
        advanced.tap()
        let browser = app.buttons["project.browse"]
        scrollToMiddle(browser, in: app)
        XCTAssertTrue(browser.isHittable)
        capture("SigningProjectCertificate", app: app)
        browser.tap()
        let info = app.staticTexts["Info.plist"].firstMatch
        XCTAssertTrue(info.waitForExistence(timeout: 5)); info.tap()
        XCTAssertTrue(app.navigationBars["Info.plist"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "CFBundleIdentifier")).firstMatch.waitForExistence(timeout: 3))
        capture("SigningProjectWorkspaceFile", app: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["完成"].tap()
        XCTAssertTrue(app.navigationBars["签名配置"].waitForExistence(timeout: 3))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        package.tap()
        XCTAssertTrue(app.staticTexts["Review Output.tipa"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.segmentedControls["project.format"].buttons["TIPA"].isSelected)
    }
    func testLibraryOpensSigningWithTabBarHidden() throws {
        let app = XCUIApplication(); app.launch()
        capture("SigningCenter", app: app)
        let package = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "测试应用")).firstMatch
        guard package.waitForExistence(timeout: 3) else { throw XCTSkip("Seed the synthetic review workspace first") }
        for _ in 0..<4 { if package.isHittable { break }; app.swipeUp() }
        package.tap()
        XCTAssertTrue(app.navigationBars["签名配置"].waitForExistence(timeout: 3))
        let libraryTab = app.tabBars.buttons["应用库"]
        XCTAssertFalse(libraryTab.exists && libraryTab.isHittable, "二级页面应隐藏底部标签栏")
        capture("SigningProjectInTab", app: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 3))
        XCTAssertTrue(libraryTab.isSelected)
    }

    func testSigningFilesAndDependenciesOpenAcrossReentry() throws {
        let app = XCUIApplication(); app.launch()
        let package = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.package.")).firstMatch
        guard package.waitForExistence(timeout: 5) else { throw XCTSkip("Import a local IPA before this read-only review") }
        package.tap()
        verifySigningFilesAndDependencies(app: app, tapX: 0.18)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        package.tap()
        verifySigningFilesAndDependencies(app: app, tapX: 0.7)
    }
    func testAIIsOptInAndCompletesBothProviderEndpoints() {
        let app = XCUIApplication(); app.launchArguments = ["--picker-test-documents", "--ai-discovery-review"]; app.launch()
        if app.buttons["以后"].exists { app.buttons["以后"].tap() }
        tapTab("设置", in: app)
        let enabled = app.switches["settings.aiEnabled"]
        scrollTo(enabled, in: app); XCTAssertTrue(enabled.waitForExistence(timeout: 3))
        if enabled.value as? String == "1" { enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() }
        XCTAssertFalse(app.tabBars.buttons["AI"].exists)
        scrollTo(enabled, in: app); enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        app.buttons["settings.ai"].tap()
        XCTAssertTrue(app.navigationBars["AI 接口"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.textFields["ai.model"].exists)
        XCTAssertFalse(app.segmentedControls["ai.provider"].exists)
        let run = UUID().uuidString.prefix(8)
        let compatibleAddress = "https://ai-review.invalid/run/\(run)/v1"
        let nativeAddress = "https://ai-review.invalid/anthropic/\(run)/v1"
        app.buttons["ai.address.clear"].tap()
        app.textFields["ai.address"].tap(); app.textFields["ai.address"].typeText(compatibleAddress)
        app.secureTextFields["ai.key"].tap(); app.secureTextFields["ai.key"].typeText("review-only-key")
        XCTAssertEqual(app.staticTexts["ai.endpointPreview"].label, compatibleAddress + "/models")
        capture("AIAutomaticSettings", app: app)
        app.buttons["ai.settings.save"].tap()
        if app.buttons["以后"].waitForExistence(timeout: 1) { app.buttons["以后"].tap() }
        XCTAssertTrue(app.buttons["settings.ai"].waitForExistence(timeout: 8))
        tapTab("AI", in: app)
        app.buttons["ai.models"].tap()
        XCTAssertTrue(app.buttons["ai.model.review-chat"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["ai.model.review-chat"].value as? String, "已选中")
        capture("AIDiscoveredModels", app: app)
        app.buttons["ai.model.review-image"].tap()
        app.buttons["ai.models"].tap()
        XCTAssertEqual(app.buttons["ai.model.review-image"].value as? String, "已选中")
        app.buttons["ai.model.review-chat"].tap()
        app.buttons["ai.models"].tap(); app.buttons["ai.settings"].tap()
        app.buttons["ai.address.clear"].tap()
        app.textFields["ai.address"].tap(); app.textFields["ai.address"].typeText(nativeAddress)
        XCTAssertTrue((app.secureTextFields["ai.key"].value as? String ?? "").contains("API Key"))
        app.secureTextFields["ai.key"].tap(); app.secureTextFields["ai.key"].typeText("review-only-key")
        app.buttons["ai.settings.save"].tap()
        if app.buttons["以后"].waitForExistence(timeout: 2) { app.buttons["以后"].tap() }
        XCTAssertTrue(app.buttons["ai.model.review-claude"].waitForExistence(timeout: 8))
        app.buttons["ai.model.review-claude"].tap()
        app.buttons["ai.new"].tap()
        capture("AIChatEmpty", app: app)
        app.buttons["ai.addAttachment"].tap(); app.buttons["选择文件"].tap()
        let document = app.cells.matching(NSPredicate(format: "label CONTAINS %@", "AI Review Notes")).firstMatch
        XCTAssertTrue(document.waitForExistence(timeout: 5)); document.tap()
        let remove = app.buttons["移除附件 AI Review Notes.txt"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5)); capture("AIDraftAttachment", app: app)
        app.buttons["预览附件 AI Review Notes.txt"].tap()
        XCTAssertTrue(app.buttons["ai.preview.close"].waitForExistence(timeout: 5)); app.buttons["ai.preview.close"].tap(); remove.tap()
        XCTAssertFalse(remove.exists)
        app.buttons["ai.addAttachment"].tap(); app.buttons["选择文件"].tap()
        let cancelFiles = app.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"])).firstMatch
        XCTAssertTrue(cancelFiles.waitForExistence(timeout: 5)); cancelFiles.tap()
        app.buttons["ai.addAttachment"].tap(); app.buttons["照片与视频"].tap()
        let cancelPhotos = app.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"])).firstMatch
        XCTAssertTrue(cancelPhotos.waitForExistence(timeout: 5)); cancelPhotos.tap()
        tapTab("设置", in: app)
        scrollTo(enabled, in: app); enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertFalse(app.tabBars.buttons["AI"].exists)
        XCTAssertFalse(app.buttons["settings.ai"].exists)
    }
    func testAIPhotoImportAndMultilineComposer() {
        let app = XCUIApplication(); app.launch(); tapTab("设置", in: app)
        let enabled = app.switches["settings.aiEnabled"]
        scrollTo(enabled, in: app)
        if enabled.value as? String != "1" { enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() }
        tapTab("AI", in: app); app.buttons["ai.new"].tap()
        app.buttons["ai.addAttachment"].tap(); app.buttons["照片与视频"].tap()
        let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 20)); photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let addPhoto = app.buttons.matching(NSPredicate(format: "label IN %@", ["完成", "Done", "添加", "Add"])).firstMatch
        XCTAssertTrue(addPhoto.waitForExistence(timeout: 5)); addPhoto.tap()
        let previewPhoto = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "预览附件 ")).firstMatch
        XCTAssertTrue(previewPhoto.waitForExistence(timeout: 10)); capture("AIPhotoImported", app: app)
        // 图片附件用全屏查看器打开（从缩略图放大），不再是文件预览面板。
        previewPhoto.tap()
        let closeViewer = app.buttons["ai.viewer.close"]
        XCTAssertTrue(closeViewer.waitForExistence(timeout: 5)); closeViewer.tap()
        XCTAssertTrue(closeViewer.waitForNonExistence(timeout: 3))
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "移除附件 ")).firstMatch.tap()
        let input = app.descendants(matching: .any)["ai.input"].firstMatch
        input.tap(); input.typeText("查看附件\n补充说明")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertFalse(app.buttons["ai.keyboard.dismiss"].exists)
        capture("AIComposerKeyboard", app: app)
        let conversation = app.scrollViews["ai.messages"]
        conversation.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        XCTAssertEqual(input.value as? String, "查看附件\n补充说明")
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        conversation.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        XCTAssertEqual(input.value as? String, "查看附件\n补充说明")
        capture("AIComposerDismissed", app: app)
        tapTab("设置", in: app)
        scrollTo(enabled, in: app); enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertFalse(app.tabBars.buttons["AI"].exists)
        XCTAssertFalse(app.buttons["settings.ai"].exists)
    }
    func testAIImagePreviewSavingAndReuse() throws {
        let app = XCUIApplication(); app.launch(); tapTab("设置", in: app)
        let enabled = app.switches["settings.aiEnabled"]
        scrollTo(enabled, in: app)
        if enabled.value as? String != "1" { enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() }
        tapTab("AI", in: app)
        guard app.staticTexts["这张图片仅用于模拟器界面验证。"].waitForExistence(timeout: 3) else { throw XCTSkip("Run seed-ai-review.py in the dedicated simulator first") }
        app.scrollViews.firstMatch.swipeUp()
        let save = app.buttons["ai.image.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 3)); capture("AIMediaConversation", app: app)
        app.buttons["预览生成图片"].tap()
        let close = app.buttons["ai.viewer.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5)); close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 3))
        app.scrollViews.firstMatch.swipeUp()
        save.tap()
        XCTAssertTrue(app.staticTexts["已保存到相册"].waitForExistence(timeout: 5))
        app.buttons["将图片添加为附件"].tap()
        XCTAssertTrue(app.buttons["预览附件 生成图片.png"].waitForExistence(timeout: 3))
        capture("AIImageReused", app: app)
        app.buttons["移除附件 生成图片.png"].tap()
        XCTAssertFalse(app.buttons["预览附件 生成图片.png"].exists)
    }
    func testAIModelBrandsAndKeyboardGestures() throws {
        let app = XCUIApplication(); app.launch(); tapTab("设置", in: app)
        let enabled = app.switches["settings.aiEnabled"]
        scrollTo(enabled, in: app)
        if enabled.value as? String != "1" { enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() }
        tapTab("AI", in: app)
        guard app.staticTexts["这张图片仅用于模拟器界面验证。"].waitForExistence(timeout: 3) else { throw XCTSkip("Run seed-ai-review.py in the dedicated simulator first") }
        app.buttons["ai.models"].tap()
        let imageModel = app.buttons["ai.model.gpt-image-2.6-sunburst"]
        XCTAssertTrue(imageModel.waitForExistence(timeout: 3))
        XCTAssertEqual(imageModel.value as? String, "已选中")
        capture("AIModelBrands", app: app)
        app.buttons["ai.model.anthropic/claude-sonnet-4-5"].tap()
        XCTAssertEqual(app.buttons["ai.models"].value as? String, "Claude · 界面示例")
        app.scrollViews["ai.messages"].swipeDown()
        XCTAssertTrue(app.staticTexts["gpt-image-2.6-sunburst"].firstMatch.exists)
        capture("AIModelChangeKeepsReplySignature", app: app)
        app.buttons["ai.new"].tap()
        let input = app.descendants(matching: .any)["ai.input"].firstMatch
        input.tap(); input.typeText("第一行\n第二行")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertFalse(app.buttons["ai.keyboard.dismiss"].exists)
        XCTAssertFalse(app.tabBars.firstMatch.isHittable)
        let addAttachment = app.buttons["ai.addAttachment"], send = app.buttons["ai.send"]
        XCTAssertTrue(addAttachment.isHittable); XCTAssertTrue(send.isHittable)
        XCTAssertLessThan(addAttachment.frame.maxY, app.keyboards.firstMatch.frame.minY)
        XCTAssertLessThan(send.frame.maxY, app.keyboards.firstMatch.frame.minY)
        capture("AINativeComposerKeyboard", app: app)
        let conversation = app.scrollViews["ai.messages"]
        conversation.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        XCTAssertEqual(input.value as? String, "第一行\n第二行")
        input.tap()
        conversation.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        XCTAssertEqual(input.value as? String, "第一行\n第二行")
        XCTAssertTrue(app.tabBars.buttons["设置"].isHittable)
        capture("AINativeComposerDismissed", app: app)
        app.buttons["ai.models"].tap(); app.buttons["ai.settings"].tap()
        XCTAssertTrue(app.navigationBars["AI 接口"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["ai.settings.save"].isEnabled)
    }
    private func verifySigningFilesAndDependencies(app: XCUIApplication, tapX: CGFloat) {
        let dependencies = app.buttons["project.dependencies"]
        scrollToMiddle(dependencies, in: app)
        XCTAssertTrue(dependencies.isHittable)
        dependencies.coordinate(withNormalizedOffset: CGVector(dx: tapX, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["主二进制依赖"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["project.dependencies.summary"].waitForExistence(timeout: 10))
        capture("SigningDependencies", app: app)
        app.buttons["project.dependencies.close"].tap()
        XCTAssertTrue(app.navigationBars["签名配置"].waitForExistence(timeout: 3))
        let browser = app.buttons["project.browse"]
        XCTAssertTrue(browser.isHittable)
        browser.coordinate(withNormalizedOffset: CGVector(dx: tapX, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["工作区文件"].waitForExistence(timeout: 3))
        let info = app.staticTexts["Info.plist"].firstMatch
        XCTAssertTrue(info.waitForExistence(timeout: 10)); info.tap()
        XCTAssertTrue(app.navigationBars["Info.plist"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "CFBundleIdentifier")).firstMatch.waitForExistence(timeout: 3))
        capture("SigningWorkspaceFile", app: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["project.files.close"].tap()
        XCTAssertTrue(app.navigationBars["签名配置"].waitForExistence(timeout: 3))
    }

    /// Seed Documents/PickerFixture.ipa before running this optional provider test.
    /// 需要事先把 Tests/Fixtures 中的 PluginIdentity.p12 / PluginIdentity.mobileprovision 以 SigningProgress.* 放入应用 Documents。
    func testSigningShowsStepProgressAndExportsResult() throws {
        let app = XCUIApplication(); app.launchArguments = ["--picker-test-documents"]; app.launch()
        XCTAssertTrue(app.buttons["library.import"].waitForExistence(timeout: 10))
        let package = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'library.package.' AND label CONTAINS %@", "测试应用")).firstMatch
        guard package.waitForExistence(timeout: 3) else { throw XCTSkip("Seed the synthetic review workspace first") }
        tapTab("设置", in: app)
        app.buttons["settings.certificates"].tap()
        XCTAssertTrue(app.navigationBars["证书管理"].waitForExistence(timeout: 3))
        app.buttons["certificates.import"].tap()
        for (label, file) in [("P12 证书", "SigningProgress.p12"), ("描述文件", "SigningProgress.mobileprovision")] {
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch.tap()
            let cell = app.cells.matching(NSPredicate(format: "label CONTAINS %@", (file as NSString).deletingPathExtension)).matching(NSPredicate(format: "label CONTAINS %@", (file as NSString).pathExtension)).firstMatch
            guard cell.waitForExistence(timeout: 5) else { throw XCTSkip("Place \(file) in the app's Documents first") }
            cell.tap()
        }
        app.secureTextFields["identity.password"].tap(); app.secureTextFields["identity.password"].typeText("test-only")
        app.buttons["identity.save"].tap()
        XCTAssertTrue(app.navigationBars["证书管理"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["操作未完成"].waitForExistence(timeout: 2))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tapTab("应用库", in: app)
        package.tap()
        XCTAssertTrue(app.navigationBars["签名配置"].waitForExistence(timeout: 3))
        // TIPA 或移除 Embedded 时主按钮本身就是「签名并导出」，否则用旁边的仅导出按钮。
        let confirm = app.buttons["package.confirmSign"]
        if confirm.label.contains("导出") { confirm.tap() } else { app.buttons["project.exportOnly"].tap() }
        let header = app.descendants(matching: .any)["signing.progress.header"].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["signing.progress.sign"].firstMatch.exists)
        let close = app.buttons["signing.progress.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "签名完成")).firstMatch.exists, app.debugDescription)
        XCTAssertTrue(app.buttons["signing.progress.share"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["signing.progress.error"].firstMatch.exists)
        capture("SigningProgressDone", app: app)
        app.swipeUp(); capture("SigningProgressDoneLarge", app: app)
        close.tap()
        XCTAssertTrue(app.buttons["package.confirmSign"].waitForExistence(timeout: 3))
    }
    func testSelectingIPAFromFilesImportsIntoLibrary() throws {
        let app = XCUIApplication(); app.launchArguments = ["--picker-test-documents"]; app.launch()
        app.buttons["library.import"].tap()
        let file = app.cells.matching(NSPredicate(format: "label CONTAINS %@", "PickerFixture")).firstMatch
        guard file.waitForExistence(timeout: 5) else {
            throw XCTSkip("Place Tests/Fixtures/Fixture.ipa in the app's Documents as PickerFixture.ipa and open that folder in Files before this provider integration test.")
        }
        XCTAssertTrue(file.isEnabled); file.tap()
        XCTAssertTrue(app.staticTexts["测试应用"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
    }

    func testTabsAndCertificateSetup() {
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.buttons["library.import"].waitForExistence(timeout: 10))
        tapTab("设置", in: app)
        app.buttons["settings.certificates"].tap()
        XCTAssertTrue(app.navigationBars["证书管理"].waitForExistence(timeout: 3))
        app.buttons["certificates.import"].tap()
        XCTAssertTrue(app.navigationBars["导入签名证书"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["identity.save"].isEnabled)
        app.buttons["取消"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tapTab("容器", in: app)
        XCTAssertTrue(app.navigationBars["容器空间"].waitForExistence(timeout: 3))
        tapTab("设置", in: app)
        XCTAssertTrue(app.buttons["settings.renewal"].exists)
        app.buttons["settings.renewal"].tap()
        XCTAssertTrue(app.navigationBars["Apple ID 自动续签"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["renewal.renewNow"].exists)
        scrollTo(app.textFields["apple.username"], in: app)
        XCTAssertTrue(app.textFields["apple.username"].exists)
        scrollTo(app.buttons["renewal.connection"], in: app)
        app.buttons["renewal.connection"].tap()
        XCTAssertTrue(app.navigationBars["连接与验证服务"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["apple.checkService"].exists)
        XCTAssertTrue(app.staticTexts["外部代理的本地回环"].exists)
        app.buttons["settings.deviceConnection"].tap()
        XCTAssertTrue(app.navigationBars["设备配对与连接"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["导入已有配对文件"].exists)
        for _ in 0..<3 { app.navigationBars.buttons.element(boundBy: 0).tap() }
        XCTAssertTrue(app.buttons["settings.runtime"].waitForExistence(timeout: 3))
        app.buttons["settings.runtime"].tap()
        XCTAssertTrue(app.navigationBars["容器运行设置"].waitForExistence(timeout: 3))
        app.segmentedControls["runtime.mode"].buttons["免 JIT"].tap()
        app.buttons["runtime.check"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["runtime.error"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["操作未完成"].exists)
    }

    func testContainerRuntimeSettingsKeepsModeAndShowsActionResultInPlace() {
        let app = XCUIApplication(); app.launch()
        tapTab("容器", in: app)
        capture("Containers", app: app)
        app.buttons["containers.runtimeSettings"].tap()
        XCTAssertTrue(app.navigationBars["容器运行设置"].waitForExistence(timeout: 3))
        app.segmentedControls["runtime.mode"].buttons["JIT"].tap()
        app.segmentedControls["runtime.jitProvider"].buttons["配对回环"].tap()
        scrollTo(app.buttons["runtime.check"], in: app)
        XCTAssertEqual(app.buttons["runtime.check"].label, "启用 JIT")
        capture("JITSettings", app: app)
        app.buttons["runtime.check"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "模拟器无法启用设备 JIT")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["容器运行设置"].exists)
        XCTAssertFalse(app.alerts["操作未完成"].exists)
        app.buttons["完成"].tap()
        tapTab("设置", in: app)
        capture("Settings", app: app)
        app.buttons["settings.runtime"].tap()
        XCTAssertTrue(app.segmentedControls["runtime.mode"].buttons["JIT"].isSelected)
        app.segmentedControls["runtime.jitProvider"].buttons["外部工具"].tap()
        XCTAssertEqual(app.buttons["runtime.check"].label, "检查外部 JIT 状态")
        XCTAssertFalse(app.descendants(matching: .any)["runtime.error"].firstMatch.exists)
        app.segmentedControls["runtime.mode"].buttons["免 JIT"].tap()
        XCTAssertFalse(app.segmentedControls["runtime.jitProvider"].exists)
        XCTAssertEqual(app.buttons["runtime.check"].label, "检测免 JIT")
    }
}

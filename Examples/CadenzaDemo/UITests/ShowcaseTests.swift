import XCTest

final class ShowcaseTests: XCTestCase {
    #if os(iOS)
    // Device-only acceptance check: the iOS 26.4 simulator does not expose
    // the native media card. This check remains outstanding on real hardware.
    #if !targetEnvironment(simulator)
    @MainActor func testSystemNowPlayingControls() {
        let app = application(); app.launch()
        activate(app.buttons["playPause"])
        waitLabel("Pause", on: app.buttons["playPause"])
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.01))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.7)))
        XCTAssertTrue(springboard.staticTexts["After the light"].waitForExistence(timeout: 8))
        let pause = springboard.buttons["Pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5)); pause.tap()
        app.activate()
        waitLabel("Play", on: app.buttons["playPause"])
        app.terminate()
    }
    #endif

    @MainActor func testSeekingKeepsTransportStable() {
        let app = application(); app.launch()
        activate(app.buttons["playPause"])
        let slider = app.sliders.firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        for target in [0.7, 0.2, 0.6] {
            slider.adjust(toNormalizedSliderPosition: target)
            for control in ["playPause", "previous", "next", "shuffle", "repeatMode"] {
                XCTAssertTrue(app.buttons[control].exists)
                XCTAssertTrue(app.buttons[control].isEnabled)
            }
            XCTAssertEqual(app.buttons["playPause"].label, "Pause")
            let elapsed = app.staticTexts["elapsed-time"]
            let initial = elapsed.label
            let advancing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", initial), object: elapsed)
            let result = XCTWaiter.wait(for: [advancing], timeout: 4)
            XCTAssertEqual(result, .completed, "Elapsed time must advance after seeking")
        }
        activate(app.buttons["playPause"])
        XCTAssertEqual(app.buttons["playPause"].label, "Play")
        slider.adjust(toNormalizedSliderPosition: 0.3)
        XCTAssertEqual(app.buttons["playPause"].label, "Play")
        app.terminate()
    }
    #endif
    @MainActor func testWholePlayerAppearanceAndFocus() {
        let app = application(); app.launch()
        for mode in ["dark", "light", "system"] {
            activate(app.buttons["customize"])
            activate(app.buttons["appearance-" + mode])
            dismissPanel(in: app)
            XCTAssertTrue(app.buttons["playPause"].exists)
            #if os(tvOS)
            activate(app.buttons["playPause"])
            XCTAssertTrue(app.buttons["playPause"].hasFocus)
            XCTAssertGreaterThanOrEqual(app.buttons["playPause"].frame.width, 96)
            #endif
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "Player appearance " + mode
            shot.lifetime = .keepAlways
            add(shot)
        }
        app.terminate()
    }

    @MainActor func testBackgroundPlaybackEnabledAndDisabled() {
        for enabled in [true, false] {
            let app = application()
            app.launchEnvironment["CADENZA_SYSTEM_PLAYBACK"] = enabled ? "1" : "0"
            app.launch()
            activate(app.buttons["queue"])
            activate(app.buttons["queue-track-0"])
            waitLabel("Pause", on: app.buttons["playPause"])
            // Tracks last 24 seconds. Return after EOF and require measurable
            // progress in track 2, proving it started while the app was hidden.
            #if os(macOS)
            app.typeKey("h", modifierFlags: .command)
            #elseif os(tvOS)
            XCUIRemote.shared.press(.home)
            #else
            XCUIDevice.shared.press(.home)
            #endif
            let elapsed = expectation(description: "Background audio interval")
            DispatchQueue.main.asyncAfter(deadline: .now() + (enabled ? 30 : 4)) { elapsed.fulfill() }
            XCTAssertEqual(XCTWaiter.wait(for: [elapsed], timeout: 35), .completed)
            app.activate()
            waitLabel(enabled ? "Pause" : "Play", on: app.buttons["playPause"])
            assertTitle(enabled ? "Soft geometry" : "After the light", in: app)
            let timer = app.staticTexts["elapsed-time"]
            #if os(macOS)
            let initial = timer.value as? String ?? timer.label
            let key = "value"
            #else
            let initial = timer.label
            let key = "label"
            #endif
            if enabled {
                let seconds = initial.split(separator: ":").compactMap { Int($0) }
                XCTAssertEqual(seconds.count, 2)
                XCTAssertGreaterThanOrEqual(seconds[0] * 60 + seconds[1], 4, "Track 2 must have advanced before foregrounding")
                let advancing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "%K != %@", key, initial), object: timer)
                XCTAssertEqual(XCTWaiter.wait(for: [advancing], timeout: 4), .completed)
            } else {
                activate(app.buttons["playPause"])
                waitLabel("Pause", on: app.buttons["playPause"])
            }
            app.terminate()
        }
    }

    override func setUpWithError() throws { continueAfterFailure = false }
    @MainActor func application(language: String = "en") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleInterfaceStyle", "Light", "-AppleLanguages", "(\(language))", "-AppleLocale", language]
        return app
    }

    @MainActor func testGermanControls() {
        let app = application(language: "de")
        app.launchArguments[1] = "Dark"
        app.launch()
        XCTAssertTrue(app.buttons["playPause"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons["playPause"].label, "Wiedergabe")
        #if os(macOS)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        #else
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        #endif
        screenshot.name = "German player"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
    }

    @MainActor func assertTitle(_ title: String, in app: XCUIApplication) {
        // AppKit exposes static text through value; UIKit exposes label.
        let match = NSPredicate(format: "label == %@ OR value == %@", title, title)
        let expectation = XCTNSPredicateExpectation(predicate: match, object: app.staticTexts["current-title"])
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }

    @MainActor func testCacheFailureIsVisible() {
        let app = application()
        app.launchEnvironment["CADENZA_DEMO_CACHE_DIRECTORY"] = "/dev/null/cadenza"
        app.launch()
        XCTAssertTrue(app.staticTexts["Unable to open demo"].waitForExistence(timeout: 15))
        app.terminate()
    }

    @MainActor func activate(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 15))
        #if !os(tvOS)
        // Customize is intentionally scrollable as host options grow. Exercise
        // real scrolling before requiring an offscreen control to be hittable.
        for _ in 0..<5 where !element.isHittable {
            guard let scroll = XCUIApplication().scrollViews.allElementsBoundByIndex.last(where: { $0.isHittable }) else { break }
            let above = element.frame.maxY < scroll.frame.minY
            #if os(macOS)
            scroll.scroll(byDeltaX: 0, deltaY: above ? 240 : -240)
            #else
            if above { scroll.swipeDown() } else { scroll.swipeUp() }
            #endif
        }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true AND isEnabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        #endif
        #if os(macOS)
        element.click()
        #elseif os(tvOS)
        var attempts: [String: Int] = [:]
        for _ in 0..<80 {
            if element.hasFocus { break }
            guard let focused = (XCUIApplication().buttons.allElementsBoundByIndex + XCUIApplication().switches.allElementsBoundByIndex + XCUIApplication().textFields.allElementsBoundByIndex).first(where: { $0.hasFocus }) else {
                XCTFail("No focused TV control"); return
            }
            let dx = element.frame.midX - focused.frame.midX
            let dy = element.frame.midY - focused.frame.midY
            let primary: XCUIRemote.Button = abs(dx) > abs(dy) ? (dx > 0 ? .right : .left) : (dy > 0 ? .down : .up)
            let directions: [XCUIRemote.Button] = [primary, .down, .left, .right, .up]
            let key = focused.identifier + focused.label
            let direction = directions.min { attempts[key + String(describing: $0), default: 0] < attempts[key + String(describing: $1), default: 0] }!
            attempts[key + String(describing: direction), default: 0] += 1
            XCUIRemote.shared.press(direction)
        }
        guard element.hasFocus else { XCTFail("Cannot focus \(element.identifier)"); return }
        XCUIRemote.shared.press(.select)
        #else
        element.tap()
        #endif
    }

    @MainActor func dismissPanel(in app: XCUIApplication) {
        #if os(tvOS)
        XCUIRemote.shared.press(.menu)
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["done"])
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
        #else
        activate(app.buttons["done"])
        #endif
    }

    @MainActor func waitLabel(_ label: String, on element: XCUIElement) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@ OR value == %@", label, label), object: element)], timeout: 10), .completed)
    }

    @MainActor func testPlaybackQueueModesAndDurableResume() {
        let app = application()
        app.launch()
        activate(app.buttons["queue"])
        activate(app.buttons["queue-track-0"])
        waitLabel("Pause", on: app.buttons["playPause"])
        #if os(tvOS)
        XCUIRemote.shared.press(.playPause)
        waitLabel("Play", on: app.buttons["playPause"])
        XCUIRemote.shared.press(.playPause)
        waitLabel("Pause", on: app.buttons["playPause"])
        #endif
        activate(app.buttons["playPause"])
        waitLabel("Play", on: app.buttons["playPause"])
        activate(app.buttons["customize"])
        activate(app.buttons["seek-forward"])
        dismissPanel(in: app)
        activate(app.buttons["queue"])
        activate(app.buttons["save"])
        XCTAssertTrue(app.staticTexts["Position saved. It will be here next time."].waitForExistence(timeout: 5))
        dismissPanel(in: app)
        activate(app.buttons["shuffle"])
        XCTAssertTrue(app.buttons["shuffle"].label.contains("on"))
        activate(app.buttons["shuffle"])
        activate(app.buttons["repeatMode"])
        XCTAssertTrue(app.buttons["repeatMode"].label.contains("all"))
        activate(app.buttons["next"])
        assertTitle("Soft geometry", in: app)
        activate(app.buttons["previous"])
        assertTitle("After the light", in: app)
        activate(app.buttons["queue"])
        activate(app.buttons["stop"])
        app.terminate()
        app.launch()
        activate(app.buttons["queue"])
        activate(app.buttons["resume"])
        waitLabel("Pause", on: app.buttons["playPause"])
        assertTitle("After the light", in: app)
        activate(app.buttons["queue"])
        activate(app.buttons["stop"])
    }

    @MainActor func testEqualizerControlsAndCompactToolbar() {
        let app = application()
        app.launch()
        let customize = app.buttons["customize"]
        XCTAssertTrue(customize.waitForExistence(timeout: 10))
        #if os(iOS)
        XCTAssertLessThan(customize.frame.height, 60, "Toolbar labels must not wrap into a tall pill")
        #endif
        let toolbar = XCTAttachment(screenshot: app.screenshot())
        toolbar.name = "Demo toolbar"; toolbar.lifetime = .keepAlways; add(toolbar)
        activate(app.buttons["equalizer"])
        waitLabel("Equalizer bypassed", on: app.staticTexts["sound-state"])
        activate(app.buttons["warm-bass"])
        waitLabel("Equalizer enabled", on: app.staticTexts["sound-state"])
        waitLabel("4 dB", on: app.staticTexts["eq-120-value"])
        activate(app.buttons["eq-120-increase"])
        waitLabel("5 dB", on: app.staticTexts["eq-120-value"])
        activate(app.buttons["eq-preamp-decrease"])
        waitLabel("-5 dB", on: app.staticTexts["eq-preamp-value"])
        activate(app.buttons["eq-120-decrease"])
        waitLabel("4 dB", on: app.staticTexts["eq-120-value"])
        activate(app.buttons["eq-preamp-increase"])
        waitLabel("-4 dB", on: app.staticTexts["eq-preamp-value"])
        let equalizer = XCTAttachment(screenshot: app.screenshot())
        equalizer.name = "Equalizer controls"; equalizer.lifetime = .keepAlways; add(equalizer)
        activate(app.buttons["bypass"])
        waitLabel("Equalizer bypassed", on: app.staticTexts["sound-state"])
        dismissPanel(in: app)
        activate(app.buttons["equalizer"])
        waitLabel("4 dB", on: app.staticTexts["eq-120-value"])
    }

    @MainActor func testLayoutCustomizationAndEqualizer() {
        let app = application()
        app.launch()
        activate(app.buttons["queue"])
        activate(app.buttons["queue-track-0"])
        activate(app.buttons["playPause"])
        waitLabel("Play", on: app.buttons["playPause"])
        activate(app.buttons["layout-empty"])
        XCTAssertFalse(app.buttons["playPause"].exists)
        activate(app.buttons["layout-default"])
        assertTitle("After the light", in: app)
        waitLabel("Play", on: app.buttons["playPause"])
        #if os(macOS)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        #else
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        #endif
        screenshot.name = "Default player"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        activate(app.buttons["customize"])
        activate(app.buttons["larger-title"])
        activate(app.buttons["Smaller title"])
        activate(app.buttons["Orange"])
        activate(app.buttons["Green"])
        activate(app.buttons["accent-indigo"])
        activate(app.descendants(matching: .any)["custom-assets"].firstMatch)
        activate(app.descendants(matching: .any)["custom-labels"].firstMatch)
        dismissPanel(in: app)
        waitLabel("Start listening", on: app.buttons["playPause"])
        activate(app.buttons["playPause"])
        waitLabel("Take a break", on: app.buttons["playPause"])
        activate(app.buttons["playPause"])
        activate(app.buttons["customize"])
        activate(app.descendants(matching: .any)["custom-buttons"].firstMatch)
        dismissPanel(in: app)
        activate(app.buttons["playPause"])
        waitLabel("Take a break", on: app.buttons["playPause"])
        activate(app.buttons["playPause"])
        activate(app.buttons["customize"])
        activate(app.buttons["reset-appearance"])
        activate(app.buttons["settings-shuffle"])
        activate(app.buttons["settings-repeat"])
        dismissPanel(in: app)
        waitLabel("Play", on: app.buttons["playPause"])
        activate(app.buttons["equalizer"])
        activate(app.buttons["warm-bass"])
        waitLabel("Equalizer enabled", on: app.staticTexts["sound-state"])
        activate(app.buttons["bypass"])
        waitLabel("Equalizer bypassed", on: app.staticTexts["sound-state"])
        activate(app.buttons["done"])
        app.terminate()
    }
    #if os(macOS)
    @MainActor func testNativeSystemNowPlayingControls() {
        let app = application(); app.launch()
        activate(app.buttons["playPause"])
        waitLabel("Pause", on: app.buttons["playPause"])
        let center = XCUIApplication(bundleIdentifier: "com.apple.controlcenter")
        center.statusItems["com.apple.menuextra.now-playing"].click()
        let title = center.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", "After the light")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        guard let group = center.groups.containing(NSPredicate(format: "value BEGINSWITH %@", "After the light")).allElementsBoundByIndex.last else {
            XCTFail("Missing demo Now Playing group"); return
        }
        group.buttons["pause"].click()
        app.activate()
        waitLabel("Play", on: app.buttons["playPause"])
        app.terminate()
    }

    @MainActor func testMinimizedPlaybackRespectsFeatureFlag() {
        for enabled in [true, false] {
            let app = application()
            app.launchEnvironment["CADENZA_SYSTEM_PLAYBACK"] = enabled ? "1" : "0"
            app.launch()
            activate(app.buttons["playPause"])
            waitLabel("Pause", on: app.buttons["playPause"])
            app.typeKey("m", modifierFlags: .command)
            let interval = expectation(description: "Minimized playback")
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { interval.fulfill() }
            XCTAssertEqual(XCTWaiter.wait(for: [interval], timeout: 8), .completed)
            app.activate()
            activate(app.menuBars.menuBarItems["Window"])
            activate(app.menuBars.menuItems["CadenzaKit"])
            waitLabel(enabled ? "Pause" : "Play", on: app.buttons["playPause"])
            app.terminate()
        }
    }

    @MainActor func testLibraryNavigationAndSearch() {
        let app = application(); app.launch()
        activate(app.buttons["library"])
        activate(app.buttons["track-2"])
        assertTitle("Blue hour", in: app)
        activate(app.sliders.firstMatch)
        activate(app.buttons["collection"])
        activate(app.buttons["track-3"])
        assertTitle("Open windows", in: app)
        activate(app.buttons["sidebar-queue"])
        let search = app.textFields["search"]
        activate(search); search.typeText("Soft")
        XCTAssertFalse(app.buttons["queue-track-0"].exists)
        activate(app.buttons["queue-track-1"])
        assertTitle("Soft geometry", in: app)
        activate(app.buttons["sidebar-sound"])
        dismissPanel(in: app)
        activate(app.buttons["more"])
        activate(app.buttons["show-queue"])
        dismissPanel(in: app)
        activate(app.buttons["back"])
        activate(app.buttons["stop"])
        app.terminate()
    }
    #endif
}

extension ShowcaseTests {
    @MainActor func testLiveSpectrumFollowsPlaybackAndSoundPanel() {
        let app = application(); app.launch()
        let spectrum = app.descendants(matching: .any).matching(identifier: "audio-spectrum").firstMatch
        XCTAssertTrue(spectrum.waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(spectrum.frame.maxY, app.windows.firstMatch.frame.maxY, "Spectrum must fit in the visible player")
        waitLabel("Spectrum idle", on: app.staticTexts["spectrum-state"])
        activate(app.buttons["playPause"])
        waitLabel("Pause", on: app.buttons["playPause"])
        waitLabel("Live audio spectrum", on: app.staticTexts["spectrum-state"])
        let live = XCTAttachment(screenshot: app.screenshot())
        live.name = "Measured audio spectrum during playback"; live.lifetime = .keepAlways; add(live)
        activate(app.buttons["playPause"])
        waitLabel("Spectrum idle", on: app.staticTexts["spectrum-state"])
        activate(app.buttons["equalizer"])
        XCTAssertTrue(spectrum.exists)
        activate(app.buttons["warm-bass"])
        waitLabel("Equalizer enabled", on: app.staticTexts["sound-state"])
        dismissPanel(in: app)
        activate(app.buttons["playPause"])
        waitLabel("Live audio spectrum", on: app.staticTexts["spectrum-state"])
        activate(app.buttons["queue"])
        activate(app.buttons["stop"])
        waitLabel("Spectrum idle", on: app.staticTexts["spectrum-state"])
    }
}

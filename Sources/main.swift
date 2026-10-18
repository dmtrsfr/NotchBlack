// NotchBlack — a tiny TopNotch-style app.
// Copies your wallpaper with a black strip the height of the menu bar and sets
// that copy as your desktop picture, so the notch blends into a black menu bar.

import AppKit
import ApplicationServices
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let toggleItem = NSMenuItem(title: "Hide Notch", action: #selector(toggleHide), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
    private let infoItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let cornersItem = NSMenuItem(title: "Round Corners", action: nil, keyEquivalent: "")
    private let cornerSizes: [(String, CGFloat)] = [("Off", 0), ("Small", 8), ("Medium", 12), ("Large", 18)]
    private var cornerWindows: [NSWindow] = []
    private var cornerSignature = ""
    private let menusItem = NSMenuItem(title: "Hide App Menus", action: #selector(toggleMenus), keyEquivalent: "")
    private let axItem = NSMenuItem(title: "", action: #selector(openAccessibility), keyEquivalent: "")
    private var lastIconCount = -1
    private let iconsItem = NSMenuItem(title: "Hide Menu Bar Icons", action: #selector(toggleIcons), keyEquivalent: "")
    private var menuCovers: [(window: NSWindow, bar: NSRect, screen: NSScreen, side: Side)] = []
    private var menuCoverSignature = ""
    private var hoverTimer: Timer?
    private var menuBarOwnerObservation: NSKeyValueObservation?
    private var timer: Timer?
    private var failed: [String: String] = [:] // screen key -> wallpaper path we couldn't read
    private let defaults = UserDefaults.standard

    private var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }

    private var cornerRadius: CGFloat {
        get { CGFloat(defaults.object(forKey: "cornerRadius") as? Double ?? 12) }
        set { defaults.set(Double(newValue), forKey: "cornerRadius") }
    }

    private var hideMenus: Bool {
        get { defaults.bool(forKey: "hideMenus") }
        set { defaults.set(newValue, forKey: "hideMenus") }
    }

    private var hideIcons: Bool {
        get { defaults.bool(forKey: "hideIcons") }
        set { defaults.set(newValue, forKey: "hideIcons") }
    }

    /// generated file path -> original wallpaper path
    private var originals: [String: String] {
        get { defaults.dictionary(forKey: "originals") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "originals") }
    }

    private let outputDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("NotchBlack", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            if let img = NSImage(systemSymbolName: "rectangle.tophalf.filled", accessibilityDescription: "NotchBlack") {
                img.isTemplate = true
                button.image = img
            } else {
                button.title = "▀"
            }
        }

        let menu = NSMenu()
        menu.delegate = self
        toggleItem.target = self
        loginItem.target = self
        infoItem.isEnabled = false
        let cornersMenu = NSMenu()
        for (i, (title, _)) in cornerSizes.enumerated() {
            let item = NSMenuItem(title: title, action: #selector(pickCorners(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            cornersMenu.addItem(item)
        }
        cornersItem.submenu = cornersMenu

        menu.addItem(toggleItem)
        menu.addItem(cornersItem)
        menusItem.target = self
        menu.addItem(menusItem)
        iconsItem.target = self
        menu.addItem(iconsItem)
        axItem.target = self
        menu.addItem(axItem)
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(infoItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit NotchBlack", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(somethingChanged(_:)), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        ws.addObserver(self, selector: #selector(somethingChanged(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(frontAppChanged(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(somethingChanged(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // Catch wallpaper changes made in System Settings.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }

        refresh()

        menuBarOwnerObservation = NSWorkspace.shared.observe(\.menuBarOwningApplication) { [weak self] _, _ in
            DispatchQueue.main.async { self?.frontAppChanged(Notification(name: .init("menuBarOwner"))) }
        }

        if hideMenus || hideIcons { askForAccessibility() }
    }

    func menuWillOpen(_ menu: NSMenu) {
        toggleItem.state = enabled ? .on : .off
        cornersItem.isEnabled = enabled
        menusItem.isEnabled = enabled
        menusItem.state = hideMenus ? .on : .off
        iconsItem.isEnabled = enabled
        iconsItem.state = hideIcons ? .on : .off
        if AXIsProcessTrusted() {
            axItem.title = lastIconCount >= 0 ? "Accessibility: on · \(lastIconCount) icons found" : "Accessibility: on"
        } else {
            axItem.title = "Accessibility: off, click to fix"
        }
        for item in cornersItem.submenu?.items ?? [] {
            item.state = cornerSizes[item.tag].1 == cornerRadius ? .on : .off
        }
        let status = SMAppService.mainApp.status
        loginItem.state = status == .enabled ? .on : .off
        loginItem.title = status == .requiresApproval ? "Launch at Login (approve in System Settings)" : "Launch at Login"
    }

    @objc private func somethingChanged(_ n: Notification) {
        // Give macOS a moment to settle after a space switch / display change.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.refresh() }
    }

    // MARK: - Menu actions

    @objc private func toggleHide() {
        enabled.toggle()
        failed.removeAll()
        refresh()
    }

    @objc private func toggleMenus() {
        hideMenus.toggle()
        if hideMenus { askForAccessibility() }
        updateMenuCovers()
    }

    @objc private func toggleIcons() {
        hideIcons.toggle()
        if hideIcons { askForAccessibility() }
        updateMenuCovers()
    }

    @objc private func pickCorners(_ sender: NSMenuItem) {
        cornerRadius = cornerSizes[sender.tag].1
        updateCorners()
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled: try service.unregister()
            case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
            default: try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = "Move NotchBlack to your Applications folder and try again.\n\n\(error.localizedDescription)"
            alert.runModal()
        }
    }

    // MARK: - Core

    private func refresh() {
        updateCorners()
        updateMenuCovers()
        layoutMenuCovers() // catches menus that change while an app is open
        var problem = false
        let ws = NSWorkspace.shared

        for screen in NSScreen.screens {
            guard screen.safeAreaInsets.top > 0 else { continue } // only screens with a notch
            guard let current = ws.desktopImageURL(for: screen) else { continue }
            let key = screenKey(screen)
            let size = pixelSize(screen)
            let sizeTag = "-\(size.w)x\(size.h)-"

            if enabled {
                var source = current
                if isGenerated(current) {
                    // Already ours. Redo it only if the resolution changed.
                    if current.lastPathComponent.contains(sizeTag) { continue }
                    guard let orig = originals[current.path] else { continue }
                    source = URL(fileURLWithPath: orig)
                }
                if failed[key] == source.path { problem = true; continue }

                if let out = render(original: source, screen: screen, key: key) {
                    var map = originals
                    map[out.path] = source.path
                    originals = map
                    setWallpaper(out, on: screen)
                    failed[key] = nil
                } else {
                    failed[key] = source.path
                    problem = true
                }
            } else if isGenerated(current), let orig = originals[current.path],
                      FileManager.default.fileExists(atPath: orig) {
                setWallpaper(URL(fileURLWithPath: orig), on: screen)
            }
        }

        if problem {
            infoItem.title = "Can't read this wallpaper, pick a regular image"
        } else {
            infoItem.title = enabled ? "Menu bar is black" : "Off"
        }
    }

    private func render(original: URL, screen: NSScreen, key: String) -> URL? {
        guard let src = NSImage(contentsOf: original) else { return nil }

        // Use the image's real pixel size, not its point size.
        var sw = src.size.width, sh = src.size.height
        if let best = src.representations.max(by: { $0.pixelsWide < $1.pixelsWide }), best.pixelsWide > 0 {
            sw = CGFloat(best.pixelsWide); sh = CGFloat(best.pixelsHigh)
        }
        guard sw > 0, sh > 0 else { return nil }

        let (w, h) = pixelSize(screen)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: w, height: h) // draw in pixel units

        NSGraphicsContext.saveGraphicsState()
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState(); return nil
        }
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high

        let canvas = NSRect(x: 0, y: 0, width: w, height: h)
        NSColor.black.setFill()
        canvas.fill()

        // Fill the screen like macOS does by default (scale to fill, centered).
        let s = max(CGFloat(w) / sw, CGFloat(h) / sh)
        let dw = sw * s, dh = sh * s
        src.draw(in: NSRect(x: (CGFloat(w) - dw) / 2, y: (CGFloat(h) - dh) / 2, width: dw, height: dh),
                 from: .zero, operation: .copy, fraction: 1)

        // The black strip. +1pt so there's never a hairline of wallpaper showing.
        let bar = (menuBarHeight(screen) + 1) * screen.backingScaleFactor
        NSColor.black.setFill()
        NSRect(x: 0, y: CGFloat(h) - bar, width: CGFloat(w), height: bar).fill()

        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        // Unique name every time; macOS caches wallpapers by URL.
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let out = outputDir.appendingPathComponent("\(key)-\(w)x\(h)-\(stamp).png")
        do { try data.write(to: out) } catch { return nil }
        prune()
        return out
    }

    private func setWallpaper(_ url: URL, on screen: NSScreen) {
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
            .allowClipping: true,
        ]
        try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
    }

    /// Keep the 30 newest generated images (each Space can use one).
    private func prune() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: outputDir, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a > b
        }
        guard sorted.count > 30 else { return }
        var map = originals
        for old in sorted.dropFirst(30) {
            try? fm.removeItem(at: old)
            map[old.path] = nil
        }
        originals = map
    }

    // MARK: - Rounded corners

    /// Small click-through black windows that round off the area just below the menu bar.
    private func updateCorners() {
        let r = enabled ? cornerRadius : 0
        let screens = NSScreen.screens.filter { $0.safeAreaInsets.top > 0 }
        let sig = "\(r)|" + screens.map { "\($0.frame)|\(menuBarHeight($0))" }.joined(separator: ";")
        guard sig != cornerSignature else { return }
        cornerSignature = sig

        cornerWindows.forEach { $0.orderOut(nil) }
        cornerWindows.removeAll()
        guard r > 0 else { return }

        for screen in screens {
            let top = screen.frame.maxY - menuBarHeight(screen)
            for left in [true, false] {
                let x = left ? screen.frame.minX : screen.frame.maxX - r
                let w = NSWindow(contentRect: NSRect(x: x, y: top - r, width: r, height: r),
                                 styleMask: .borderless, backing: .buffered, defer: false)
                w.isOpaque = false
                w.backgroundColor = .clear
                w.hasShadow = false
                w.ignoresMouseEvents = true
                w.isReleasedWhenClosed = false
                w.level = .statusBar
                // All desktops, but not inside full-screen apps (no menu bar there).
                w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
                w.contentView = CornerView(radius: r, left: left)
                w.orderFrontRegardless()
                cornerWindows.append(w)
            }
        }
    }

    // MARK: - Hide app menus and menu bar icons

    private enum Side { case left, right }

    /// Black, click-through strips in the menu bar:
    /// left  = over the app menus (File, Edit…), between the app name and the notch;
    /// right = over the menu bar icons, between the notch and Control Center/clock.
    /// Each one fades out while the pointer is in the menu bar on its side of the notch.
    private func updateMenuCovers() {
        var sides: [Side] = []
        if enabled && hideMenus { sides.append(.left) }
        if enabled && hideIcons { sides.append(.right) }
        let screens = NSScreen.screens.filter { $0.safeAreaInsets.top > 0 }
        let sig = "\(sides)|" + screens.map { "\($0.frame)|\(menuBarHeight($0))" }.joined(separator: ";")
        guard sig != menuCoverSignature else { return }
        menuCoverSignature = sig

        menuCovers.forEach { $0.window.orderOut(nil) }
        menuCovers.removeAll()
        hoverTimer?.invalidate()
        hoverTimer = nil
        guard !sides.isEmpty else { return }

        for screen in screens {
            let h = menuBarHeight(screen)
            let bar = NSRect(x: screen.frame.minX, y: screen.frame.maxY - h, width: screen.frame.width, height: h)
            for side in sides {
                let rect = menuCoverRect(screen: screen, bar: bar, side: side)
                let w = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
                w.isOpaque = true
                w.backgroundColor = .black
                w.hasShadow = false
                w.ignoresMouseEvents = true // clicks still reach what's underneath
                w.isReleasedWhenClosed = false
                // Just above the menu bar; open menus draw higher still, so they stay visible.
                w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
                w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
                w.orderFrontRegardless()
                menuCovers.append((w, bar, screen, side))
            }
        }

        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let p = NSEvent.mouseLocation
            for cover in self.menuCovers {
                let inBar = cover.bar.insetBy(dx: 0, dy: -2).contains(p)
                let onSide: Bool
                switch cover.side {
                case .left:
                    onSide = p.x < (cover.screen.auxiliaryTopLeftArea?.maxX ?? cover.bar.midX)
                case .right:
                    onSide = p.x > (cover.screen.auxiliaryTopRightArea?.minX ?? cover.bar.midX)
                }
                let target: CGFloat = (inBar && onSide) ? 0 : 1
                if cover.window.alphaValue != target {
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.15
                        cover.window.animator().alphaValue = target
                    }
                }
            }
        }
    }

    private func axFrame(_ el: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        guard size.width > 0 else { return nil }
        return CGRect(origin: pos, size: size)
    }

    private func axChildren(_ el: AXUIElement, _ attr: String) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return [] }
        var kidsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ref as! AXUIElement, kAXChildrenAttribute as CFString, &kidsRef) == .success
        else { return [] }
        return kidsRef as? [AXUIElement] ?? []
    }

    /// Where the first real menu (File, etc.) begins, read from the frontmost app via Accessibility.
    /// Returns nil without Accessibility permission.
    private func firstMenuX() -> CGFloat? {
        guard AXIsProcessTrusted(), let app = menuBarApp() else { return nil }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 0.2)
        let items = axChildren(el, kAXMenuBarAttribute)
        // items[0] = Apple menu, items[1] = app name menu. Cover from the end of the app name menu.
        guard items.count > 1, let f = axFrame(items[1]) else { return nil }
        return f.maxX
    }

    /// Left edge of the Control Center and clock icons, read via Accessibility.
    private func keepIconsX(bar: NSRect) -> CGFloat? {
        guard AXIsProcessTrusted(),
              let cc = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first
        else { return nil }
        let el = AXUIElementCreateApplication(cc.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 0.2)
        let frames = axChildren(el, "AXExtrasMenuBar")
            .compactMap { axFrame($0) }
            .filter { $0.midX > bar.minX && $0.midX < bar.maxX }
        // The clock is always rightmost and Control Center sits just left of it: keep exactly those two.
        lastIconCount = frames.count
        let keep = frames.sorted { $0.minX > $1.minX }.prefix(2)
        return keep.map(\.minX).min()
    }

    private func menuCoverRect(screen: NSScreen, bar: NSRect, side: Side) -> NSRect {
        switch side {
        case .left:
            // Estimate from the app name's text width; never start the strip before this,
            // so the app name can't be covered.
            let nameStart: CGFloat = 53 // where the app name begins, after the Apple logo
            let name = menuBarApp()?.localizedName ?? ""
            let base = NSFont.menuBarFont(ofSize: 0)
            let bold = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
            let nameWidth = ceil((name as NSString).size(withAttributes: [.font: bold]).width)
            let estimate = bar.minX + nameStart + nameWidth + 10
            var start = estimate
            if let x = firstMenuX(), x > bar.minX, x < bar.maxX {
                start = max(x, bar.minX + nameStart + nameWidth + 2)
            }
            let notchLeft = screen.auxiliaryTopLeftArea?.maxX ?? screen.frame.midX
            return NSRect(x: start, y: bar.minY, width: max(0, notchLeft - start), height: bar.height)
        case .right:
            let notchRight = screen.auxiliaryTopRightArea?.minX ?? screen.frame.midX
            // Fallback without Accessibility: leave just Control Center and the clock showing.
            let end = (keepIconsX(bar: bar) ?? (bar.maxX - 80)) - 2
            return NSRect(x: notchRight, y: bar.minY, width: max(0, end - notchRight), height: bar.height)
        }
    }

    @objc private func frontAppChanged(_ n: Notification) {
        layoutMenuCovers()
        // The new app's menus can take a moment to appear; measure again shortly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.layoutMenuCovers() }
    }

    private func layoutMenuCovers() {
        for cover in menuCovers {
            let r = menuCoverRect(screen: cover.screen, bar: cover.bar, side: cover.side)
            if cover.window.frame != r { cover.window.setFrame(r, display: true) }
        }
    }

    @objc private func openAccessibility() {
        askForAccessibility()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The app whose name and menus are in the menu bar. Screen recorders and other
    /// background apps can be "active" without owning the menu bar.
    private func menuBarApp() -> NSRunningApplication? {
        NSWorkspace.shared.menuBarOwningApplication ?? NSWorkspace.shared.frontmostApplication
    }

    private func askForAccessibility() {
        guard !AXIsProcessTrusted() else { return }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: - Helpers

    private func isGenerated(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(outputDir.standardizedFileURL.path)
    }

    private func menuBarHeight(_ screen: NSScreen) -> CGFloat {
        max(screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY)
    }

    private func pixelSize(_ screen: NSScreen) -> (w: Int, h: Int) {
        let s = screen.backingScaleFactor
        return (Int((screen.frame.width * s).rounded()), Int((screen.frame.height * s).rounded()))
    }

    private func screenKey(_ screen: NSScreen) -> String {
        let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return "display\(n?.uint32Value ?? 0)"
    }
}

/// Draws the black fillet for one corner (the square minus a quarter circle).
final class CornerView: NSView {
    private let radius: CGFloat
    private let left: Bool

    init(radius: CGFloat, left: Bool) {
        self.radius = radius
        self.left = left
        super.init(frame: NSRect(x: 0, y: 0, width: radius, height: radius))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = radius
        let p = NSBezierPath()
        if left {
            p.move(to: NSPoint(x: 0, y: 0))
            p.line(to: NSPoint(x: 0, y: r))
            p.line(to: NSPoint(x: r, y: r))
            p.appendArc(withCenter: NSPoint(x: r, y: 0), radius: r, startAngle: 90, endAngle: 180, clockwise: false)
        } else {
            p.move(to: NSPoint(x: r, y: 0))
            p.line(to: NSPoint(x: r, y: r))
            p.line(to: NSPoint(x: 0, y: r))
            p.appendArc(withCenter: NSPoint(x: 0, y: 0), radius: r, startAngle: 90, endAngle: 0, clockwise: true)
        }
        p.close()
        NSColor.black.setFill()
        p.fill()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
app.run()

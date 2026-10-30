// HDRSwitch — 一键开关外接显示器 HDR
// 菜单栏小工具：点击图标即切换 HDR；⌃⌥H 全局快捷键；支持命令行调用。

import AppKit
import Carbon.HIToolbox
import ServiceManagement

// MARK: - SkyLight 私有接口

private let slHandle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

private func loadSym<T>(_ name: String, _ type: T.Type) -> T? {
    guard let h = slHandle, let p = dlsym(h, name) else { return nil }
    return unsafeBitCast(p, to: T.self)
}

typealias HDRSupportsFn = @convention(c) (CGDirectDisplayID) -> Bool
typealias HDRStateFn    = @convention(c) (CGDirectDisplayID) -> Bool
typealias HDRSetFn      = @convention(c) (CGDirectDisplayID, Bool) -> Int32

enum HDR {
    static let supportsFn: HDRSupportsFn? = loadSym("CoreDisplay_Display_SupportsHDRMode", HDRSupportsFn.self)
    static let stateFn: HDRStateFn?       = loadSym("CoreDisplay_Display_IsHDRModeEnabled", HDRStateFn.self)
    static let setFn: HDRSetFn?           = loadSym("SLSDisplaySetHDRModeEnabled", HDRSetFn.self)

    static var available: Bool { supportsFn != nil && stateFn != nil && setFn != nil }

    static func supports(_ d: CGDirectDisplayID) -> Bool { supportsFn?(d) ?? false }
    static func isOn(_ d: CGDirectDisplayID) -> Bool { stateFn?(d) ?? false }

    @discardableResult
    static func set(_ d: CGDirectDisplayID, _ on: Bool) -> Bool {
        (setFn?(d, on) ?? 1) == 0
    }
}

// MARK: - 显示模式

struct ModeKey: Hashable, CustomStringConvertible {
    let w: Int, h: Int, pw: Int, ph: Int, hz: Int

    init(_ m: CGDisplayMode) {
        w  = m.width
        h  = m.height
        pw = m.pixelWidth
        ph = m.pixelHeight
        hz = Int(m.refreshRate.rounded())
    }

    init?(string: String) {
        let parts = string.split(separator: "|")
        guard parts.count == 3 else { return nil }
        let a = parts[0].split(separator: "x").compactMap { Int($0) }
        let b = parts[1].split(separator: "x").compactMap { Int($0) }
        guard a.count == 2, b.count == 2, let hz = Int(parts[2]) else { return nil }
        w = a[0]; h = a[1]; pw = b[0]; ph = b[1]; self.hz = hz
    }

    var string: String { "\(w)x\(h)|\(pw)x\(ph)|\(hz)" }

    /// 物理像素大于逻辑尺寸，说明是 HiDPI（视网膜缩放）模式
    var isHiDPI: Bool { pw > w }

    var description: String {
        "\(w)×\(h)" + (isHiDPI ? " Retina" : "") + " @\(hz)Hz"
    }
}

enum Displays {
    static func online() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    static func allModes(_ d: CGDirectDisplayID) -> [CGDisplayMode] {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let arr = CGDisplayCopyAllDisplayModes(d, opts) else { return [] }
        var out: [CGDisplayMode] = []
        for i in 0..<CFArrayGetCount(arr) {
            if let p = CFArrayGetValueAtIndex(arr, i) {
                out.append(unsafeBitCast(p, to: CGDisplayMode.self))
            }
        }
        return out
    }

    static func current(_ d: CGDirectDisplayID) -> CGDisplayMode? {
        CGDisplayCopyDisplayMode(d)
    }

    @discardableResult
    static func apply(_ d: CGDirectDisplayID, _ m: CGDisplayMode, scope: CGConfigureOption = .permanently) -> Bool {
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { return false }
        CGConfigureDisplayWithDisplayMode(cfg, d, m, nil)
        return CGCompleteDisplayConfiguration(cfg, scope) == .success
    }

    static func mode(_ key: ModeKey, of d: CGDirectDisplayID) -> CGDisplayMode? {
        allModes(d).first { ModeKey($0) == key }
    }

    static func name(_ d: CGDirectDisplayID) -> String {
        for s in NSScreen.screens {
            if let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
               n.uint32Value == d {
                return s.localizedName
            }
        }
        return "显示器 \(d)"
    }

    static func subtitle(_ d: CGDirectDisplayID) -> String {
        guard let m = current(d) else { return "未知模式" }
        return ModeKey(m).description
    }
}

// MARK: - 核心：HDR 切换

final class HDRManager {
    static let shared = HDRManager()

    private let queue = DispatchQueue(label: "com.wangjin.hdrswitch.serial")
    private let defaults = UserDefaults.standard

    private func highRefreshKey(_ d: CGDirectDisplayID) -> String { "highRefresh.\(d)" }
    private func hdrModeKey(_ d: CGDirectDisplayID) -> String { "hdrMode.\(d)" }

    var isBusy = false
    func savedHighRefresh(_ d: CGDirectDisplayID) -> ModeKey? {
        defaults.string(forKey: highRefreshKey(d)).flatMap(ModeKey.init(string:))
    }

    /// 切换耗时分段记录（只在 debugLog 打开时写日志，用来判断黑屏时间花在哪一段）
    private var traceStart = CFAbsoluteTimeGetCurrent()
    private var trace: [String] = []
    private func mark(_ label: String) {
        trace.append("\(label) \(Int((CFAbsoluteTimeGetCurrent() - traceStart) * 1000))ms")
    }

    func setHDR(_ on: Bool, display d: CGDirectDisplayID, completion: @escaping (Bool, String) -> Void) {
        queue.async {
            self.isBusy = true
            defer { self.isBusy = false }
            guard HDR.available else {
                completion(false, "当前系统不支持 HDR 控制接口")
                return
            }
            self.traceStart = CFAbsoluteTimeGetCurrent()
            self.trace = []
            let result = on ? self.turnOn(d) : self.turnOff(d)
            Log.write("切换耗时 \(Int((CFAbsoluteTimeGetCurrent() - self.traceStart) * 1000))ms · \(on ? "开" : "关") · \(self.trace.joined(separator: " → "))", force: true)
            completion(result.0, result.1)
        }
    }

    // MARK: 开启

    private func turnOn(_ d: CGDirectDisplayID) -> (Bool, String) {
        if HDR.isOn(d) { return (true, "HDR 已处于开启状态") }

        // 当前模式本身就支持 HDR，直接开
        if HDR.supports(d) {
            HDR.set(d, true)
            if waitFor(1.2, { HDR.isOn(d) }) {
                return (true, "HDR 已开启 · \(Displays.subtitle(d))")
            }
            return (false, "系统没有响应 HDR 开启请求")
        }

        // 需要先切到带宽允许 HDR 的显示模式
        guard let curMode = Displays.current(d) else { return (false, "无法读取当前显示模式") }
        let cur = ModeKey(curMode)
        defaults.set(cur.string, forKey: highRefreshKey(d))

        for m in candidateModes(d, cur: cur) {
            mark("候选模式")
            guard applyMode(d, m, settle: 0) else { continue }
            mark("模式已应用")

            // 关键：模式一落地就立刻请求 HDR，让「换模式」和「开 HDR」的黑屏叠成一次。
            // 以前这里是先等 HDR.supports 再开，等于等面板同步完再黑一次 —— 用户看到两次黑屏。
            HDR.set(d, true)
            if waitFor(0.35, { HDR.isOn(d) }) {
                mark("HDR 已确认")
                defaults.set(ModeKey(m).string, forKey: hdrModeKey(d))
                return (true, "HDR 已开启 · \(ModeKey(m).description)")
            }
            mark("HDR 未确认")

            // 没生效：等驱动认可这个模式支持 HDR，再补一两次
            guard waitFor(1.0, { HDR.supports(d) }) else { continue }
            for attempt in 0..<2 {
                HDR.set(d, true)
                if waitFor(1.0, { HDR.isOn(d) }) {
                    defaults.set(ModeKey(m).string, forKey: hdrModeKey(d))
                    return (true, "HDR 已开启 · \(ModeKey(m).description)")
                }
                if attempt == 0 { HDR.set(d, false); usleep(200_000) }
            }
        }

        // 全部失败，回滚原模式
        if let back = Displays.mode(cur, of: d) { _ = Displays.apply(d, back) }
        defaults.removeObject(forKey: highRefreshKey(d))
        return (false, "这台显示器在当前连接下无法开启 HDR（通常是非 Retina 低分辨率模式或带宽不足）")
    }

    // MARK: 关闭

    private func turnOff(_ d: CGDirectDisplayID) -> (Bool, String) {
        if !HDR.isOn(d) { return (true, "HDR 已处于关闭状态") }

        var message = "HDR 已关闭 · \(Displays.subtitle(d))"

        // 先切回高刷新率模式：那一档本身带不动 HDR，系统会连带把 HDR 关掉，
        // 一次黑屏就够。以前是「先关 HDR 等它生效，再换模式」—— 黑两次。
        var switched = false
        if let s = defaults.string(forKey: highRefreshKey(d)),
           let key = ModeKey(string: s),
           let m = Displays.mode(key, of: d),
           ModeKey(Displays.current(d) ?? m) != key {
            mark("切回高刷 前")
            if applyMode(d, m, settle: 0.05) {
                switched = true
                mark("高刷已恢复")
                message = "HDR 已关闭 · \(key.description)"
            } else {
                message = "HDR 已关闭（高刷新率未能恢复，可在系统设置里手动调）"
            }
        }

        // 换模式后 HDR 一般已经被系统收掉了；还开着就补一刀
        if HDR.isOn(d) || !switched {
            HDR.set(d, false)
            _ = waitFor(1.2, { !HDR.isOn(d) })
        }

        defaults.removeObject(forKey: highRefreshKey(d))
        return (true, message)
    }

    // MARK: 候选模式

    /// 开 HDR 前需要把显示模式换到「链路带宽允许 HDR」的那一档。
    /// 优先级：上次成功过的模式 > 同分辨率同 Retina > 同分辨率 > 同像素密度；刷新率从高到低。
    private func candidateModes(_ d: CGDirectDisplayID, cur: ModeKey) -> [CGDisplayMode] {
        let usable = Displays.allModes(d).filter { m in
            let k = ModeKey(m)
            return k.hz >= 24 && k.w >= 800 && k != cur
        }

        var ordered: [CGDisplayMode] = []
        var seen = Set<ModeKey>()
        func add(_ list: [CGDisplayMode]) {
            for m in list where seen.insert(ModeKey(m)).inserted {
                ordered.append(m)
            }
        }

        if let s = defaults.string(forKey: hdrModeKey(d)), let k = ModeKey(string: s) {
            add(usable.filter { ModeKey($0) == k })
        }
        add(usable.filter {
            let k = ModeKey($0)
            return k.w == cur.w && k.h == cur.h && k.pw == cur.pw && k.ph == cur.ph
        }.sorted { ModeKey($0).hz > ModeKey($1).hz })
        add(usable.filter {
            let k = ModeKey($0)
            return k.w == cur.w && k.h == cur.h && k.pw == cur.pw
        }.sorted { ModeKey($0).hz > ModeKey($1).hz })
        add(usable.filter {
            let k = ModeKey($0)
            return k.pw >= cur.pw && k.ph >= cur.ph
        }.sorted { (ModeKey($0).hz, ModeKey($0).pw) > (ModeKey($1).hz, ModeKey($1).pw) })

        return Array(ordered.prefix(6))
    }

    // MARK: 工具

    /// 切换显示模式并确认真的生效（macOS 偶尔会把模式弹回原样，必须校验）
    /// settle：模式生效后再多等多久才返回。切换 HDR 时传 0 —— 那点时间已经用来
    /// 立刻发 HDR 请求了，让两次黑屏合并成一次。
    private func applyMode(_ d: CGDirectDisplayID, _ m: CGDisplayMode, settle: Double = 0.3, tries: Int = 3) -> Bool {
        let key = ModeKey(m)
        for _ in 0..<tries {
            mark("apply 前")
            _ = Displays.apply(d, m)
            mark("apply 返回")
            if waitFor(1.2, {
                guard let cur = Displays.current(d) else { return false }
                return ModeKey(cur) == key
            }) {
                mark("模式确认")
                if settle > 0 { usleep(useconds_t(settle * 1_000_000)) }
                return true
            }
        }
        return false
    }

    @discardableResult
    private func waitFor(_ timeout: Double, _ cond: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            // 20ms 一轮：这些查询都是极轻的 SPI 调用，粗粒度轮询纯粹是在白等
            usleep(20_000)
        }
        return cond()
    }
}

// MARK: - 屏幕浮层提示

final class HUD {
    static let shared = HUD()
    private var window: NSPanel?

    func show(_ text: String) {
        window?.orderOut(nil)

        let width: CGFloat = 300, height: CGFloat = 68
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let box = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 0.9).cgColor
        box.layer?.cornerRadius = 16
        box.layer?.borderWidth = 0.5
        box.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.12).cgColor

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13.5, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 14, y: (height - 20) / 2, width: width - 28, height: 20)
        box.addSubview(label)

        panel.contentView = box

        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - width / 2, y: f.midY - height / 2))
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        window = panel

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak panel] in
            guard let panel = panel else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.4
                panel.animator().alphaValue = 0
            }, completionHandler: { panel.orderOut(nil) })
        }
    }
}

// MARK: - 菜单栏

var globalDelegate: AppDelegate?

func displayReconfigured(_ d: CGDirectDisplayID,
                         _ flags: CGDisplayChangeSummaryFlags,
                         _ ctx: UnsafeMutableRawPointer?) {
    DispatchQueue.main.async { globalDelegate?.refreshUI() }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var hotKeyRef: EventHotKeyRef?
    private var busy = false
    private let prefs = UserDefaults.standard

    private var activeDisplay: CGDirectDisplayID {
        get {
            if let n = prefs.object(forKey: "activeDisplay") as? NSNumber {
                let d = n.uint32Value
                if Displays.online().contains(d) { return d }
            }
            return CGMainDisplayID()
        }
        set {
            prefs.set(NSNumber(value: newValue), forKey: "activeDisplay")
            refreshUI()
        }
    }

    private var napToken: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 不用 LSUIElement（那会让 App 从 Launchpad 的图标列表里消失，只能靠搜索找到），
        // 改成启动后把激活策略设成 .accessory：一样没有 Dock 图标、不抢焦点、不进 ⌘Tab，
        // 但 Launchpad / 应用程序文件夹里能正常看到图标。
        NSApp.setActivationPolicy(.accessory)

        // 关键：菜单栏小工具在后台时会被 App Nap 限流，
        // 定时器会被压到一分钟甚至更久才触发一次 —— 表现为「看了半天才切 / 不切」。
        // 声明成用户发起的活动，保持轮询按 1 秒走。
        napToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "监听播放状态以自动切换 HDR")

        statusItem = NSStatusBar.system.statusItem(withLength: 32)
        statusItem.isVisible = true
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        CGDisplayRegisterReconfigurationCallback(displayReconfigured, nil)
        registerHotKey()
        // 先探一次「能不能读播放器窗口标题」：读得到就能分清「暂停」和「关掉片子」，
        // 读不到就退回按时间兜底（这一步在后台跑，不会拖慢启动）
        WindowProbe.warmUp()
        refreshUI()

        AutoHDR.shared.displayProvider = { [weak self] in self?.activeDisplay ?? CGMainDisplayID() }
        AutoHDR.shared.onChange = { [weak self] in self?.refreshUI() }
        if AutoHDR.shared.enabled { AutoHDR.shared.start() }

        // 播放器启动 / 退出 → 清掉它的历史判定。
        // 不清的话「上一场看的是 HDR 片」会留到下一次打开 App：一露头就被当成
        // 「暂停中」，屏幕直接跳 HDR（打开 Infuse 就变色的那个 bug）。
        let wsCenter = NSWorkspace.shared.notificationCenter
        for noteName in [NSWorkspace.didLaunchApplicationNotification,
                         NSWorkspace.didTerminateApplicationNotification] {
            wsCenter.addObserver(forName: noteName, object: nil, queue: .main) { note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication else { return }
                PlaybackWatcher.forget(bundleID: app.bundleIdentifier,
                                       name: app.localizedName ?? "")
            }
        }

        // 共享片源（本机 SMB）识别靠特权小工具读 smbd 的句柄，启动时记一笔便于排查
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            let title = SMBService.helperTitle()
            let ok = SMBService.hasAccess()
            Log.write("权限自检 · 共享识别=\(ok ? "可用" : "不可用") · \(title)", force: true)
        }

        // 网页画质探测要往浏览器发 Apple 事件。必须由 App 自己发（不能靠命令行试），
        // 因为系统是按「谁发起的」来判授权的。
        if WebProbe.enabled {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4) {
                let s = WebProbe.selfTest()
                Log.write("权限自检 · 网页探测=\(s)", force: true)
            }
        }
    }

    // MARK: 图标与状态

    /// 在「应用程序」里再次双击本 App：只提示当前状态，不擅自切换
    /// （以前这里是直接翻转 HDR，容易被误触，也不利于排查问题）
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let d = activeDisplay
        HUD.shared.show("HDR \(HDR.isOn(d) ? "已开启" : "已关闭") · \(Displays.subtitle(d))")
        refreshUI()
        return false
    }

    private func icon(on: Bool) -> NSImage {
        let size = NSSize(width: 30, height: 18)
        let img = NSImage(size: size)
        img.lockFocus()

        let alpha: CGFloat = on ? 1.0 : 0.45
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .heavy),
            .foregroundColor: NSColor.black.withAlphaComponent(alpha),
            .kern: -0.3
        ]
        let s = NSAttributedString(string: "HDR", attributes: attrs)
        let sz = s.size()
        let originY: CGFloat = on ? 4.0 : 3.5
        s.draw(at: NSPoint(x: (size.width - sz.width) / 2, y: originY))

        // 开启时在下方画一条指示条，状态一眼可辨
        if on {
            NSColor.black.setFill()
            let bar = NSRect(x: (size.width - 13) / 2, y: 1.4, width: 13, height: 1.6)
            NSBezierPath(roundedRect: bar, xRadius: 0.8, yRadius: 0.8).fill()
        }

        img.unlockFocus()
        img.isTemplate = true
        return img
    }

    func refreshUI() {
        let d = activeDisplay
        let isOn = HDR.isOn(d)
        if let button = statusItem?.button {
            button.image = icon(on: isOn && !busy)
            button.appearsDisabled = busy
            button.toolTip = "\(Displays.name(d))\nHDR \(isOn ? "已开启" : "已关闭") · \(Displays.subtitle(d))\n\(AutoHDR.shared.summary())"
        }
    }

    // MARK: 交互

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            toggleHDR(source: "click")
        }
    }

    func toggleHDR(source: String = "menu") {
        guard !busy else { return }
        let d = activeDisplay
        let target = !HDR.isOn(d)
        Log.write("toggleHDR source=\(source) -> \(target ? "on" : "off")")

        busy = true
        AutoHDR.shared.noteManualToggle()
        refreshUI()

        HDRManager.shared.setHDR(target, display: d) { ok, message in
            DispatchQueue.main.async {
                self.busy = false
                self.refreshUI()
                HUD.shared.show((ok ? "" : "⚠︎ ") + message)
            }
        }
    }

    private func showMenu() {
        statusItem.menu = buildMenu()
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    func buildMenu() -> NSMenu {
        let d = activeDisplay
        let isOn = HDR.isOn(d)
        let menu = NSMenu()

        let header = NSMenuItem(title: "\(Displays.name(d)) · \(isOn ? "HDR 已开启" : "HDR 已关闭")",
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let sub = NSMenuItem(title: "  当前 \(Displays.subtitle(d))", action: nil, keyEquivalent: "")
        sub.isEnabled = false
        menu.addItem(sub)

        menu.addItem(.separator())

        let toggle = NSMenuItem(title: isOn ? "关闭 HDR" : "开启 HDR",
                                action: #selector(menuToggle), keyEquivalent: "h")
        toggle.keyEquivalentModifierMask = [.control, .option]
        toggle.target = self
        menu.addItem(toggle)

        menu.addItem(.separator())

        // MARK: 自动切换

        let auto = AutoHDR.shared
        let autoItem = NSMenuItem(title: "播放 HDR 内容时自动开启", action: #selector(menuToggleAuto), keyEquivalent: "")
        autoItem.target = self
        autoItem.state = auto.enabled ? .on : .off
        menu.addItem(autoItem)

        let autoStatus = NSMenuItem(title: "  " + auto.summary(), action: nil, keyEquivalent: "")
        autoStatus.isEnabled = false
        menu.addItem(autoStatus)

        let autoOptions = NSMenu()
        let unknownItem = NSMenuItem(title: "播放器识别不到片源时也开 HDR", action: #selector(menuToggleUnknown), keyEquivalent: "")
        unknownItem.target = self
        unknownItem.state = auto.unknownAsHDR ? .on : .off
        autoOptions.addItem(unknownItem)

        let keepItem = NSMenuItem(title: "识别不到片源时保持已有 HDR（不自动关）", action: #selector(menuToggleKeepUnknown), keyEquivalent: "")
        keepItem.target = self
        keepItem.state = auto.keepUnknownPlayer ? .on : .off
        autoOptions.addItem(keepItem)

        let pausedItem = NSMenuItem(title: "暂停播放时保持 HDR（不退回 SDR）", action: #selector(menuToggleKeepPaused), keyEquivalent: "")
        pausedItem.target = self
        pausedItem.state = auto.keepPaused ? .on : .off
        autoOptions.addItem(pausedItem)

        // 「暂停」和「关掉片子」在系统信号里长得一样，唯一分得开的是播放界面 ——
        // 那需要屏幕录制权限。给了就能做到「关掉片子立刻回落」。
        let winOK = WindowProbe.titlesAvailable
        let winItem = NSMenuItem(
            title: winOK ? "暂停 / 停播识别：精确（读得到播放界面）"
                         : "暂停 / 停播识别：点击授权（分清「暂停」和「关掉片子」）",
            action: winOK ? nil : #selector(menuGrantScreenRecording),
            keyEquivalent: "")
        winItem.target = self
        winItem.isEnabled = !winOK
        autoOptions.addItem(winItem)

        let smbAccess = SMBService.hasAccess()
        let smbItem = NSMenuItem(
            title: smbAccess ? "共享片源识别：已就绪" : "共享片源识别：点击安装（读共享里的片源）",
            action: smbAccess ? nil : #selector(menuOpenFullDiskAccess),
            keyEquivalent: "")
        smbItem.target = self
        smbItem.isEnabled = !smbAccess
        autoOptions.addItem(smbItem)

        // 腾讯视频把画质判定写在自己的沙盒容器里，读它需要「完全磁盘访问权限」。
        // 没授权时菜单栏必须说清楚 —— 否则用户看到的就是「播了 HDR 片却毫无反应」，
        // 而命令行（继承终端权限）又是正常的，根本没线索。
        if NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == TencentVideoProbe.bundleID
        }) || FileManager.default.fileExists(atPath: "/Applications/QQLive.app") {
            let tvOK = TencentVideoProbe.canRead()
            let tvItem = NSMenuItem(
                title: tvOK ? "腾讯视频识别：已就绪"
                            : "腾讯视频识别：点击授权（读播放内核画质日志）",
                action: tvOK ? nil : #selector(menuOpenFullDiskAccess),
                keyEquivalent: "")
            tvItem.target = self
            tvItem.isEnabled = !tvOK
            autoOptions.addItem(tvItem)
        }

        // 读外置盘 / 网络卷上的片源会触发系统授权框，而授权跟着签名走 ——
        // 每次重新编译都要再点一遍。默认不读，靠文件名判定；需要精确时再打开。
        let extItem = NSMenuItem(
            title: MediaProbe.readExternal
                ? "读取外置卷片源信息：已开启（会请求磁盘授权）"
                : "读取外置卷片源信息：关闭（不弹磁盘授权，只按文件名判）",
            action: #selector(menuToggleReadExternal), keyEquivalent: "")
        extItem.target = self
        extItem.state = MediaProbe.readExternal ? .on : .off
        autoOptions.addItem(extItem)

        let streamItem = NSMenuItem(title: "网页视频一律按 HDR 切（读不到画质）", action: #selector(menuToggleStreaming), keyEquivalent: "")
        streamItem.target = self
        streamItem.state = auto.streamingAsHDR ? .on : .off
        autoOptions.addItem(streamItem)

        let probeItem = NSMenuItem(title: "网页视频按实测画质切换（B 站 HDR / 杜比）",
                                   action: #selector(menuToggleWebProbe), keyEquivalent: "")
        probeItem.target = self
        probeItem.state = WebProbe.enabled ? .on : .off
        autoOptions.addItem(probeItem)

        let unlockItem = NSMenuItem(title: "YouTube 藏起 HDR 选项时先切 HDR 解锁",
                                    action: #selector(menuToggleUnlockHDR), keyEquivalent: "")
        unlockItem.target = self
        unlockItem.state = WebProbe.unlockHiddenHDR ? .on : .off
        autoOptions.addItem(unlockItem)

        let forceItem = NSMenuItem(title: "解锁后直接选 4K HDR 画质（有 4K HDR 就不停在 1080p）",
                                   action: #selector(menuToggleForceTopHDR), keyEquivalent: "")
        forceItem.target = self
        forceItem.state = WebProbe.forceTopHDR ? .on : .off
        autoOptions.addItem(forceItem)

        let probeState = NSMenuItem(title: "    " + WebProbe.statusText(), action: nil, keyEquivalent: "")
        probeState.isEnabled = false
        autoOptions.addItem(probeState)

        autoOptions.addItem(.separator())
        let graceTitle = NSMenuItem(title: "播放结束后切回 SDR", action: nil, keyEquivalent: "")
        graceTitle.isEnabled = false
        autoOptions.addItem(graceTitle)
        for (label, seconds) in [("立即", 3.0), ("10 秒后", 10.0), ("30 秒后", 30.0), ("1 分钟后", 60.0), ("5 分钟后", 300.0)] {
            let item = NSMenuItem(title: "    " + label, action: #selector(menuPickGrace(_:)), keyEquivalent: "")
            item.representedObject = NSNumber(value: seconds)
            item.state = abs(auto.grace - seconds) < 0.5 ? .on : .off
            item.target = self
            autoOptions.addItem(item)
        }
        if auto.isHolding {
            let release = NSMenuItem(title: "恢复自动接管（当前为手动）", action: #selector(menuReleaseHold), keyEquivalent: "")
            release.target = self
            autoOptions.insertItem(release, at: 0)
            autoOptions.insertItem(.separator(), at: 1)
        }

        let optionsItem = NSMenuItem(title: "自动切换选项", action: nil, keyEquivalent: "")
        optionsItem.submenu = autoOptions
        menu.addItem(optionsItem)

        let ids = Displays.online()
        if ids.count > 1 {
            let displayMenu = NSMenu()
            for id in ids {
                let item = NSMenuItem(title: "\(Displays.name(id))  (\(Displays.subtitle(id)))",
                                      action: #selector(menuPickDisplay(_:)), keyEquivalent: "")
                item.representedObject = NSNumber(value: id)
                item.state = (id == d) ? .on : .off
                item.target = self
                displayMenu.addItem(item)
            }
            let displayItem = NSMenuItem(title: "显示器", action: nil, keyEquivalent: "")
            displayItem.submenu = displayMenu
            menu.addItem(displayItem)
        }

        menu.addItem(.separator())

        let login = NSMenuItem(title: "开机自动启动", action: #selector(menuToggleLogin), keyEquivalent: "")
        login.target = self
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(login)

        let diag = NSMenuItem(title: "复制诊断信息", action: #selector(menuCopyDiagnostics), keyEquivalent: "")
        diag.target = self
        menu.addItem(diag)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 HDRSwitch", action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        // 版本号挂在最后：反馈问题时报一句就能对上包
        let ver = NSMenuItem(title: "  " + AppDelegate.versionText, action: nil, keyEquivalent: "")
        ver.isEnabled = false
        menu.addItem(ver)

        return menu
    }

    /// 「HDRSwitch 1.0.4（build 5）」
    static var versionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let v = info["CFBundleShortVersionString"] as? String ?? ""
        let b = info["CFBundleVersion"] as? String ?? ""
        if v.isEmpty { return "HDRSwitch" }
        return b.isEmpty ? "HDRSwitch \(v)" : "HDRSwitch \(v)（build \(b)）"
    }

    @objc private func menuToggle() { toggleHDR(source: "menu") }

    @objc private func menuReleaseHold() {
        AutoHDR.shared.releaseHold()
        refreshUI()
        HUD.shared.show("已恢复自动接管")
    }

    @objc private func menuToggleAuto() {
        let a = AutoHDR.shared
        a.enabled = !a.enabled
        if a.enabled {
            a.start()
        } else {
            a.stop()
            // 关闭自动时，若 HDR 是自动开的就一并收回，避免留下一个没人管的状态
            if a.hdrAppliedByAuto, HDR.isOn(activeDisplay) {
                let d = activeDisplay
                HDRManager.shared.setHDR(false, display: d) { _, _ in self.refreshUI() }
            }
        }
        refreshUI()
    }

    @objc private func menuToggleUnknown() {
        AutoHDR.shared.unknownAsHDR.toggle()
        refreshUI()
    }

    @objc private func menuToggleKeepUnknown() {
        AutoHDR.shared.keepUnknownPlayer.toggle()
        refreshUI()
    }

    @objc private func menuToggleKeepPaused() {
        AutoHDR.shared.keepPaused.toggle()
        refreshUI()
    }

    @objc private func menuToggleStreaming() {
        AutoHDR.shared.streamingAsHDR.toggle()
        refreshUI()
    }

    /// 是否读取外置盘 / 网络卷上的片源。
    /// 关着时完全不碰这些文件：不会弹「想访问可移除宗卷上的文件」，
    /// 代价是文件名看不出来的 HDR 片会按未知处理（不开 HDR）。
    @objc private func menuToggleReadExternal() {
        MediaProbe.readExternal.toggle()
        HUD.shared.show(MediaProbe.readExternal
                        ? "读取外置卷片源：已开启（会请求磁盘授权）"
                        : "读取外置卷片源：已关闭（不再弹磁盘授权）")
        refreshUI()
        AutoHDR.shared.refresh()
    }

    /// 网页视频按实测画质切换（回页面里读清晰度标签 / 播放器色彩信息）
    @objc private func menuToggleWebProbe() {
        WebProbe.enabled.toggle()
        HUD.shared.show(WebProbe.enabled ? "网页实测画质：已开启" : "网页实测画质：已关闭")
        refreshUI()
    }

    /// YouTube 在 SDR 下会隐藏 HDR 选项，先切 HDR 才能解锁
    @objc private func menuToggleUnlockHDR() {
        WebProbe.unlockHiddenHDR.toggle()
        HUD.shared.show(WebProbe.unlockHiddenHDR ? "查到 HDR 片源就先切：已开启" : "查到 HDR 片源就先切：已关闭")
        refreshUI()
    }

    /// 解锁之后直接替用户把画质拉到最高的 HDR 档
    @objc private func menuToggleForceTopHDR() {
        WebProbe.forceTopHDR.toggle()
        HUD.shared.show(WebProbe.forceTopHDR ? "解锁后直接选最高 HDR 画质：已开启" : "解锁后直接选最高 HDR 画质：已关闭")
        refreshUI()
    }

    /// 申请「屏幕录制」权限：有了它才能读播放器窗口标题，
    /// 从而分辨「暂停」和「关掉片子」—— 前者保持 HDR，后者立刻回落。
    @objc private func menuGrantScreenRecording() {
        if CGPreflightScreenCaptureAccess() {
            WindowProbe.resetAvailability()
            if WindowProbe.titlesAvailable {
                HUD.shared.show("播放界面识别已可用")
            } else {
                HUD.shared.show("已授权，请重启 HDRSwitch 生效")
            }
        } else {
            _ = CGRequestScreenCaptureAccess()
            // 系统框点完之后再探一次；一般要重启 App 才真正生效
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                WindowProbe.resetAvailability()
                HUD.shared.show(WindowProbe.titlesAvailable
                                ? "播放界面识别已可用"
                                : "授权后请重启 HDRSwitch")
            }
        }
        refreshUI()
    }

    /// 打开安装脚本所在位置 —— 读 smbd（root 进程）持有的句柄需要装一个只读小工具
    @objc private func menuOpenFullDiskAccess() {
        let script = "/Users/wangjin/WorkBuddy/2026-10-29-22-25-38/HDRSwitch/安装共享识别.command"
        if FileManager.default.fileExists(atPath: script) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: script)])
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func menuPickGrace(_ sender: NSMenuItem) {
        if let n = sender.representedObject as? NSNumber {
            AutoHDR.shared.grace = n.doubleValue
        }
        refreshUI()
    }

    @objc private func menuPickDisplay(_ sender: NSMenuItem) {
        if let n = sender.representedObject as? NSNumber { activeDisplay = n.uint32Value }
    }

    @objc private func menuToggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                HUD.shared.show("已关闭开机启动")
            } else {
                try SMAppService.mainApp.register()
                HUD.shared.show("已设为开机启动")
            }
        } catch {
            HUD.shared.show("设置失败：请先把 App 拖到「应用程序」文件夹")
        }
        refreshUI()
    }

    @objc private func menuCopyDiagnostics() {
        let d = activeDisplay
        var lines = ["HDRSwitch 诊断信息", "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)"]
        for id in Displays.online() {
            lines.append("")
            lines.append("显示器 #\(id) \(Displays.name(id))")
            lines.append("  模式: \(Displays.subtitle(id))")
            lines.append("  支持 HDR: \(HDR.supports(id) ? "是" : "否")")
            lines.append("  HDR 状态: \(HDR.isOn(id) ? "开" : "关")")
        }
        if let m = Displays.current(d) {
            lines.append("  像素: \(m.pixelWidth)x\(m.pixelHeight)")
        }
        let auto = AutoHDR.shared
        lines.append("")
        lines.append("自动切换: \(auto.enabled ? "开" : "关") · 未知片源=\(auto.unknownAsHDR ? "按HDR" : "不切")/\(auto.keepUnknownPlayer ? "保持" : "不保持") · 暂停=\(auto.keepPaused ? "保持HDR" : "视为结束") · 网页视频=\(auto.streamingAsHDR ? "一律HDR" : "仅确认HDR时") · 宽限=\(Int(auto.grace))s")
        lines.append("当前识别: \(auto.session?.description ?? "无")")
        if let s = auto.session { lines.append("判定依据: \(s.detail) · \(s.basis)") }
        lines.append("最近动作: \(auto.lastAction.isEmpty ? "无" : auto.lastAction)")
        let text = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        HUD.shared.show("诊断信息已复制")
    }

    @objc private func menuQuit() { NSApp.terminate(nil) }

    // MARK: 全局快捷键 ⌃⌥H

    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async { globalDelegate?.toggleHDR(source: "hotkey") }
            return noErr
        }, 1, &spec, nil, nil)

        let id = EventHotKeyID(signature: OSType(0x48445231), id: 1)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(cmdKey | optionKey), UInt32(kVK_ANSI_H), id, GetApplicationEventTarget(), 0, &ref)
        hotKeyRef = ref
    }
}

// MARK: - 命令行

func runCLI(_ command: String) -> Never {
    _ = NSApplication.shared
    let d = CGMainDisplayID()
    let sem = DispatchSemaphore(value: 0)

    switch command {
    case "status":
        print("显示器: \(Displays.name(d)) (#\(d))")
        print("模式:   \(Displays.subtitle(d))")
        print("支持 HDR: \(HDR.supports(d) ? "是" : "否")")
        print("HDR 状态: \(HDR.isOn(d) ? "开启" : "关闭")")
        let u = UserDefaults.standard
        print("自动切换: \(u.object(forKey: "autoEnabled") as? Bool ?? true ? "开" : "关")" +
              (u.bool(forKey: "autoHold") ? " · 手动接管中" : ""))
        print("上次识别: \(u.string(forKey: "autoLastSession").flatMap { $0.isEmpty ? nil : $0 } ?? "无")")
        print("最近动作: \(u.string(forKey: "autoLastAction").flatMap { $0.isEmpty ? nil : $0 } ?? "无")")
        exit(HDR.isOn(d) ? 0 : 1)

    case "list":
        for id in Displays.online() {
            print("#\(id)  \(Displays.name(id))  \(Displays.subtitle(id))  HDR支持=\(HDR.supports(id) ? "是" : "否")  HDR=\(HDR.isOn(id) ? "开" : "关")")
        }
        exit(0)

    case "modes":
        for m in Displays.allModes(d) {
            print("\(ModeKey(m).description)  key=\(ModeKey(m).string)")
        }
        exit(0)

    case "detect":
        let path = CommandLine.arguments.dropFirst(2).first ?? ""
        guard !path.isEmpty else {
            print("用法: HDRSwitch detect <文件路径>")
            exit(2)
        }
        let r = MediaProbe.shared.probe(path: path)
        print("片源: \(path)")
        print("判定: \(r.verdict.label)  (\(r.detail))")
        exit(r.verdict == .hdr ? 0 : 1)

    case "sessions":
        let list = PlaybackWatcher.sessions(includeStreaming: true)
        if list.isEmpty { print("未检测到正在播放的片源") }
        for s in list {
            print("\(s.description)  —  \(s.detail)  [\(s.basis)]")
        }
        if !PlaybackWatcher.ignoredApps.isEmpty {
            print("已忽略下载器: \(PlaybackWatcher.ignoredApps.joined(separator: "、"))（持有文件句柄，但不播放）")
        }
        exit(0)

    case "smb":
        print("服务端: \(SMBService.diagnostics())")
        print("特权小工具: \(SMBService.helperStatus())")
        print("共享片源识别: \(SMBService.hasAccess() ? "可用" : "不可用") · \(SMBService.helperTitle())")
        let paths = SMBService.openMediaPaths()
        if paths.isEmpty { print("共享里没有正在读的视频文件") }
        for p in paths { print(p) }
        exit(0)

    case "web":
        print("网页实测画质: \(WebProbe.enabled ? "开" : "关")")
        print("查到 HDR 片源就先切（解锁 YouTube 隐藏的 HDR）: \(WebProbe.unlockHiddenHDR ? "开" : "关")")
        print("解锁后直接选最高 HDR 画质（有 4K HDR 就 4K HDR）: \(WebProbe.forceTopHDR ? "开" : "关")")
        print("最近状态: \(WebProbe.statusText())")
        print("自检: \(WebProbe.selfTest())")
        let list = PlaybackWatcher.sessions(includeStreaming: true)
        let web = list.filter { $0.kind == .streaming }
        if web.isEmpty { print("当前没有浏览器在播网页视频") }
        for s in web { print("  \(s.description) — \(s.detail) [\(s.basis)]") }
        exit(0)

    case "menu":
        let dg = AppDelegate()
        let menu = dg.buildMenu()
        for item in menu.items {
            if item.isSeparatorItem { print("  ---"); continue }
            let mark = item.state == .on ? "✓ " : (item.state == .off ? "  " : "")
            print("\(mark)\(item.title)\(item.submenu != nil ? "  ▸" : "")")
            if let sub = item.submenu {
                for si in sub.items {
                    if si.isSeparatorItem { print("      ---"); continue }
                    let sm = si.state == .on ? "✓ " : (si.state == .off ? "  " : "")
                    print("      \(sm)\(si.title)")
                }
            }
        }
        exit(0)

    case "mr":
        print("接口可用: \(MediaRemote.available ? "是" : "否")")
        print("正在播放(IsPlaying): \(MediaRemote.isPlaying().map { $0 ? "是" : "否" } ?? "读不到")")
        print("正在播放 PID: \(MediaRemote.nowPlayingPid().map { String($0) } ?? "读不到")")
        let cs = MediaRemote.clients()
        print("注册的客户端: \(cs.isEmpty ? "无" : "")")
        for c in cs { print("  \(c.bundleID)  pid=\(c.pid)") }
        let info = MediaRemote.nowPlayingInfo()
        print("媒体信息: \(info.isEmpty ? "无（没有正在播放的内容）" : "")")
        for (k, v) in info.sorted(by: { $0.key < $1.key }) where !k.hasPrefix("kMRMediaRemoteNowPlayingInfoArtwork") {
            print("  \(k.replacingOccurrences(of: "kMRMediaRemoteNowPlayingInfo", with: "")): \(v)")
        }
        print("有内容: \(MediaRemote.hasContent() ? "是" : "否") · 属主: \(MediaRemote.contentBundleID() ?? "未知")")
        exit(0)

    case "debugjs":
        // 内部调试：把一段 JS 发到前台标签页执行（排查网页暂停/播放用）
        let js = CommandLine.arguments.dropFirst(2).joined(separator: " ")
        guard !js.isEmpty else { print("用法: debugjs <javascript>"); exit(1) }
        let r = WebProbe.debugEval(js)
        print(r)
        // 由 launchd（open -n）启动时看不到 stdout，顺手落一份到临时文件
        try? r.write(toFile: "/tmp/hdrs-debug.txt", atomically: true, encoding: .utf8)
        exit(0)

    case "why":
        // 排查「为什么没自动切换」：把现场信号、自动模式状态、最近日志一次列出来
        let u = UserDefaults.standard
        func ts(_ key: String) -> String {
            let v = u.double(forKey: key)
            guard v > 0 else { return "无" }
            return DateFormatter.localizedString(from: Date(timeIntervalSince1970: v),
                                                 dateStyle: .none, timeStyle: .medium)
        }

        print("=== 显示器 ===")
        print("  \(Displays.name(d))  #\(d)")
        print("  当前模式: \(Displays.subtitle(d))")
        print("  该模式支持 HDR: \(HDR.supports(d) ? "是" : "否")")
        print("  HDR 状态: \(HDR.isOn(d) ? "开启" : "关闭")")
        print("")

        print("=== 现场检测到的播放 ===")
        let live = PlaybackWatcher.sessions(includeStreaming: true)
        if live.isEmpty {
            print("  没有检测到任何播放中的片源")
        }
        for s in live {
            let file = s.path.map { ($0 as NSString).lastPathComponent } ?? "无本地片源（网络串流/媒体库）"
            print("  \(s.appName)：\(file)")
            print("     判定=\(s.verdict.label)   依据=\(s.detail)   可信度=\(s.basis)")
        }
        if !PlaybackWatcher.ignoredApps.isEmpty {
            print("  已忽略下载器：\(PlaybackWatcher.ignoredApps.joined(separator: "、"))（它们会一直开着片源文件，但不播放）")
        }
        print("")

        print("=== 本机 SMB 共享 ===")
        let smbPaths = SMBService.openMediaPaths()
        let smbAccess = SMBService.hasAccess()
        print("  共享片源识别: \(smbAccess ? "可用" : "不可用") · \(SMBService.helperTitle())")
        if smbPaths.isEmpty {
            print("  共享里正在读的视频: 无")
        } else {
            for p in smbPaths {
                print("  共享里正在读的视频: \((p as NSString).lastPathComponent)")
                print("     路径=\(p)")
            }
        }
        print("")

        print("=== 腾讯视频 ===")
        if let tv = TencentVideoProbe.probe() {
            print("  当前内容: \(tv.detail)（\(tv.verdict.label)）· 依据 \(tv.evidence.label)")
        } else if !TencentVideoProbe.canRead() {
            print("  当前内容: 读不到 · 缺少「完全磁盘访问权限」")
            print("            系统设置 → 隐私与安全性 → 完全磁盘访问权限 → 勾选 HDRSwitch")
        } else {
            print("  当前内容: 读不到（没在播 / 已停止播放 / 日志不可读）")
        }
        print("  判定来源: 播放内核日志 \(TencentVideoProbe.logDir)")
        print("")

        print("=== 自动模式 ===")
        let enabled = u.object(forKey: "autoEnabled") as? Bool ?? true
        let unknownHDR = u.object(forKey: "autoUnknownAsHDR") as? Bool ?? false
        let keepUnknown = u.object(forKey: "autoKeepUnknownPlayer") as? Bool ?? false
        let streamHDR = u.object(forKey: "autoStreamingAsHDR") as? Bool ?? false
        let grace = u.double(forKey: "autoGraceSeconds")
        print("  总开关: \(enabled ? "开" : "关")")
        print("  识别不到片源的播放器: \(unknownHDR ? "按 HDR 切" : "不切") · \(keepUnknown ? "已开着就保持" : "到点就关")")
        print("  网页视频: \(streamHDR ? "一律按 HDR 切（读不到画质，会误判 SDR）" : "只在读到 HDR 色彩标记时切")")
        print("  网页实测画质: \(WebProbe.enabled ? "开" : "关") · \(WebProbe.statusText())")
        print("  退出后宽限: \(grace > 0 ? Int(grace) : 30) 秒")
        print("  暂停时: \((u.object(forKey: "autoKeepPaused") as? Bool ?? true) ? "保持 HDR（片源还开着就不收）" : "视为播放结束")")
        print("  手动接管中: \((u.bool(forKey: "autoHold")) ? "是（本场播放内不再自动切）" : "否")")
        let fails = u.integer(forKey: "autoFailCount")
        if fails > 0 {
            print("  连续失败: \(fails) 次，下次重试: \(ts("autoNextRetry"))")
        }
        print("  上次切回 SDR: \(ts("autoLastOffAt"))")
        print("  上次识别: \(u.string(forKey: "autoLastSession").flatMap { $0.isEmpty ? nil : $0 } ?? "无")")
        print("  最近动作: \(u.string(forKey: "autoLastAction").flatMap { $0.isEmpty ? nil : $0 } ?? "无")")
        print("")

        print("=== 最近日志 ===")
        let tail = Log.tail(12)
        if tail.isEmpty { print("  （暂无，日志文件为空）") }
        for line in tail { print("  " + line) }
        exit(0)

    case "auto":
        print("自动模式监视中（Ctrl+C 退出）…")
        var last = ""
        while true {
            let list = PlaybackWatcher.sessions(includeStreaming: true)
            let line = list.isEmpty
                ? "无播放"
                : list.map { "\($0.appName):\($0.verdict.label)(\($0.detail))" }.joined(separator: " | ")
            let state = "HDR=\(HDR.isOn(d) ? "开" : "关") mode=\(Displays.subtitle(d))"
            if line != last {
                let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
                print("[\(ts)] \(line)  ·  \(state)")
                last = line
            }
            Thread.sleep(forTimeInterval: 1.5)
        }

    default:
        let target: Bool
        switch command {
        case "on":     target = true
        case "off":    target = false
        default:       target = !HDR.isOn(d)
        }
        HDRManager.shared.setHDR(target, display: d) { ok, message in
            print((ok ? "✅ " : "⚠️  ") + message)
            sem.signal()
            exit(ok ? 0 : 2)
        }
        sem.wait()
        exit(0)
    }
}

// MARK: - 入口

let cliCommands: Set<String> = ["on", "off", "toggle", "status", "list", "modes", "detect", "sessions", "auto", "menu", "why", "smb", "web", "mr", "debugjs"]

if let first = CommandLine.arguments.dropFirst().first?.lowercased(), cliCommands.contains(first) {
    runCLI(first)
}

let app = NSApplication.shared
let delegate = AppDelegate()
globalDelegate = delegate
app.delegate = delegate
app.run()

// AutoHDR.swift — 自动模式：检测到 HDR 片源在播就开 HDR，退出播放再切回 SDR
//
// 设计取舍：
//   · 只有「确认是 HDR 片源」才动手，避免随便放个 SDR 视频就跳模式；
//   · 连续两次轮询都命中才动作，防止拖拽预览、选片时的瞬时误判；
//   · 播完不立刻切回，等一个宽限期（默认 30 秒），避免看片时暂停/切集反复横跳；
//   · 用户手动点过开关后，本场播放不再自动干预（不跟用户抢方向盘）。

import AppKit

/// 轻量调试日志：`defaults write com.wangjin.hdrswitch debugLog -bool true` 后重启 App 生效
enum Log {
    static let enabled = UserDefaults.standard.bool(forKey: "debugLog")
    static let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/HDRSwitch.log")

    /// verbose=false 时只记录「动作级」事件，方便事后排查；verbose=true 时连每次轮询都记
    static func write(_ msg: String, force: Bool = false) {
        guard enabled || force else { return }
        rotateIfNeeded()
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "[\(ts)] \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        } else {
            try? data.write(to: url)
        }
    }

    private static func rotateIfNeeded() {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        if size > 512 * 1024 {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 读取最近若干行（给 `why` 诊断命令用）
    static func tail(_ lines: Int) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true)
                   .suffix(lines).map(String.init)
    }
}

final class AutoHDR {
    static let shared = AutoHDR()

    private let defaults = UserDefaults.standard
    private let work = DispatchQueue(label: "com.wangjin.hdrswitch.detect", qos: .utility)

    private var timer: Timer?
    private var polling = false
    private var pollStartedAt: Date?
    private var activeStreak = 0
    private var lastActiveAt: Date?
    private var holdUntilSessionEnds = false
    /// 刚切回 SDR 的时间点，用于抑制信号抖动导致的来回切换
    private var lastOffAt: Date?
    /// 上一次看到的播放会话标识（App + 片源），换了片/换了播放器要重新接管
    private var lastIdentity = ""
    /// 连续失败次数与下次允许重试时间
    private var failCount = 0
    private var nextRetryAt: Date?
    /// 上一次写进日志的判定详情（调试日志里只在变化时记一行，免得刷屏）
    private var lastDetail = ""
    /// 上一次写进日志的播放健康度状态（true = 卡住），以及上次记录的时间
    private var lastStuckState: Bool?
    private var lastHealthLogAt: Date?

    /// 当前被自动控制的目标显示器
    var displayProvider: () -> CGDirectDisplayID = { CGMainDisplayID() }
    /// 状态变化时回调（刷新菜单栏 / 菜单）
    var onChange: (() -> Void)?

    private(set) var session: MediaSession?
    private(set) var lastAction: String = ""
    /// 当前 HDR 是不是本模块自动打开的
    private(set) var hdrAppliedByAuto = false

    // MARK: 设置项

    var enabled: Bool {
        get { defaults.object(forKey: "autoEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoEnabled"); persistState(); onChange?() }
    }

    /// 播放器拿不到片源信息时（典型是 Infuse 走网络串流），是否也按 HDR 处理
    var unknownAsHDR: Bool {
        get { defaults.object(forKey: "autoUnknownAsHDR") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "autoUnknownAsHDR"); onChange?() }
    }

    /// 播放器拿不到片源信息、但 HDR 已经开着时，是否保持不关。
    /// 默认**关**：读不到画质就当作 SDR，到点回 SDR —— 宁可漏掉一个 HDR 网络流，
    /// 也不要让 SDR 内容一直挂在 HDR 上。想反过来的在这里打开。
    var keepUnknownPlayer: Bool {
        get { defaults.object(forKey: "autoKeepUnknownPlayer") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "autoKeepUnknownPlayer"); onChange?() }
    }

    /// 浏览器 / 网页视频是否一律按 HDR 处理（拿不到画质，开启后 SDR 网页也会切，不推荐）
    var streamingAsHDR: Bool {
        get { defaults.object(forKey: "autoStreamingAsHDR") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "autoStreamingAsHDR"); onChange?() }
    }

    /// 暂停播放时是否保持 HDR（片源仍开着就不收回）。
    /// 默认**开**：播放器一按暂停就会收回防休眠断言，旧逻辑因此把暂停当成「播完了」，
    /// 宽限期一到就退回 SDR，看片中途暂停一下画面就掉色。
    var keepPaused: Bool {
        get { defaults.object(forKey: "autoKeepPaused") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoKeepPaused"); onChange?() }
    }

    /// 浏览器 / 流媒体（拿不到片源信息）是否参与
    var includeStreaming: Bool {
        get { defaults.object(forKey: "autoIncludeStreaming") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoIncludeStreaming"); onChange?() }
    }

    /// 播放结束后的宽限期（秒）
    var grace: Double {
        get {
            let v = defaults.double(forKey: "autoGraceSeconds")
            return v > 0 ? v : 30
        }
        set { defaults.set(newValue, forKey: "autoGraceSeconds"); onChange?() }
    }

    var isRunning: Bool { timer != nil }

    // MARK: 生命周期

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t

        // App 在播放中途被重启的情况：HDR 还开着但会话已丢失，
        // 用持久化标记续上宽限期，避免「没有播放却一直停在 HDR」。
        if defaults.bool(forKey: "autoHDRon"), HDR.isOn(displayProvider()) {
            hdrAppliedByAuto = true
            if lastActiveAt == nil { lastActiveAt = Date() }
            Log.write("启动时发现 HDR 仍为自动开启状态，续上宽限期", force: true)
        }

        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    var isHolding: Bool { holdUntilSessionEnds }

    /// 手动解除接管，让自动逻辑立刻重新生效
    func releaseHold() {
        holdUntilSessionEnds = false
        failCount = 0
        nextRetryAt = nil
        lastAction = "已恢复自动接管"
        persistState()
        onChange?()
        tick()
    }

    /// 用户手动拨动开关：放弃本场播放的自动控制
    func noteManualToggle() {
        guard enabled else { return }
        holdUntilSessionEnds = true
        hdrAppliedByAuto = false
        lastAction = "已手动接管（本场播放内不再自动切换）"
        onChange?()
    }

    // MARK: 轮询

    private func tick() {
        guard enabled else { return }

        if polling {
            // 上一次检测卡住太久（极少数情况下系统调用会不返回）→ 强制复位，避免自动逻辑停摆
            if let t = pollStartedAt, Date().timeIntervalSince(t) > 6 {
                Log.write("检测超过 6 秒未返回，强制复位", force: true)
                polling = false
                pollStartedAt = nil
            } else {
                return
            }
        }
        guard !HDRManager.shared.isBusy else { return }
        polling = true
        pollStartedAt = Date()
        let includeStreaming = self.includeStreaming

        work.async {
            // 页面脚本要知道显示器是不是已经 HDR 了，才决定要不要让播放器重建格式列表
            WebProbe.displayHDR = HDR.isOn(self.displayProvider())
            // 顺便把屏幕的像素高度传进去：8K 片源不该被拉到 4320p
            if let m = Displays.current(self.displayProvider()) {
                WebProbe.displayPixelHeight = m.pixelHeight
            }
            let list = PlaybackWatcher.sessions(includeStreaming: includeStreaming)
            DispatchQueue.main.async {
                self.polling = false
                self.pollStartedAt = nil
                self.evaluate(list)
            }
        }
    }

    /// 本场应当做什么：开 / 保持现状 / 关
    private enum Goal { case on, keep, off }

    private func evaluate(_ list: [MediaSession]) {
        let candidate = list.first
        session = candidate

        let d = displayProvider()
        let hdrOn = HDR.isOn(d)

        // 换片 / 换播放器 → 重置状态（否则「手动接管」会一路粘住，新片再也不自动切）
        let identity = candidate.map { "\($0.appName)|\($0.path ?? "-")|\($0.verdict.rawValue)|\($0.detail)" } ?? ""
        if identity != lastIdentity {
            lastIdentity = identity
            activeStreak = 0
            failCount = 0
            nextRetryAt = nil
            if !identity.isEmpty && holdUntilSessionEnds {
                holdUntilSessionEnds = false
                Log.write("会话变化，恢复自动接管: \(identity)", force: true)
            }
            persistState()
        }

        let goal = self.goal(for: candidate, hdrOn: hdrOn)
        // cfg 三位：u=未知片源是否按HDR / s=网页视频是否按HDR / k=未知时是否保持
        // 判定结果和这三个开关一起记，回看日志时才能确认「是设定变了还是判定错了」
        let cfg = "u\(unknownAsHDR ? 1 : 0)s\(streamingAsHDR ? 1 : 0)k\(keepUnknownPlayer ? 1 : 0)"
        Log.write("eval session=\(candidate?.description ?? "无") basis=\(candidate?.basis ?? "-") cfg=\(cfg) goal=\(goal) hdrOn=\(hdrOn) streak=\(activeStreak) hold=\(holdUntilSessionEnds)")

        // 判定详情（网页实测到了什么画质、读到了哪些色彩标记）只在变化时记一行，
        // 排查「为什么没切 / 切了但没到 4K」时全靠它
        if let s = candidate, s.detail != lastDetail {
            lastDetail = s.detail
            Log.write("  详情: \(s.detail)", force: true)
        } else if candidate == nil && !lastDetail.isEmpty {
            lastDetail = ""
        }

        // 播放健康度（readyState / 缓冲 / 帧数 / 前进量）：只在变化时记一行。
        // 排查「切了 HDR 之后断流」全靠它 —— 播放器报「在播」但 adv 一直是 0，
        // 就是画面不再推进；buf 掉到 0 说明是缓冲断而不是解码断。
        let health = WebProbe.healthLine()
        let stuckNow = WebProbe.stalledRecently(6)
        if !health.isEmpty {
            let changed = (lastStuckState == nil) || (lastStuckState! != stuckNow)
            let due = Date().timeIntervalSince(lastHealthLogAt ?? Date.distantPast) > 15
            if changed || (stuckNow && due) {
                lastStuckState = stuckNow
                lastHealthLogAt = Date()
                Log.write("  健康: \(health)\(stuckNow ? "（卡住）" : "")", force: true)
            }
        } else if candidate == nil {
            lastStuckState = nil
        }

        // 判定不出画质时，把「共享片源识别」这条线的状态一起记下来，
        // 否则排查时看不出来到底是没权限还是确实没在播
        if candidate?.verdict == .unknown && candidate?.kind == .player {
            let access = SMBService.hasAccess()
            Log.write("  共享片源: 权限=\(access ? "有" : "无") · smbd 打开的视频=\(SMBService.openMediaPaths().count) 个")
        }

        switch goal {
        case .on:
            activeStreak += 1
            lastActiveAt = Date()

            // 用户手动拨过开关：本场播放内不干预
            guard !holdUntilSessionEnds else { onChange?(); return }
            // 刚切回 SDR 的 6 秒内不再开，避免检测信号抖动造成反复黑屏
            if let off = lastOffAt, Date().timeIntervalSince(off) < 6 { onChange?(); return }
            // 失败退避：切不动时不要每秒重试（那会一直黑屏闪）
            if let t = nextRetryAt, Date() < t { onChange?(); return }
            // 连续两次命中才动作，防拖拽预览/选片时的瞬时误判
            guard activeStreak >= 2, !hdrOn, !HDRManager.shared.isBusy else { onChange?(); return }
            applyAuto(true, display: d)

        case .keep:
            // 拿不到片源、但 HDR 已开：只续期，不动作（30 秒宽限会一直往后推）
            activeStreak = 0
            if hdrOn { lastActiveAt = Date() }
            onChange?()

        case .off:
            activeStreak = 0
            // 播放结束 → 解除「手动接管」，下一场重新按自动逻辑走
            holdUntilSessionEnds = false

            // 只关「自己开的」：用户/系统自己开的 HDR 不碰
            guard hdrOn, hdrAppliedByAuto, let last = lastActiveAt,
                  Date().timeIntervalSince(last) >= grace,
                  !HDRManager.shared.isBusy else { onChange?(); return }
            applyAuto(false, display: d)
        }
    }

    /// 判定目标状态。核心原则：**没有确凿的 HDR 证据就不开**。
    private func goal(for s: MediaSession?, hdrOn: Bool) -> Goal {
        guard let s = s else {
            // 刚由我们重建过播放器：那几秒页面里没有 <video> 在播，别当成「播放结束」
            return WebProbe.reinitGraceActive ? .keep : .off
        }
        // 暂停 + 画质未知 + HDR 已开 → 保持。
        //
        // 暂停时画质常常读不到：网页把清晰度控件收起来了，本地播放器也放掉了解码器。
        // 判定于是变成「未知」，而未知默认按 SDR 处理 —— 于是暂停一下、切个页面，
        // 屏幕就掉回 SDR 再没亮起来。用户明确要求「暂停期间保持」，而这里
        // HDR 本来就是我们自己开的，暂停也不是播放结束：宁可多亮一会儿。
        // 注意只在「未知」时这样处理：明确读到 SDR 片源（比如暂停在一条 1080p 上）
        // 仍然按 SDR 收掉。
        if s.paused && s.verdict == .unknown && hdrOn { return .keep }
        switch s.verdict {
        case .hdr:
            return .on
        case .sdr:
            return .off
        case .unknown:
            switch s.kind {
            case .player:
                if unknownAsHDR { return .on }
                return (keepUnknownPlayer && hdrOn) ? .keep : .off
            case .streaming:
                // 网页视频：读不到色彩信息时不主动开 HDR（除非显式勾了
                // 「网页视频一律按 HDR」）—— 这是「不开」的原则。
                //
                // 但**已经开着的时候不要收**。收 HDR 只有两个正当理由：
                //   ① 明确读到这条视频是 SDR（上面的 .sdr 分支）；
                //   ② 播放结束（会话消失，走最前面的 guard）。
                // 「读不到」不是理由：B 站暂停会把清晰度控件收起来，切标签、
                // 播放器正忙、脚本偶尔超时，都会让这一轮抓空。抓空就掉色，
                // 用户看到的就是屏幕一会儿掉一会儿亮 —— 这比多亮一会儿糟糕得多。
                if hdrOn { return .keep }
                return streamingAsHDR ? .on : .off
            }
        }
    }

    private func applyAuto(_ on: Bool, display d: CGDirectDisplayID) {
        lastAction = on ? "自动开启 HDR" : "自动恢复 SDR"
        HDRManager.shared.setHDR(on, display: d) { ok, message in
            DispatchQueue.main.async {
                self.lastAction = (ok ? "" : "⚠︎ ") + message
                if ok {
                    self.hdrAppliedByAuto = on
                    self.failCount = 0
                    self.nextRetryAt = nil
                } else if on {
                    self.failCount += 1
                    let delay = min(60.0, pow(2.0, Double(self.failCount)) * 4)
                    self.nextRetryAt = Date().addingTimeInterval(delay)
                    if self.failCount >= 3 {
                        self.holdUntilSessionEnds = true
                        self.lastAction = "⚠︎ 多次切换失败，本场不再尝试（\(message)）"
                    }
                }
                if !on { self.lastActiveAt = nil; self.lastOffAt = Date() }
                Log.write("actuate on=\(on) ok=\(ok) msg=\(message)", force: true)
                self.onChange?()
                self.persistState()
            }
        }
        onChange?()
    }

    // MARK: 状态持久化（CLI / 重启后能看出来）

    private func persistState() {
        defaults.set(lastAction, forKey: "autoLastAction")
        // 带上判定依据，这样在终端里 `defaults read` 就能看出「凭什么这么判」，
        // 不用再靠 Apple 事件去问浏览器（终端进程没这个授权）
        let s = session.map { "\($0.description) · \($0.detail)" } ?? ""
        defaults.set(s, forKey: "autoLastSession")
        defaults.set(holdUntilSessionEnds, forKey: "autoHold")
        defaults.set(failCount, forKey: "autoFailCount")
        defaults.set(nextRetryAt?.timeIntervalSince1970 ?? 0, forKey: "autoNextRetry")
        defaults.set(lastOffAt?.timeIntervalSince1970 ?? 0, forKey: "autoLastOffAt")
        defaults.set(hdrAppliedByAuto && HDR.isOn(displayProvider()), forKey: "autoHDRon")
        defaults.synchronize()
    }

    func summary() -> String {
        guard enabled else { return "自动切换：已关闭" }
        guard let s = session else {
            if HDR.isOn(displayProvider()) { return "自动切换：空闲（HDR 由手动开启保持中）" }
            return "自动切换：待命（未检测到播放）"
        }
        switch s.verdict {
        case .hdr:
            return "自动切换：\(s.appName) · \(s.detail)"
        case .sdr:
            return "自动切换：\(s.appName) · SDR 片源，保持 SDR"
        case .unknown:
            if s.kind == .streaming {
                return "自动切换：\(s.appName) · 网页视频（读不到画质，不切）"
            }
            return "自动切换：\(s.appName) · 片源未知（\(unknownAsHDR ? "按 HDR 处理" : "不切")）"
        }
    }
}

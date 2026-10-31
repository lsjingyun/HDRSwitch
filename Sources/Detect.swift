// Detect.swift — 播放行为与 HDR 片源识别
//
// 两个信号拼起来判断「现在是不是在播 HDR」：
//   1. 进程文件句柄 → 找到播放器当前加载的媒体文件（无需权限，无需子进程）
//   2. 容器探测     → mp4/mov 走 AVFoundation，mkv/webm 自己解析 EBML 的 Colour 元素
// 另外用 MediaRemote 兜住浏览器/流媒体这类拿不到文件的场景。

import AppKit
import AVFoundation
import CoreMedia
import IOKit.pwr_mgt

// MARK: - 读取进程打开的文件

@_silgen_name("proc_pidinfo")
private func proc_pidinfo(_ pid: Int32, _ flavor: Int32, _ arg: UInt64,
                          _ buffer: UnsafeMutableRawPointer?, _ size: Int32) -> Int32

@_silgen_name("proc_pidfdinfo")
private func proc_pidfdinfo(_ pid: Int32, _ fd: Int32, _ flavor: Int32,
                            _ buffer: UnsafeMutableRawPointer?, _ size: Int32) -> Int32

@_silgen_name("proc_listpids")
private func proc_listpids(_ type: UInt32, _ typeinfo: UInt32,
                           _ buffer: UnsafeMutableRawPointer?, _ buffersize: Int32) -> Int32

@_silgen_name("proc_name")
private func proc_name(_ pid: Int32, _ buffer: UnsafeMutableRawPointer?,
                       _ buffersize: UInt32) -> Int32

enum ProcFiles {
    private static let PROC_PIDLISTFDS: Int32 = 1
    private static let PROC_PIDFDVNODEPATHINFO: Int32 = 2
    /// vnode_fdinfowithpath 里 vip_path 的偏移（proc_fileinfo 24 + vnode_info 152）
    private static let pathOffset = 176

    /// 只问「能不能列出这个进程的 fd」，不关心内容。
    /// 返回 > 0 就说明有权限读别的用户（如 root 的 smbd）的 fd 表。
    static func fdCount(pid: Int32) -> Int {
        guard pid > 0 else { return 0 }
        var raw = [UInt8](repeating: 0, count: 32 * 1024)
        let got = raw.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32(32 * 1024))
        }
        return Int(max(0, got)) / 8
    }

    static func openPaths(pid: Int32) -> [String] {
        guard pid > 0 else { return [] }
        var size = 64 * 1024
        var raw = [UInt8](repeating: 0, count: size)
        var got = raw.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32(size))
        }
        if got > size {
            size = Int(got) + 4096
            raw = [UInt8](repeating: 0, count: size)
            got = raw.withUnsafeMutableBytes {
                proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32(size))
            }
        }
        guard got > 0 else { return [] }

        var paths: [String] = []
        let count = Int(got) / 8
        for i in 0..<count {
            let fd = raw.withUnsafeBytes { $0.load(fromByteOffset: i * 8, as: Int32.self) }
            guard fd >= 0 else { continue }
            var buf = [UInt8](repeating: 0, count: 2048)
            let r = buf.withUnsafeMutableBytes {
                proc_pidfdinfo(pid, fd, PROC_PIDFDVNODEPATHINFO, $0.baseAddress, Int32(2048))
            }
            guard r > 0 else { continue }
            let path = buf.withUnsafeBytes { p -> String in
                let c = p.baseAddress!.advanced(by: pathOffset).assumingMemoryBound(to: CChar.self)
                return String(cString: c)
            }
            if path.hasPrefix("/") { paths.append(path) }
        }
        return paths
    }
}

// MARK: - 本机 SMB 共享（Infuse 挂载共享播放的关键）
//
// Infuse / 其他 App 通过 SMB 播放「本机共享」里的文件时，播放器进程里没有
// 任何文件句柄 —— 数据是 SMB 协议流进来的。真正 open() 这些文件的是服务端
// 进程 `smbd`，它由 root 运行。
//
// 所以这里反过来查服务端：列出 smbd 当前打开的视频文件，就是「正在通过共享
// 播放的那个文件」。读取 root 进程的 fd 需要「完全磁盘访问权限」，没有权限时
// proc_pidinfo 返回 0，本函数静默返回空，不影响其他判定路径。

enum SMBService {
    private static var cache: (at: Date, paths: [String])?
    private static var pidCache: (at: Date, pids: [Int32])?
    /// 有没有成功读到过（用来区分「没在播」和「没权限」）
    private(set) static var lastReadSucceeded = false

    /// smbd 当前打开的视频文件（路径去重）。无权限或没在播时返回空。
    static func openMediaPaths() -> [String] {
        // 缓存压到 1 秒以内：smbd 打开片源的时间窗很窄（读完一段就放），
        // 轮询间隔稍长一点就整轮错过，Infuse 这类共享播放会时判时不判。
        if let c = cache, Date().timeIntervalSince(c.at) < 0.7 { return c.paths }

        let pids = serverPids()
        var found: [String] = []
        var canListOwn = false

        for pid in pids {
            if ProcFiles.fdCount(pid: pid) > 0 { canListOwn = true }
            for p in ProcFiles.openPaths(pid: pid) {
                let ext = (p as NSString).pathExtension.lowercased()
                guard MediaProbe.mediaExtensions.contains(ext) else { continue }
                if p.hasPrefix("/System/") || p.hasPrefix("/Library/") { continue }
                found.append(p)
            }
        }

        // 自己读不到 root 进程（没有完全磁盘访问权限）→ 走已安装的特权小工具
        if !canListOwn {
            found = helperPaths()
        }

        let uniq = Array(Set(found)).sorted()
        cache = (Date(), uniq)
        return uniq
    }

    /// 特权小工具的路径（安装脚本放的固定位置）
    static let helperPath = "/usr/local/libexec/hdrswitch-smbdump"

    /// 播放器启动 / 退出时清缓存：别拿上一轮读到的句柄表去判断刚起来的进程
    static func invalidateCache() { cache = nil }

    /// 小工具是否已安装且可用
    static func helperAvailable() -> Bool {
        if let c = helperCacheOK, Date().timeIntervalSince(c.at) < 60 { return c.ok }
        let ok = isHelperRunnable()
        helperCacheOK = (Date(), ok)
        return ok
    }

    private static var helperCacheOK: (at: Date, ok: Bool)?

    /// 跑一次小工具，带回 stdout / stderr / 退出码（诊断要用到 stderr）
    private static func runHelperRaw() -> (status: Int32, out: String, err: String) {
        guard FileManager.default.isExecutableFile(atPath: helperPath) else {
            return (-1, "", "小工具未安装：\(helperPath)")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", helperPath]
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do {
            try p.run()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus,
                    String(data: outData, encoding: .utf8) ?? "",
                    String(data: errData, encoding: .utf8) ?? "")
        } catch {
            return (-1, "", "启动 sudo 失败：\(error.localizedDescription)")
        }
    }

    /// 只要 sudo -n 能跑通（哪怕没输出）就说明装好了
    private static func isHelperRunnable() -> Bool { runHelperRaw().status == 0 }

    /// 诊断用：把 sudo 的原始报错带出来（"no tty present" / 不在 sudoers 里都能看见）
    static func helperStatus() -> String {
        let r = runHelperRaw()
        var s = "小工具路径=\(helperPath) 退出码=\(r.status)"
        let err = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
        if !err.isEmpty { s += " stderr=\(err)" }
        return s
    }

    /// 一句话说明「共享识别靠什么在工作」
    static func helperTitle() -> String {
        let installed = FileManager.default.isExecutableFile(atPath: helperPath)
        let readable = serverPids().first.map { ProcFiles.fdCount(pid: $0) > 0 } ?? false
        if readable { return "自身可直接读取 smbd 句柄" }
        if installed && isHelperRunnable() { return "经特权小工具读取 smbd 句柄" }
        return "小工具未装好：\(helperPath)"
    }

    private static func runHelper() -> [String] {
        let r = runHelperRaw()
        guard r.status == 0 else { return [] }
        return r.out.split(separator: "\n").map(String.init).filter { $0.hasPrefix("/") }
    }

    private static func helperPaths() -> [String] { runHelper() }

    /// 共享片源识别这条线是否可用：自己读得到（完全磁盘访问）或小工具已装好
    static func hasAccess() -> Bool {
        if let c = accessCache, Date().timeIntervalSince(c.at) < 60 { return c.ok }
        var ok = false
        let pids = serverPids()
        if let first = pids.first {
            // 注意：不能用「有没有媒体文件」判断权限 —— smbd 空闲时一个文件都不开。
            // 能不能列出 fd 表本身才是权限信号。
            ok = ProcFiles.fdCount(pid: first) > 0
        }
        if !ok { ok = helperAvailable() }
        accessCache = (Date(), ok)
        return ok
    }

    /// 诊断用：smbd 进程数 / fd 总数 / 是否读得到路径
    static func diagnostics() -> String {
        let pids = serverPids()
        guard let first = pids.first else { return "没找到 smbd 进程" }
        let fds = ProcFiles.fdCount(pid: first)
        let paths = ProcFiles.openPaths(pid: first).count
        return "smbd pid=\(first) fd 总数=\(fds) 有路径的=\(paths)"
    }

    /// TCC 探针：读别的 App 的容器目录，能成功说明「完全磁盘访问权限」真的生效了
    static func canReadOtherAppData() -> Bool {
        let p = NSHomeDirectory() + "/Library/Containers/com.firecore.infuse/Data"
        return (try? FileManager.default.contentsOfDirectory(atPath: p)) != nil
    }

    private static var accessCache: (at: Date, ok: Bool)?

    private static func serverPids() -> [Int32] {
        if let c = pidCache, Date().timeIntervalSince(c.at) < 10 { return c.pids }

        // proc_name 对 root 进程同样受保护，读不到名字。
        // pgrep 走 sysctl，普通用户也能列出 root 进程，稳。
        var pids: [Int32] = []
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-x", "smbd"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            if let text = String(data: data, encoding: .utf8) {
                pids = text.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
            }
        } catch {
            pids = []
        }
        pidCache = (Date(), pids)
        return pids
    }
}

// MARK: - 电源断言（判断「正在放视频」的通用信号）

/// 播放视频时播放器几乎都会持有「阻止显示器休眠」的电源断言：
/// IINA 是 `NoDisplaySleepAssertion / IINA is playing video`，
/// Infuse 是 `PreventUserIdleDisplaySleep / com.firecore.fuse.video_controller`。
/// 这个信号跟片源在本地还是网络无关，正好补上网络串流拿不到文件句柄的缺口。
enum DisplayAssertions {
    private static let displayTypes: Set<String> = [
        "NoDisplaySleepAssertion",
        "PreventUserIdleDisplaySleep"
    ]

    static func playingPids() -> Set<Int32> {
        var out: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&out) == kIOReturnSuccess, let raw = out else { return [] }
        let dict = raw.takeRetainedValue() as NSDictionary

        var pids = Set<Int32>()
        for (k, v) in dict {
            guard let pid = (k as? NSNumber)?.int32Value,
                  let list = v as? [[String: Any]] else { continue }
            for item in list {
                let type = item["AssertType"] as? String ?? ""
                let level = item["AssertLevel"] as? Int ?? 0
                if level != 0 && displayTypes.contains(type) {
                    pids.insert(pid)
                    break
                }
            }
        }
        return pids
    }

    /// 哪些浏览器此刻真的在放网页视频。
    ///
    /// WebKit 播放音视频时会向 runningboardd 申请一条 `WebKit Media Playback` 断言，
    /// 断言名里带着发起方的 bundle id（形如
    /// `app<application.com.apple.Safari.14504.15170(501)>…:WebKit Media Playback`）。
    /// 这条断言虽然是「系统休眠」级别、进不了 playingPids，但正好能当「网页在播」的证据。
    static func webPlaybackBundles() -> Set<String> {
        var out: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&out) == kIOReturnSuccess, let raw = out else { return [] }
        let dict = raw.takeRetainedValue() as NSDictionary

        var bundles = Set<String>()
        for (_, v) in dict {
            guard let list = v as? [[String: Any]] else { continue }
            for item in list {
                let name = item["AssertName"] as? String ?? ""
                guard name.contains("Media Playback") else { continue }
                guard let r = name.range(of: "application.") else { continue }
                let rest = name[r.upperBound...]
                // bundle id 后面紧跟 「.<版本>.<构建>(<pid>)」
                var id = ""
                for ch in rest {
                    if ch.isLetter || ch.isNumber || ch == "." || ch == "-" || ch == "_" {
                        id.append(ch)
                    } else {
                        break
                    }
                }
                // 去掉尾部的 版本.构建 两段纯数字
                let parts = id.split(separator: ".").map(String.init)
                var keep: [String] = []
                for p in parts {
                    if Int(p) != nil && keep.count >= 2 { break }
                    keep.append(p)
                }
                let cleaned = keep.joined(separator: ".")
                if !cleaned.isEmpty { bundles.insert(cleaned) }
            }
        }
        return bundles
    }
}

// MARK: - 片源判定结果

enum HDRVerdict: String {
    case hdr, sdr, unknown

    var label: String {
        switch self {
        case .hdr: return "HDR"
        case .sdr: return "SDR"
        case .unknown: return "未知"
        }
    }
}

/// 判定依据的可靠程度：只有 colorTags 才算「真的看了码流」，filenameHint 只是文件名猜的
enum Evidence {
    case colorTags      // 容器 Colour 元素 / SPS-VUI / AVFoundation 色彩标记
    case filenameHint   // 文件名里的 HDR 字样
    case webProbe       // 回网页里读到的清晰度标签 / 播放器色彩信息
    case appLog         // 播放器自己写进日志的内容级 HDR 判定（腾讯视频）
    case none           // 无从判断（网页流、网络串流）

    var label: String {
        switch self {
        case .colorTags: return "实读色彩标记"
        case .filenameHint: return "文件名推断"
        case .webProbe: return "网页实测"
        case .appLog: return "播放器日志"
        case .none: return "无法判定"
        }
    }
}

struct ProbeResult {
    let verdict: HDRVerdict
    let detail: String
    var evidence: Evidence = .none
}

// MARK: - 容器探测

final class MediaProbe {
    static let shared = MediaProbe()

    private var cache: [String: ProbeResult] = [:]
    private let lock = NSLock()

    private static let avExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "m2ts", "mts", "ts"]
    private static let ebmlExtensions: Set<String> = ["mkv", "webm", "mka"]

    static let mediaExtensions: Set<String> = avExtensions
        .union(ebmlExtensions)
        .union(["flv", "wmv", "rmvb", "rm", "mpg", "mpeg", "vob", "iso", "3gp", "ogv", "asf"])

    /// 要不要去读外置盘 / 网络卷上的片源。
    ///
    /// 打开这些卷上的文件会触发系统授权框（「想访问可移除宗卷上的文件」），
    /// 而授权是跟**签名**绑定的 —— 每次重新编译换了签名就要再点一遍。
    /// 默认不读：文件名带 HDR / DoVi / HLG 的照样判得出来，判不出的按未知处理，
    /// 未知不会去开 HDR，所以最坏情况只是「这部片子不开 HDR」，不会误开。
    static var readExternal: Bool {
        get { UserDefaults.standard.bool(forKey: "readExternalMedia") }
        set { UserDefaults.standard.set(newValue, forKey: "readExternalMedia") }
    }

    /// 路径是不是在「读它要系统授权」的卷上。
    private static func onExternalVolume(_ path: String) -> Bool {
        guard path.hasPrefix("/Volumes/") else { return false }
        guard let vol = path.dropFirst("/Volumes/".count).split(separator: "/").first else { return true }
        // 「Macintosh HD」这类名字是系统盘（符号链接到 /），读它不需要授权
        let root = "/Volumes/" + vol
        return URL(fileURLWithPath: root).resolvingSymlinksInPath().path != "/"
    }

    func probe(path: String) -> ProbeResult {
        // 名字里就能看出是 HDR 的，先按名字判。纯字符串操作，一个字节都不读，
        // 也就不会弹出「想访问可移除宗卷上的文件」那个框。
        if let named = Self.filenameVerdict(path) {
            return ProbeResult(verdict: named, detail: "文件名标记", evidence: .filenameHint)
        }

        // 外置盘 / 网络卷默认一点都不碰 —— 连文件属性都不读。
        // 读它们要系统授权，而授权跟着签名走，每换一次构建就问一遍。
        // 没标记的片子按未知处理（不开 HDR），需要精确判定时菜单里打开开关。
        if Self.onExternalVolume(path), !Self.readExternal {
            if Log.enabled { Log.write("片源访问：\(path) · 外置卷，未读取") }
            return ProbeResult(verdict: .unknown,
                               detail: "外置卷 · 未读取片源（可在菜单里允许）",
                               evidence: .none)
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(path)|\(size)|\(Int(mtime))"

        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()

        var result = probeUncached(path: path)

        // 容器里没写色彩信息时，退回文件名线索（HDR10 / DoVi / HLG 这类命名几乎不会误报）
        if result.verdict == .unknown, let named = Self.filenameVerdict(path) {
            result = ProbeResult(verdict: named, detail: "文件名标记", evidence: .filenameHint)
        }

        lock.lock()
        if cache.count > 200 { cache.removeAll() }
        cache[key] = result
        lock.unlock()
        return result
    }

    // MARK: 正在写入判定

    /// 文件此刻是不是「还在被写入」。播放器打开片源只读，不会让文件变大；
    /// 下载器（qBittorrent 关了「.!qB 临时后缀」时就是最终文件名）、拷贝、转码会。
    /// 用它兜住那些认不出名字的下载客户端。
    private static var sizeWatch: [String: (size: Int64, at: Date)] = [:]
    private static let sizeLock = NSLock()

    static func isBeingWritten(_ path: String) -> Bool {
        // 外置卷不读属性：这里 stat 一下同样会让系统来问「能不能访问这个卷」，
        // 而它问一次就要你点一次（授权跟着构建签名走）。
        if onExternalVolume(path), !readExternal { return false }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        guard let attrs else { return false }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
        let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast
        let now = Date()

        sizeLock.lock()
        let prev = sizeWatch[path]
        if sizeWatch.count > 300 { sizeWatch.removeAll() }
        sizeWatch[path] = (size, now)
        sizeLock.unlock()

        // 上一轮（约 1 秒前）大小不同 → 正在下载
        if let prev, prev.size != size, now.timeIntervalSince(prev.at) < 20 { return true }
        // 刚写完的几秒内也别算播放：下载器常有「下完立刻播」的一串动作
        return now.timeIntervalSince(mtime) < 4
    }

    private func probeUncached(path: String) -> ProbeResult {
        if Log.enabled { Log.write("片源读取：\(path)") }
        let ext = (path as NSString).pathExtension.lowercased()
        if Self.avExtensions.contains(ext) {
            return Self.avFoundationProbe(path)
        }
        if Self.ebmlExtensions.contains(ext) {
            return Self.matroskaProbe(path)
        }
        return ProbeResult(verdict: .unknown, detail: "不支持的容器 .\(ext)")
    }

    private static func filenameVerdict(_ path: String) -> HDRVerdict? {
        let name = (path as NSString).lastPathComponent.lowercased()
        let tokens = Set(name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        if tokens.contains("hdr") || tokens.contains("hdr10") || tokens.contains("dovi")
            || tokens.contains("dv") || tokens.contains("hlg") || tokens.contains("pq") {
            return .hdr
        }
        if name.contains("hdr10+") || name.contains("dolbyvision") { return .hdr }
        return nil
    }

    // MARK: mp4 / mov

    private static func avFoundationProbe(_ path: String) -> ProbeResult {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path),
                               options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        let sem = DispatchSemaphore(value: 0)
        var descriptions: [CMFormatDescription] = []
        var codec = "?"

        asset.loadTracks(withMediaType: .video) { tracks, _ in
            guard let track = tracks?.first else { sem.signal(); return }
            track.loadValuesAsynchronously(forKeys: ["formatDescriptions"]) {
                descriptions = (track.formatDescriptions as? [CMFormatDescription]) ?? []
                if let fd = descriptions.first {
                    let sub = CMFormatDescriptionGetMediaSubType(fd)
                    let bytes = [UInt8((sub >> 24) & 0xff), UInt8((sub >> 16) & 0xff), UInt8((sub >> 8) & 0xff), UInt8(sub & 0xff)]
                    codec = String(bytes: bytes, encoding: .ascii) ?? "?"
                }
                sem.signal()
            }
        }
        _ = sem.wait(timeout: .now() + 1.2)

        guard let fd = descriptions.first,
              let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any] else {
            return ProbeResult(verdict: .unknown, detail: "读取视频轨失败")
        }

        var transfer = "", primaries = ""
        var mastering = false
        for (k, v) in ext {
            let key = "\(k)"
            let value = "\(v)"
            if key.contains("TransferFunction") { transfer = value }
            if key.contains("ColorPrimaries") { primaries = value }
            if key.contains("Mastering") || key.contains("ContentLight") { mastering = true }
        }

        let isPQ = transfer.contains("2084") || transfer.uppercased().contains("PQ")
        let isHLG = transfer.uppercased().contains("HLG") || transfer.contains("2100")
        let is2020 = primaries.contains("2020")

        if isPQ || isHLG {
            return ProbeResult(verdict: .hdr,
                               detail: "\(codec) · \(isPQ ? "PQ" : "HLG") · BT.2020\(mastering ? " · 含主控亮度" : "")",
                               evidence: .colorTags)
        }
        if is2020 {
            // BT.2020 色域 + BT.709 传输曲线 = 宽色域 SDR，不是 HDR（很多 SDR 母版这么做）
            let sdrTransfer = transfer.contains("709") || transfer.contains("SMPTE") || transfer.contains("240")
            return ProbeResult(verdict: sdrTransfer ? .sdr : .hdr,
                               detail: "\(codec) · BT.2020\(sdrTransfer ? " · SDR 传输曲线" : "")",
                               evidence: .colorTags)
        }
        if transfer.isEmpty && primaries.isEmpty {
            return ProbeResult(verdict: .unknown, detail: "\(codec) · 无色彩标记")
        }
        return ProbeResult(verdict: .sdr, detail: "\(codec) · \(primaries.isEmpty ? transfer : primaries)",
                           evidence: .colorTags)
    }

    // MARK: mkv / webm

    private static func matroskaProbe(_ path: String) -> ProbeResult {
        guard let fh = FileHandle(forReadingAtPath: path) else {
            return ProbeResult(verdict: .unknown, detail: "无法打开")
        }
        defer { try? fh.close() }
        // Tracks 一般在前几 MB 内，读 8MB 足够且不会拖慢
        let data = fh.readData(ofLength: 8 * 1024 * 1024)
        guard !data.isEmpty else { return ProbeResult(verdict: .unknown, detail: "文件为空") }
        let bytes = [UInt8](data)

        guard let track = Matroska.videoTrack(bytes) else {
            return ProbeResult(verdict: .unknown, detail: "mkv 里没找到视频轨")
        }

        // 路径一：容器里写了 Colour 元素（标准写法，最可信）
        if let t = track.transfer {
            return judge(transfer: Int(t), primaries: track.primaries.map { Int($0) }, mastering: track.hasMastering,
                         source: "容器标记", codec: track.codecName,
                         size: (track.width, track.height), depth: nil)
        }

        // 路径二：容器没写，去码流的 SPS/VUI 里找（WEB-DL 常见做法）
        if let cp = track.codecPrivate,
           let info = BitstreamColor.color(codec: track.codecID, codecPrivate: cp) {
            return judge(transfer: info.transfer < 0 ? nil : info.transfer,
                         primaries: info.primaries < 0 ? nil : info.primaries,
                         mastering: info.hasMastering, source: "码流标记", codec: track.codecName,
                         size: info.size, depth: info.bitDepth)
        }

        return ProbeResult(verdict: .unknown, detail: "mkv 未声明色彩信息")
    }

    private static func judge(transfer t: Int?, primaries p: Int?, mastering: Bool, source: String,
                              codec: String, size: (Int, Int), depth: Int?) -> ProbeResult {
        let isPQ = t == 16
        let isHLG = t == 18
        let is2020 = p == 9
        // BT.2020 色域不代表就是 HDR：宽色域 SDR 母版常用 2020 色域 + 709 传输曲线
        let sdrCurve = t == 1 || t == 6 || t == 7

        var tags: [String] = []
        if !codec.isEmpty { tags.append(codec) }
        if size.0 > 0 { tags.append("\(size.0)×\(size.1)") }
        if let d = depth { tags.append("\(d)bit") }
        if isPQ { tags.append("PQ") }
        if isHLG { tags.append("HLG") }
        if is2020 { tags.append("BT.2020" + (sdrCurve ? "(SDR 曲线)" : "")) }
        if let t = t, !isPQ, !isHLG { tags.append("传输特性\(t)") }
        if mastering { tags.append("含主控亮度") }
        tags.append(source)
        let detail = tags.joined(separator: " · ")

        if isPQ || isHLG || (is2020 && !sdrCurve) {
            return ProbeResult(verdict: .hdr, detail: detail, evidence: .colorTags)
        }

        if t == nil && p == nil {
            // 完全没有色彩标记：HDR 一定是 10bit 起步，所以 8bit 直接判定 SDR；
            // 1080p 及以下也基本可以认定 SDR（现实里没有 1080p 的 HDR 片源）
            let lowBit = (depth ?? 0) > 0 && (depth ?? 0) <= 8
            let smallFrame = size.0 > 0 && size.0 <= 1920
            if lowBit || smallFrame {
                return ProbeResult(verdict: .sdr,
                                   detail: detail + " · 按" + (lowBit ? "8bit" : "1080p") + "推定 SDR",
                                   evidence: .colorTags)
            }
            return ProbeResult(verdict: .unknown, detail: detail + " · 无色彩标记")
        }

        return ProbeResult(verdict: .sdr, detail: detail, evidence: .colorTags)
    }
}

// MARK: - Matroska（mkv / webm）结构解析

struct MatroskaTrack {
    var codecID = ""
    var codecName = ""
    var codecPrivate: [UInt8]?
    var transfer: UInt64?
    var primaries: UInt64?
    var matrix: UInt64?
    var hasMastering = false
    var width = 0
    var height = 0
}

enum Matroska {
    private static let segment: UInt64      = 0x18538067
    private static let tracks: UInt64       = 0x1654AE6B
    private static let trackEntry: UInt64   = 0xAE
    private static let video: UInt64        = 0xE0
    private static let colour: UInt64       = 0x55B0
    private static let transfer: UInt64     = 0x55B2
    private static let primaries: UInt64    = 0x55B3
    private static let matrix: UInt64       = 0x55B1
    private static let mastering: UInt64    = 0x55D0
    private static let codecIDElem: UInt64  = 0x86
    private static let codecPrivate: UInt64 = 0x63A2
    private static let pixelWidth: UInt64   = 0xB0
    private static let pixelHeight: UInt64  = 0xBA

    struct Element {
        let id: UInt64
        let start: Int
        let end: Int
    }

    /// 读元素 ID，返回 (值, 字节数)
    private static func readID(_ b: [UInt8], _ off: Int) -> (UInt64, Int)? {
        guard off < b.count else { return nil }
        let first = b[off]
        var len = 0
        for i in 0..<4 where first & (0x80 >> UInt8(i)) != 0 { len = i + 1; break }
        guard len > 0, off + len <= b.count else { return nil }
        var v: UInt64 = 0
        for i in 0..<len { v = (v << 8) | UInt64(b[off + i]) }
        return (v, len)
    }

    /// 读元素长度，返回 (值, 字节数, 是否未知长度)
    private static func readSize(_ b: [UInt8], _ off: Int) -> (UInt64, Int, Bool)? {
        guard off < b.count else { return nil }
        let first = b[off]
        var len = 0
        for i in 0..<8 where first & (0x80 >> UInt8(i)) != 0 { len = i + 1; break }
        guard len > 0, off + len <= b.count else { return nil }
        var v: UInt64 = UInt64(first) & (0xFF >> UInt8(len))
        for i in 1..<len { v = (v << 8) | UInt64(b[off + i]) }
        let allOnes = (UInt64(1) << UInt64(7 * len)) - 1
        return (v, len, v == allOnes)
    }

    /// 平铺同一层级的子元素
    static func elements(_ b: [UInt8], _ from: Int, _ to: Int, limit: Int = 4000) -> [Element] {
        var out: [Element] = []
        var off = from
        var n = 0
        while off < to - 2 && n < limit {
            n += 1
            guard let (id, idLen) = readID(b, off),
                  let (size, sizeLen, unknown) = readSize(b, off + idLen) else { break }
            let payload = off + idLen + sizeLen
            if payload > to { break }
            let end = unknown ? to : min(to, payload + Int(clamping: size))
            out.append(Element(id: id, start: payload, end: end))
            if unknown || end <= off { break }
            off = end
        }
        return out
    }

    private static func uintValue(_ b: [UInt8], _ e: Element) -> UInt64 {
        var v: UInt64 = 0
        var i = e.start
        while i < min(e.end, e.start + 8) { v = (v << 8) | UInt64(b[i]); i += 1 }
        return v
    }

    private static func intValue(_ b: [UInt8], _ e: Element) -> Int {
        Int(clamping: uintValue(b, e))
    }

    private static func ascii(_ b: [UInt8], _ e: Element) -> String {
        guard e.start < e.end, e.end <= b.count else { return "" }
        return String(bytes: b[e.start..<e.end], encoding: .utf8) ?? ""
    }

    private static func codecName(_ id: String) -> String {
        let u = id.uppercased()
        if u.contains("HEVC") || u.contains("H265") { return "HEVC" }
        if u.contains("AVC")  || u.contains("H264") { return "H.264" }
        if u.contains("AV1")  { return "AV1" }
        if u.contains("VP9")  { return "VP9" }
        if u.contains("VP8")  { return "VP8" }
        return id.replacingOccurrences(of: "V_MPEG4/ISO/", with: "")
                 .replacingOccurrences(of: "V_MPEGH/ISO/", with: "")
                 .replacingOccurrences(of: "V_MPEG/", with: "")
    }

    /// 找到第一条视频轨
    static func videoTrack(_ b: [UInt8]) -> MatroskaTrack? {
        guard let seg = elements(b, 0, b.count).first(where: { $0.id == segment }) else { return nil }
        var firstVideo: MatroskaTrack?

        for t in elements(b, seg.start, seg.end) where t.id == tracks {
            for entry in elements(b, t.start, t.end) where entry.id == trackEntry {
                var tr = MatroskaTrack()
                var hasVideo = false

                for child in elements(b, entry.start, entry.end) {
                    switch child.id {
                    case codecIDElem:
                        tr.codecID = ascii(b, child)
                    case codecPrivate:
                        tr.codecPrivate = Array(b[child.start..<child.end])
                    case video:
                        hasVideo = true
                        for v in elements(b, child.start, child.end) {
                            switch v.id {
                            case pixelWidth:  tr.width = intValue(b, v)
                            case pixelHeight: tr.height = intValue(b, v)
                            case colour:
                                for c in elements(b, v.start, v.end) {
                                    switch c.id {
                                    case transfer:  tr.transfer = uintValue(b, c)
                                    case primaries: tr.primaries = uintValue(b, c)
                                    case matrix:    tr.matrix = uintValue(b, c)
                                    case mastering: tr.hasMastering = true
                                    default: break
                                    }
                                }
                            default: break
                            }
                        }
                    default: break
                    }
                }

                guard hasVideo else { continue }
                tr.codecName = codecName(tr.codecID)
                // 优先返回带色彩信息或参数集的视频轨
                if tr.transfer != nil || tr.codecPrivate != nil { return tr }
                if firstVideo == nil { firstVideo = tr }
            }
        }
        return firstVideo
    }
}

// MARK: - 从码流参数集（SPS/VUI）读色彩信息

/// 很多 WEB-DL 的 mkv 不在容器里写 Colour，色彩信息只存在于 HEVC/H.264 的 SPS 中。
/// 这里直接解析 hvcC / avcC 里携带的 SPS，读 VUI 的 colour_primaries / transfer_characteristics。
struct BitstreamColor {
    let transfer: Int
    let primaries: Int
    let matrix: Int
    let size: (Int, Int)
    let bitDepth: Int?
    let hasMastering: Bool

    static func color(codec: String, codecPrivate cp: [UInt8]) -> BitstreamColor? {
        let u = codec.uppercased()
        if u.contains("HEVC") || u.contains("H265") {
            return hevc(cp)
        }
        if u.contains("AVC") || u.contains("H264") {
            return avc(cp)
        }
        return nil
    }

    // MARK: HEVC（hvcC）

    private static func hevc(_ cp: [UInt8]) -> BitstreamColor? {
        guard cp.count > 23, cp[0] == 1 else { return nil }
        var pos = 22
        let arrays = Int(cp[pos]); pos += 1
        var spsList: [[UInt8]] = []

        for _ in 0..<arrays {
            guard pos + 3 <= cp.count else { break }
            let nalType = cp[pos] & 0x3F
            let count = (Int(cp[pos + 1]) << 8) | Int(cp[pos + 2])
            pos += 3
            for _ in 0..<count {
                guard pos + 2 <= cp.count else { break }
                let len = (Int(cp[pos]) << 8) | Int(cp[pos + 1])
                pos += 2
                guard len > 0, pos + len <= cp.count else { break }
                if nalType == 33 { spsList.append(Array(cp[pos..<pos + len])) }
                pos += len
            }
        }

        for sps in spsList {
            if let r = hevcSPS(sps) { return r }
        }
        return nil
    }

    private static func hevcSPS(_ nal: [UInt8]) -> BitstreamColor? {
        let d = rbsp(nal)
        guard d.count > 8 else { return nil }
        var br = BitReader(Array(d.dropFirst(2)))

        do {
            _ = try br.u(4)                       // sps_video_parameter_set_id
            let maxSub = try br.u(3)              // sps_max_sub_layers_minus1
            _ = try br.u(1)
            try hevcProfileTierLevel(&br, maxSub)
            _ = try br.ue()                       // sps_seq_parameter_set_id
            let chroma = try br.ue()
            if chroma == 3 { _ = try br.u(1) }
            let w = try br.ue(), h = try br.ue()
            var cropL = 0, cropR = 0, cropT = 0, cropB = 0
            if try br.u(1) == 1 {
                cropL = try br.ue(); cropR = try br.ue(); cropT = try br.ue(); cropB = try br.ue()
            }
            let bdLuma = try br.ue() + 8
            _ = try br.ue() + 8
            let log2poc = try br.ue() + 4
            let orderingPresent = try br.u(1)
            let start = orderingPresent == 1 ? 0 : maxSub
            if start <= maxSub {
                for _ in start...maxSub { _ = try br.ue(); _ = try br.ue(); _ = try br.ue() }
            }
            _ = try br.ue(); _ = try br.ue(); _ = try br.ue(); _ = try br.ue()
            _ = try br.ue(); _ = try br.ue()
            if try br.u(1) == 1 {                 // scaling_list_enabled_flag
                if try br.u(1) == 1 { try hevcScalingList(&br) }
            }
            _ = try br.u(1)                       // amp_enabled_flag
            _ = try br.u(1)                       // sample_adaptive_offset_enabled_flag
            if try br.u(1) == 1 {                 // pcm_enabled_flag
                try br.skip(4); try br.skip(4)
                _ = try br.ue(); _ = try br.ue(); _ = try br.u(1)
            }
            let numSets = try br.ue()
            guard numSets >= 0, numSets < 128 else { return nil }
            var counts: [Int] = []
            for i in 0..<numSets { try stRefPicSet(&br, idx: i, numSets: numSets, counts: &counts) }
            if try br.u(1) == 1 {                 // long_term_ref_pics_present_flag
                let n = try br.ue()
                guard n >= 0, n < 64 else { return nil }
                for _ in 0..<n { try br.skip(log2poc); _ = try br.u(1) }
            }
            _ = try br.u(1)                       // sps_temporal_mvp_enabled_flag
            _ = try br.u(1)                       // strong_intra_smoothing_enabled_flag

            let subW = chroma == 1 ? 2 : (chroma == 2 ? 2 : 1)
            let subH = chroma == 1 ? 2 : (chroma == 2 ? 1 : 1)
            let width = w - (cropL + cropR) * subW
            let height = h - (cropT + cropB) * subH

            if try br.u(1) == 1, let c = try vuiColour(&br) {   // vui_parameters_present_flag
                return BitstreamColor(transfer: c.transfer, primaries: c.primaries,
                                      matrix: c.matrix, size: (width, height),
                                      bitDepth: bdLuma, hasMastering: false)
            }
            // 没有 VUI、或 VUI 没写色彩：仍然把尺寸/位深带回去，
            // 上层可以据此按「8bit / 1080p = SDR」保守判定，而不是一律当未知
            return BitstreamColor(transfer: -1, primaries: -1, matrix: -1,
                                  size: (width, height), bitDepth: bdLuma, hasMastering: false)
        } catch {
            return nil
        }
    }

    private static func hevcProfileTierLevel(_ br: inout BitReader, _ maxSub: Int) throws {
        try br.skip(2 + 1 + 5)      // profile_space / tier_flag / profile_idc
        try br.skip(32)             // compatibility flags
        try br.skip(4 + 43 + 1)     // progressive... + 43 reserved + 1
        try br.skip(8)              // general_level_idc
        guard maxSub > 0 else { return }
        var subProfile = [Bool](repeating: false, count: maxSub)
        var subLevel = [Bool](repeating: false, count: maxSub)
        for i in 0..<maxSub {
            subProfile[i] = try br.u(1) == 1
            subLevel[i] = try br.u(1) == 1
        }
        if maxSub > 0 {
            for _ in maxSub..<8 { try br.skip(2) }
        }
        for i in 0..<maxSub {
            if subProfile[i] { try br.skip(88) }
            if subLevel[i] { try br.skip(8) }
        }
    }

    private static func hevcScalingList(_ br: inout BitReader) throws {
        for sizeID in 0..<4 {
            let step = sizeID == 3 ? 3 : 1
            for _ in stride(from: 0, to: 6, by: step) {
                if try br.u(1) == 0 {
                    _ = try br.ue()
                } else {
                    if sizeID > 1 { _ = try br.se() }
                    let coefNum = min(64, 1 << (4 + (sizeID << 1)))
                    for _ in 0..<coefNum { _ = try br.se() }
                }
            }
        }
    }

    private static func stRefPicSet(_ br: inout BitReader, idx: Int, numSets: Int, counts: inout [Int]) throws {
        var inter = false
        if idx != 0 { inter = try br.u(1) == 1 }
        if inter {
            if idx == numSets { _ = try br.ue() }
            _ = try br.u(1)
            _ = try br.ue()
            let ref = idx - 1 < counts.count ? counts[max(idx - 1, 0)] : 0
            var cnt = 0
            for _ in 0...ref {
                if try br.u(1) == 1 { cnt += 1 }
                else if try br.u(1) == 1 { cnt += 1 }
            }
            counts.append(cnt)
        } else {
            let neg = try br.ue(), pos = try br.ue()
            guard neg >= 0, neg < 64, pos >= 0, pos < 64 else { throw BitReader.Err.bad }
            for _ in 0..<neg { _ = try br.ue(); _ = try br.u(1) }
            for _ in 0..<pos { _ = try br.ue(); _ = try br.u(1) }
            counts.append(neg + pos)
        }
    }

    // MARK: H.264（avcC）

    private static func avc(_ cp: [UInt8]) -> BitstreamColor? {
        guard cp.count > 7, cp[0] == 1 else { return nil }
        let numSPS = Int(cp[5] & 0x1F)
        var pos = 6
        var spsList: [[UInt8]] = []
        for _ in 0..<numSPS {
            guard pos + 2 <= cp.count else { break }
            let len = (Int(cp[pos]) << 8) | Int(cp[pos + 1])
            pos += 2
            guard len > 0, pos + len <= cp.count else { break }
            spsList.append(Array(cp[pos..<pos + len]))
            pos += len
        }
        for sps in spsList {
            if let r = avcSPS(sps) { return r }
        }
        return nil
    }

    private static func avcSPS(_ nal: [UInt8]) -> BitstreamColor? {
        let d = rbsp(nal)
        guard d.count > 6 else { return nil }
        var br = BitReader(Array(d.dropFirst(1)))

        do {
            let profile = try br.u(8)
            try br.skip(8)                 // constraint flags
            _ = try br.u(8)                // level_idc
            _ = try br.ue()                // seq_parameter_set_id

            let highProfile = [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135]
            var bdLuma = 8
            if highProfile.contains(profile) {
                let chroma = try br.ue()
                if chroma == 3 { try br.skip(1) }
                bdLuma = try br.ue() + 8   // bit_depth_luma_minus8
                _ = try br.ue()            // bit_depth_chroma_minus8
                try br.skip(1)             // qpprime_y_zero_transform_bypass
                if try br.u(1) == 1 { return nil }   // 有缩放矩阵，放弃（罕见）
            }
            _ = try br.ue()                // log2_max_frame_num_minus4
            let pocType = try br.ue()
            if pocType == 0 {
                _ = try br.ue()
            } else if pocType == 1 {
                try br.skip(1)
                _ = try br.se(); _ = try br.se()
                let n = try br.ue()
                guard n >= 0, n < 256 else { return nil }
                for _ in 0..<n { _ = try br.se() }
            }
            _ = try br.ue()                // max_num_ref_frames
            try br.skip(1)                 // gaps_in_frame_num_value_allowed
            let wMbs = try br.ue() + 1
            let hMap = try br.ue() + 1
            let frameOnly = try br.u(1)
            if frameOnly == 0 { try br.skip(1) }
            try br.skip(1)                 // direct_8x8_inference
            var cropL = 0, cropR = 0, cropT = 0, cropB = 0
            if try br.u(1) == 1 {
                cropL = try br.ue(); cropR = try br.ue(); cropT = try br.ue(); cropB = try br.ue()
            }
            let width = wMbs * 16 - (cropL + cropR) * 2
            let height = (2 - frameOnly) * hMap * 16 - (cropT + cropB) * 2

            if try br.u(1) == 1, let c = try vuiColour(&br) {   // vui_parameters_present_flag
                return BitstreamColor(transfer: c.transfer, primaries: c.primaries,
                                      matrix: c.matrix, size: (width, height),
                                      bitDepth: bdLuma, hasMastering: false)
            }
            // 没有 VUI / VUI 没写色彩 → 仍带回尺寸与位深，交上层保守判断
            return BitstreamColor(transfer: -1, primaries: -1, matrix: -1,
                                  size: (width, height), bitDepth: bdLuma, hasMastering: false)
        } catch {
            return nil
        }
    }

    // MARK: 公共 VUI

    private static func vuiColour(_ br: inout BitReader) throws -> (transfer: Int, primaries: Int, matrix: Int)? {
        if try br.u(1) == 1 {                        // aspect_ratio_info_present_flag
            let ar = try br.u(8)
            if ar == 255 { try br.skip(16); try br.skip(16) }
        }
        if try br.u(1) == 1 { _ = try br.u(1) }      // overscan_info_present_flag
        guard try br.u(1) == 1 else { return nil }   // video_signal_type_present_flag
        _ = try br.u(3)                              // video_format
        _ = try br.u(1)                              // video_full_range_flag
        guard try br.u(1) == 1 else { return nil }   // colour_description_present_flag
        let primaries = try br.u(8)
        let transfer = try br.u(8)
        let matrix = try br.u(8)
        guard transfer != 2, primaries != 2 else { return nil }   // 2 = 未指定
        return (transfer, primaries, matrix)
    }

    // MARK: 工具

    private static func rbsp(_ nal: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(nal.count)
        var i = 0
        while i < nal.count {
            if i + 2 < nal.count && nal[i] == 0 && nal[i + 1] == 0 && nal[i + 2] == 3 {
                out.append(0); out.append(0)
                i += 3
            } else {
                out.append(nal[i])
                i += 1
            }
        }
        return out
    }
}

/// 按位读取（H.264/H.265 的参数集用 bit 级语法）
struct BitReader {
    enum Err: Error { case eof, bad }

    private let d: [UInt8]
    private var p = 0

    init(_ d: [UInt8]) { self.d = d }

    var bitsLeft: Int { d.count * 8 - p }

    mutating func u(_ n: Int) throws -> Int {
        guard n >= 0, n <= 32 else { throw Err.bad }
        var v = 0
        for _ in 0..<n {
            guard p >> 3 < d.count else { throw Err.eof }
            let bit = (d[p >> 3] >> UInt8(7 - (p & 7))) & 1
            v = (v << 1) | Int(bit)
            p += 1
        }
        return v
    }

    mutating func skip(_ n: Int) throws {
        guard n >= 0, p + n <= d.count * 8 else { throw Err.eof }
        p += n
    }

    mutating func ue() throws -> Int {
        var z = 0
        while try u(1) == 0 {
            z += 1
            if z > 31 { throw Err.bad }
        }
        guard z > 0 else { return 0 }
        return (1 << z) - 1 + (try u(z))
    }

    mutating func se() throws -> Int {
        let k = try ue()
        return k % 2 == 1 ? (k + 1) / 2 : -(k / 2)
    }
}

// MARK: - 腾讯视频（QQLive）在播内容的画质
//
// 腾讯视频 Mac 版是原生播放器（TVKPlayer 内核），既没有本地文件句柄，也不是
// 网页 —— 「读容器色彩」和「回页面问一句」这两条路都用不上。
//
// 但它的播放内核会把**内容级**的 HDR 判定写进自己的日志：
//     frame hdr info changed, ... ==> hdr type=HDRVivid, hdr mapping type=HardwareHDR10StaticMapping
//     updateSubtitleRenderMode. isHDRVideo=1 fileid=322108
// SDR 内容对应 `hdr type=None` / `isHDRVideo=0`。
//
// 要特别小心日志开头那一批 `HDR Cap Query: HDRVivid ... -> Supported`：那是
// **设备能力查询**（这台机器支不支持 HDR），跟正在放什么内容毫无关系。
// 拿它当判据的话，只要打开腾讯视频就会判成 HDR。所以这里只认上面两种
// 「内容级」记录，能力查询的行一个字都不看。

enum TencentVideoProbe {
    static let bundleID = "com.tencent.tenvideo"

    /// 第一次看到某个日志时，从文件尾部回读这么多建立基线。
    ///
    /// 必须覆盖整个文件：播放内核的单个日志上限约 5MB，而「内容判定」可能
    /// 只在开播那一刻打一条 —— 只读尾部 2MB 的话，播久了那条判定就落到窗口
    /// 外面，进程重启后又从头判，于是「明明在播 HDR 却报读不到」。全读 5MB
    /// 只在首次见到该文件时发生一次，之后都走增量。
    private static let seedBytes: UInt64 = 8_000_000

    /// 实例级 HDR 判定算数多久。
    ///
    /// 8 秒：关片时腾讯视频经常不发 `kStop`（直接切到别的内容），这时只能靠
    /// 「这个实例不再输出日志」来判定。窗口给太长，HDR 就会一直挂着不回落。
    /// 暂停不怕 —— 暂停时由内容标志 `isHDRVideo` 兜住。
    private static let hdrWindow: TimeInterval = 8

    /// 内容标志 `isHDRVideo=1` 的有效期。
    ///
    /// 这个标志只在「内容切换」时打一条，不随时间刷新，所以不能给短窗口
    /// （暂停半小时也不该掉色）。关片 / 换片时它会立刻被刷成 0，那时
    /// `flagAt` 会被清空，走不到这里。10 分钟只是兜底「App 异常退出、
    /// 没来得及刷 0」的残留，和日志文件的活跃窗口一致。
    private static let flagLifetime: TimeInterval = 600

    /// 一个播放实例的状态。
    ///
    /// 腾讯视频在**同一个日志文件**里同时输出十几个播放器实例：首页每个推荐位
    /// 各有一个自动预览，详情页预览一个，正式播放一个。活跃时有 1000+ 行/实例。
    /// 它们的 `hdr type` 判定混在一起 —— 正片在 `tpcore24` 判出 HDRVivid，
    /// 十几秒后首页预览 `tpcore26` 又打一条 `None`。如果只取「最后一条判定」，
    /// 正片的 HDR 会被预览的 None 盖掉，永远判成 SDR。
    ///
    /// 所以按实例隔离：每个实例自己一条判定、自己的停止时间，最后再看谁在播。
    private struct InstanceState {
        /// 最后一次内容判定的时间和结论
        var at: Date?
        var verdict: HDRVerdict?
        var detail = ""
        /// 该实例最后一次出现在日志里的时间 —— 判定只在「变化时」打一条，
        /// 播十分钟也不会再打，所以判断「还在不在播」只能看这个。
        var lastSeen: Date?
        /// 解码器销毁 / 停止播放
        var stopped: Date?
    }

    /// 每个日志文件的续读状态。`offset` 是已经消费到的位置。
    private struct FileState {
        var offset: UInt64 = 0
        var seeded = false
        /// `tpplayerN_tpcoreM` → 该实例的状态
        var instances: [String: InstanceState] = [:]
        /// 全局兜底：`isHDRVideo` 那行不带实例标识，只能整个文件记一条
        var verdict: HDRVerdict?
        var detail = ""
        var at: Date?
        /// `isHDRVideo=1` —— 内容层面的 HDR 标志，单独记。
        ///
        /// 这跟 `hdr type` 是两件事：`hdr type` 反映**渲染输出**，显示器没开
        /// HDR 时播放器会把 HDR 内容 tone-map 成 SDR，`hdr type` 就报 None；
        /// 而 `isHDRVideo` 说的是**这一片有没有 HDR 版本**，跟显示器无关。
        /// 正因如此，它才是「该不该开 HDR」的正确判据 —— 拿 `hdr type` 当判据
        /// 会锁死：不开 HDR 就读不到 HDR，读不到 HDR 就不开 HDR。
        ///
        /// **注意**：这个标志约每 30 秒重刷一次，关片 / 换片时会立刻被刷成 0。
        /// 所以它必须能被「取消」—— 只记时间不给取消，关掉 HDR 片之后它会靠
        /// 一段新鲜期一直成立，屏幕也就一直不回落。
        var flagAt: Date?
        /// 见过 `isHDRVideo` 行没有 —— 决定「`hdr type=None` 敢不敢当真」
        var flagSeen = false
        /// 最近一次「解码器销毁 / 停止播放」的时间，比判定晚就说明片子已停
        var stopped: Date?
    }

    private static var files: [String: FileState] = [:]

    private static var cache: (at: Date, result: ProbeResult?)?
    private static let lock = NSLock()

    /// 日志目录读得到吗？
    ///
    /// 腾讯视频把日志写在自己的沙盒容器里，而 macOS 会拦「读别的 App 容器」——
    /// 需要「完全磁盘访问权限」。从终端跑 CLI 会继承终端的权限所以一切正常，
    /// 菜单栏 App 自己跑就一个文件都看不到，这个差异极难靠猜定位，所以要显式暴露。
    static func canRead() -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: logDir)) != nil
    }

    /// 日志目录（App 沙盒容器内，同用户可读）
    static var logDir: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Containers/com.tencent.tenvideo/Data/Library/Logs")
    }

    /// 日志行首时间戳（`2026-10-30 20:10:08.885`）→ Date。只解析命中的那几行，
    /// 开销可以忽略；一行几万条的全量解析才需要担心。
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    private static func time(of line: String) -> Date? {
        guard line.count >= 23 else { return nil }
        return stamp.date(from: String(line.prefix(23)))
    }

    /// 播放内核是「一个播放实例一个日志文件」—— 首页预览、详情页预览、正式
    /// 播放各开一个，同时躺着好几个。只挑 mtime 最新的那个会挑错（刚关掉预览
    /// 窗口，它的文件反而最新）。所以把最近改过的都读一遍，取时间最靠后的判定。
    private static func recentLogs(within seconds: TimeInterval = 600) -> [String] {
        let dir = logDir
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: dir)
        } catch {
            // 读不到目录时把原因记下来：最常见的是没有「完全磁盘访问权限」——
            // 从终端跑 CLI 会继承终端的权限，所以命令行一切正常、菜单栏 App 却
            // 一个文件都看不到，这个差异极难靠猜定位。
            if Log.enabled { Log.write("  腾讯日志目录不可读: \(error.localizedDescription) · \(dir)") }
            return []
        }
        let files = names
        let now = Date()
        var out: [(path: String, at: Date)] = []
        for f in files where f.hasPrefix("TVKPlayer SDK") && f.hasSuffix(".log") {
            let p = (logDir as NSString).appendingPathComponent(f)
            guard let a = try? FileManager.default.attributesOfItem(atPath: p),
                  let m = a[.modificationDate] as? Date,
                  now.timeIntervalSince(m) < seconds else { continue }
            out.append((p, m))
        }
        return out.sorted { $0.at > $1.at }.prefix(4).map(\.path)
    }

    /// 从 `from` 读到文件末尾，返回文本和新的末尾位置。
    private static func readChunk(_ h: FileHandle, from: UInt64, to end: UInt64) -> String? {
        guard end > from else { return "" }
        do { try h.seek(toOffset: from) } catch { return nil }
        guard let data = try? h.read(upToCount: Int(end - from)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 当前播放内容的画质。读不到（日志不在 / 没权限 / 没在播）时返回 nil。
    static func probe() -> ProbeResult? {
        lock.lock()
        if let c = cache, Date().timeIntervalSince(c.at) < 1.0 {
            let hit = c.result
            lock.unlock()
            return hit
        }
        lock.unlock()

        let result = refresh()

        lock.lock()
        cache = (Date(), result)
        lock.unlock()
        return result
    }

    /// 把每个活跃日志里新增的内容读进来，更新各自的状态，再挑出全局最新的一条。
    private static func refresh() -> ProbeResult? {
        let live = recentLogs()

        // 已经不活跃的日志，状态一起丢掉，免得下次重开时接着用陈旧偏移
        for k in files.keys where !live.contains(k) { files[k] = nil }

        for path in live {
            var st = files[path] ?? FileState()
            guard let h = FileHandle(forReadingAtPath: path) else { continue }
            defer { try? h.close() }
            guard let size = try? h.seekToEnd() else { continue }

            // 第一次见 / 文件被轮转变小了 → 从尾部重建基线
            if !st.seeded || size < st.offset {
                st = FileState()
                st.offset = size > seedBytes ? size - seedBytes : 0
                st.seeded = true
            }
            guard size > st.offset else { files[path] = st; continue }

            guard let text = readChunk(h, from: st.offset, to: size) else { continue }
            // 回退一点点，容忍上一块末尾被截断的半行；重复消费是幂等的
            st.offset = size > 200 ? size - 200 : 0
            consume(text, into: &st)
            files[path] = st
        }

        // 先把「还在播、且判过 HDR」的实例挑出来。
        //
        // 优先级高于「最近一条判定」：正片判 HDR 后，首页预览会不断打 None，
        // 按时间取最新永远是 None。只有「该实例没停 + 最近还在输出日志」才能
        // 说明它真的在播 —— 一旦关片，腾讯视频会给这个实例发 kStop，或者它
        // 直接不再出日志，两种都会让它掉出这个集合。
        let now = Date()
        var hdrHit: (at: Date, result: ProbeResult)?
        var liveHit: (at: Date, result: ProbeResult)?

        // 按路径排序再遍历：字典无序，两个实例 lastSeen 相同（同一毫秒）时
        // 谁先被遇到会让结论在两次运行间跳，先排一下保证稳定。
        for (_, st) in files.sorted(by: { $0.key < $1.key }) {
            for inst in st.instances.values {
                // 已停止的实例不算
                if let s = inst.stopped, let a = inst.at, s > a { continue }
                if inst.stopped != nil, inst.at == nil { continue }

                guard let seen = inst.lastSeen else { continue }

                // 实例级 HDR 只在「它最近还在输出日志」时才算数。
                // 窗口压到 8 秒：关片时腾讯视频经常不发 kStop（直接切走内容），
                // 这时只能靠「不再出日志」来判定，窗口太长会让 HDR 一直挂着。
                // 暂停不受影响 —— 暂停时内容标志 `isHDRVideo` 仍会周期刷新，
                // 由下面那一层兜住。
                if let v = inst.verdict, let at = inst.at,
                   v == .hdr, now.timeIntervalSince(seen) < hdrWindow,
                   hdrHit == nil || at > hdrHit!.at {
                    hdrHit = (at, ProbeResult(verdict: v, detail: inst.detail, evidence: .appLog))
                }
                if liveHit == nil || seen > liveHit!.at {
                    var v = inst.verdict ?? .unknown
                    var detail = inst.verdict == nil ? "腾讯视频 · 正在播放" : inst.detail
                    // `hdr type=None` 只代表「渲染成了 SDR」：显示器没开 HDR 时，
                    // HDR 片源也会渲成 SDR。没有 `isHDRVideo` 佐证就不敢当 SDR，
                    // 否则会「看到 None → 关 HDR → 永远读不到 HDR」自己锁死。
                    if v == .sdr, !st.flagSeen {
                        v = .unknown
                        detail = "腾讯视频 · 正在播放（画质未知）"
                    }
                    // 实例还没打判定（刚起播那一两秒）时，用主内容标志补：
                    // 它说的是「这一片是 HDR / 是 SDR」，比实例更早就有结论。
                    // 不补的话这里会吐「未知」，上层走「保持 HDR」并顺手刷新
                    // 计时，而回落靠的正是这个计时 —— 于是一直回不去。
                    if v == .unknown, let fv = st.verdict, let fa = st.at,
                       now.timeIntervalSince(fa) < 60 {
                        v = fv
                        detail = st.detail
                    }
                    // 主内容已经被清空（关片回首页时 `isHDRVideo` 刷成 null，
                    // 于是 `st.at` 归 nil），此刻还在出日志的只剩首页推荐位的
                    // 自动预览 —— 那些永远是 SDR。判「未知」会让上层一直走
                    // 「保持 HDR」，屏幕就再也回不来了。
                    if v == .unknown, st.flagSeen, st.at == nil {
                        v = .sdr
                        detail = "腾讯视频 · 已结束（仅首页预览）"
                    }
                    liveHit = (seen, ProbeResult(verdict: v, detail: detail, evidence: .appLog))
                }
            }
        }

        if let hit = hdrHit { return hit.result }

        if Log.enabled {
            let desc = files.map { k, v in
                "\(((k as NSString).lastPathComponent).suffix(17))=\(v.offset)/\(v.instances.count)"
            }.joined(separator: " ")
            Log.write("  腾讯日志: live=\(live.count) 缓存=\(files.count) [\(desc)]")
        }

        // 没有实例级 HDR 判定，退一步看内容标志。
        //
        // 这是打破死锁的那一步：显示器没开 HDR 时，即使片源是 HDR，播放器
        // 也只报 `hdr type=None`（它渲成了 SDR）。只有 `isHDRVideo=1` 能说明
        // 「这片有 HDR 版本」。首页预览永远是 0，所以看到 1 就说明有 HDR 内容在播。
        //
        // 这里**不再要求「实例最近还在写日志」**：暂停时播放器会停止输出，
        // 实例看着就「不动了」，但片子还开着，HDR 不该收。判断内容是否结束
        // 交给 `isHDRVideo` 归零（关片时它会被刷成 0 / null）。
        for (_, st) in files.sorted(by: { $0.key < $1.key }) {
            guard let at = st.flagAt, now.timeIntervalSince(at) < flagLifetime else { continue }
            return ProbeResult(verdict: .hdr, detail: "腾讯视频 · HDR", evidence: .appLog)
        }

        if let hit = liveHit { return hit.result }

        // 没有任何实例判定 → 用 `isHDRVideo` 兜底（老逻辑）
        var best: (at: Date, result: ProbeResult)?
        for st in files.values {
            guard let at = st.at, let v = st.verdict else { continue }
            if let s = st.stopped, s > at { continue }
            if best == nil || at > best!.at {
                best = (at, ProbeResult(verdict: v, detail: st.detail, evidence: .appLog))
            }
        }
        return best?.result
    }

    /// 从日志行里取出播放实例标识，例如 `[TVKPlayer_C1021_T10000_tpplayer27_tpcore26]`
    /// → `tpplayer27_tpcore26`。取不到（tpdlcore / 字幕模块那些行）返回 nil。
    private static func instanceID(_ line: String) -> String? {
        guard let r = line.range(of: "tpplayer") else { return nil }
        let rest = line[r.lowerBound...]
        guard let end = rest.firstIndex(of: "]") else { return nil }
        return String(rest[..<end])
    }

    /// 消费一段日志文本（可能是从文件中间切进去的，首行是残行 ——
    /// 用「行首能不能解析出时间戳」自然把它筛掉）。
    private static func consume(_ text: String, into st: inout FileState) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(line)
            guard let t = time(of: line) else { continue }

            let inst = instanceID(line)
            let isStop = line.contains("Destructor. media_type:kVideo") || line.contains("id:kStop")

            // 任何带实例标识的行都算「这个实例还活着」
            if let id = inst {
                var s = st.instances[id] ?? InstanceState()
                if s.lastSeen == nil || t > s.lastSeen! { s.lastSeen = t }
                if isStop, s.stopped == nil || t > s.stopped! { s.stopped = t }

                if line.contains("frame hdr info changed"),
                   let r = line.range(of: "==> hdr type=") {
                    let cut = line[r.upperBound...].prefix { $0 != "," }
                    let v = cut.trimmingCharacters(in: .whitespaces)
                    if !v.isEmpty, s.at == nil || t >= s.at! {
                        let isSDR = (v == "None")
                        s.verdict = isSDR ? .sdr : .hdr
                        s.detail = isSDR ? "腾讯视频 · SDR" : "腾讯视频 · \(v)"
                        s.at = t
                    }
                }
                st.instances[id] = s
            }

            // `isHDRVideo` 约每 30 秒重刷一次，带当前主内容的 fileid；这一行
            // 不带实例标识（是字幕渲染模块打的），只能整个文件记一条。
            //
            // 它有两种「归零」：`fileid=真实ID` 表示主内容换成了 SDR，
            // `fileid=(null)` 表示主内容没了（关片回首页）。两种都必须把
            // `isHDRVideo=1` 的记录作废 —— 否则关掉 HDR 片之后那条记录会靠
            // 新鲜期一直成立，首页预览又把 session 撑着，屏幕就一直不回落。
            if line.contains("isHDRVideo="),
               let r = line.range(of: "isHDRVideo="),
               let n = Int(line[r.upperBound...].prefix(1)) {
                st.flagSeen = true
                let cleared = line.contains("fileid=(null)")
                if n == 1 {
                    st.flagAt = t
                    st.verdict = .hdr
                    st.detail = "腾讯视频 · HDR"
                    st.at = t
                } else {
                    st.flagAt = nil
                    if cleared {
                        // 主内容清空：这条片子已经结束，别拿旧结论兜底
                        st.verdict = nil
                        st.at = nil
                    } else if t >= (st.at ?? .distantPast) {
                        st.verdict = .sdr
                        st.detail = "腾讯视频 · SDR"
                        st.at = t
                    }
                }
            }
            // 解码器销毁 / 播放卡在停止指令上：这之后没有新的内容判定，
            // 说明片子已经停了 —— 不能拿上一次的 HDR 一直挂着。
            if isStop {
                st.stopped = t
            }
        }
    }

    /// 日志里最近还有实例在输出？用来补「没有防休眠断言但在播」的情况。
    ///
    /// 腾讯视频不是每次都持断言 —— 实测播广告 / 部分内容时整段都没有
    /// `NoDisplaySleepAssertion`，播放位置却一直在往前走。只看断言会把它
    /// 判成「已暂停」，于是永远不切。
    static func isLive(_ seconds: TimeInterval = 8) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        for st in files.values {
            for inst in st.instances.values {
                guard let seen = inst.lastSeen, now.timeIntervalSince(seen) < seconds else { continue }
                // 已停止的实例不算
                if let s = inst.stopped, s >= (inst.at ?? .distantPast) { continue }
                return true
            }
        }
        return false
    }

    /// 刚刚停止播放？用来「立刻回落」—— 关掉片子不必再等满宽限期。
    /// 只认「停止时间晚于最后一次内容判定」的那种，避免几十年前的旧记录也命中。
    static func stoppedRecently(_ seconds: TimeInterval = 20) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        for st in files.values {
            // 实例级：某个正在播 HDR 的实例刚停 —— 这才是真的关片
            for inst in st.instances.values {
                guard let s = inst.stopped, now.timeIntervalSince(s) < seconds else { continue }
                if inst.at == nil || s > inst.at! { return true }
            }
            guard let s = st.stopped, now.timeIntervalSince(s) < seconds else { continue }
            if st.at == nil || s > st.at! { return true }
        }
        return false
    }
}

// MARK: - MediaRemote（系统「正在播放」）

enum MediaRemote {
    private typealias PlayingFn = @convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void
    private typealias PidFn = @convention(c) (DispatchQueue, @escaping @convention(block) (Int32) -> Void) -> Void

    private static let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY)
    private static let playingFn: PlayingFn? = {
        guard let h = handle, let p = dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") else { return nil }
        return unsafeBitCast(p, to: PlayingFn.self)
    }()
    private static let pidFn: PidFn? = {
        guard let h = handle, let p = dlsym(h, "MRMediaRemoteGetNowPlayingApplicationPID") else { return nil }
        return unsafeBitCast(p, to: PidFn.self)
    }()

    static var available: Bool { playingFn != nil && pidFn != nil }

    private static var cachedPlaying: (value: Bool, at: Date)?
    private static var cachedPid: (value: Int32, at: Date)?

    static func isPlaying() -> Bool? {
        if let c = cachedPlaying, Date().timeIntervalSince(c.at) < 3 { return c.value }
        guard let f = playingFn else { return nil }
        var out: Bool?
        let sem = DispatchSemaphore(value: 0)
        f(DispatchQueue.global(qos: .utility)) { v in out = v; sem.signal() }
        _ = sem.wait(timeout: .now() + 0.3)
        if let v = out { cachedPlaying = (v, Date()) }
        return out
    }

    static func nowPlayingPid() -> Int32? {
        if let c = cachedPid, Date().timeIntervalSince(c.at) < 3 { return c.value }
        guard let f = pidFn else { return nil }
        var out: Int32?
        let sem = DispatchSemaphore(value: 0)
        f(DispatchQueue.global(qos: .utility)) { v in out = v; sem.signal() }
        _ = sem.wait(timeout: .now() + 0.3)
        if let v = out { cachedPid = (v, Date()) }
        return out
    }

    // MARK: 注册成「正在播放」的 App
    //
    // Infuse 这类播放网络 / 共享片源的 App，进程里既没有文件句柄，也不一定持
    // 防休眠断言，本机完全看不到它播的是哪个文件。但它会把自己注册进系统的
    // 「正在播放」列表（控制中心 / 锁屏显示的那个），而这份注册的时机正好是
    // 「加载了一个媒体」——暂停时还在（否则锁屏不会继续显示进度），关掉播放
    // 才撤销。这恰好就是我们要的「暂停」与「播完」的分界。

    struct Client {
        let bundleID: String
        let pid: Int32
    }

    private typealias ClientsFn = @convention(c) (DispatchQueue, @escaping @convention(block) (CFArray?) -> Void) -> Void
    private static let clientsFn: ClientsFn? = {
        guard let h = handle, let p = dlsym(h, "MRMediaRemoteGetNowPlayingClients") else { return nil }
        return unsafeBitCast(p, to: ClientsFn.self)
    }()

    private static var cachedClients: (value: [Client], at: Date)?

    static func clients() -> [Client] {
        if let c = cachedClients, Date().timeIntervalSince(c.at) < 2 { return c.value }
        guard let f = clientsFn else { return [] }
        var out: CFArray?
        let sem = DispatchSemaphore(value: 0)
        f(DispatchQueue.global(qos: .utility)) { v in out = v; sem.signal() }
        _ = sem.wait(timeout: .now() + 0.4)
        var list: [Client] = []
        for item in (out as? [Any]) ?? [] {
            let obj = item as AnyObject
            guard obj.responds(to: NSSelectorFromString("bundleIdentifier")),
                  let bid = obj.perform(NSSelectorFromString("bundleIdentifier"))?
                      .takeUnretainedValue() as? String,
                  let num = obj.perform(NSSelectorFromString("processIdentifier"))?
                      .takeUnretainedValue() as? NSNumber
            else { continue }
            list.append(Client(bundleID: bid, pid: num.int32Value))
        }
        cachedClients = (list, Date())
        return list
    }

    /// 这个 App 是否还挂着「正在播放」的媒体（播放中或暂停中）
    static func isLoaded(bundleID: String) -> Bool {
        clients().contains { $0.bundleID == bundleID }
    }

    // MARK: 正在播放的「内容」
    //
    // clients() 那份注册在播放器「停止播放、回到媒体库」之后常常还挂着，几十分钟
    // 都不撤 —— 光看它能判断「这个 App 碰过媒体」，判断不了「这条片子还在不在」。
    // 真正的分界在 Now Playing Info：暂停时它还在（控制中心仍显示片名和进度），
    // 停止播放 / 关掉片子就会被清空。所以「暂停」要两条都满足。

    private typealias InfoFn = @convention(c) (DispatchQueue,
        @escaping @convention(block) (CFDictionary?) -> Void) -> Void
    private static let infoFn: InfoFn? = {
        guard let h = handle, let p = dlsym(h, "MRMediaRemoteGetNowPlayingInfo") else { return nil }
        return unsafeBitCast(p, to: InfoFn.self)
    }()

    private static var cachedInfo: (value: [String: Any], at: Date)?

    /// 系统当前「正在播放」的媒体信息，没有内容时返回空表
    static func nowPlayingInfo() -> [String: Any] {
        if let c = cachedInfo, Date().timeIntervalSince(c.at) < 2 { return c.value }
        guard let f = infoFn else { return [:] }
        var out: CFDictionary?
        let sem = DispatchSemaphore(value: 0)
        f(DispatchQueue.global(qos: .utility)) { v in out = v; sem.signal() }
        _ = sem.wait(timeout: .now() + 0.4)
        let dict = (out as? [String: Any]) ?? [:]
        cachedInfo = (dict, Date())
        return dict
    }

    /// 系统里是否还挂着一条具体的媒体（暂停也算挂着，停止播放就没了）
    static func hasContent() -> Bool {
        let info = nowPlayingInfo()
        if info.isEmpty { return false }
        // 有标题 / 时长 / 播放速率任一，都说明这条媒体真的还挂着
        let keys = ["kMRMediaRemoteNowPlayingInfoTitle",
                    "kMRMediaRemoteNowPlayingInfoDuration",
                    "kMRMediaRemoteNowPlayingInfoPlaybackRate",
                    "kMRMediaRemoteNowPlayingInfoElapsedTime"]
        return keys.contains { info[$0] != nil }
    }

    /// 这条媒体属于哪个 App（读不到就返回 nil）
    static func contentBundleID() -> String? {
        nowPlayingInfo()["kMRMediaRemoteNowPlayingInfoClientBundleIdentifier"] as? String
    }

    /// 播放器启动 / 退出时清缓存：否则新启动的 App 会读到上一个进程留下的判断，
    /// 表现就是「刚打开播放器，屏幕就跳 HDR」。
    static func flushCaches() {
        cachedPlaying = nil
        cachedPid = nil
        cachedClients = nil
        cachedInfo = nil
    }
}

// MARK: - 播放器窗口
//
// 「暂停」和「停止播放」在系统信号里几乎长得一样：都不持防休眠断言、都不再读
// 片源、控制中心的注册也可能两种都留着。真正分得开的是界面 —— 暂停时播放界面
// 还停在那一帧（窗口标题还是片名），停止播放、退回媒体库就把这条片子的界面换
// 掉了。所以播放中记一份「窗口标题基线」，之后拿现状去比：换了就是关片了。
//
// 读窗口标题需要「屏幕录制」权限，没有时读到的是空标题 —— 这种情况返回 nil，
// 调用方退回按时间兜底，不会因此误判。
enum WindowProbe {
    private static func norm(_ s: String) -> String {
        // 去掉数字与空白：比较的是「界面身份」，不是播放进度
        String(s.lowercased().filter { !$0.isNumber && !$0.isWhitespace })
    }

    /// 读窗口标题要「屏幕录制」权限。没授权时这个调用会卡住等系统回应，
    /// 所以启动时先在后台试一次：拿得到就一路用下去，拿不到就永久退回按时间兜底，
    /// 绝不让它拖住检测线程。
    private enum Availability { case unknown, ok, unavailable }
    private static var availability: Availability = .unknown
    private static let probeQueue = DispatchQueue(label: "com.wangjin.hdrswitch.winprobe",
                                                  qos: .utility)

    static var titlesAvailable: Bool {
        lock.lock(); defer { lock.unlock() }
        return availability == .ok
    }

    static func warmUp() {
        lock.lock(); let cur = availability; lock.unlock()
        guard cur == .unknown else { return }
        let sem = DispatchSemaphore(value: 0)
        var got = -1
        probeQueue.async {
            got = rawTitles().count
            sem.signal()
        }
        if sem.wait(timeout: .now() + 1.0) == .timedOut {
            lock.lock(); availability = .unavailable; lock.unlock()
            Log.write("播放界面识别=不可用（系统未允许读取窗口标题）", force: true)
            return
        }
        lock.lock(); availability = got > 0 ? .ok : .unavailable; lock.unlock()
        Log.write(got > 0
                  ? "播放界面识别=可用（\(got) 个窗口有标题）"
                  : "播放界面识别=不可用（读不到窗口标题）", force: true)
    }

    /// 用户刚在系统设置里授权后调用：重新试一次
    static func resetAvailability() {
        lock.lock(); availability = .unknown; lock.unlock()
        warmUp()
    }

    /// 所有进程的正常层窗口标题
    private static func rawTitles() -> [String] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        var out: [String] = []
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.05
            else { continue }
            let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
            guard (b["Height"] as? Double ?? 0) >= 120 else { continue }
            let t = (w[kCGWindowName as String] as? String) ?? ""
            if !t.isEmpty { out.append(t) }
        }
        return out
    }

    /// 该进程所有正常层窗口的标题（原样，可能为空串）
    private static func windowTitles(pid: Int32) -> [String] {
        guard titlesAvailable else { return [] }
        guard let list = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        var out: [String] = []
        for w in list {
            guard let p = w[kCGWindowOwnerPID as String] as? Int32, p == pid,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.05
            else { continue }
            let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
            guard (b["Height"] as? Double ?? 0) >= 120 else { continue }
            out.append((w[kCGWindowName as String] as? String) ?? "")
        }
        return out
    }

    /// 该进程的正常层窗口标题（归一化、去空、去重）
    static func titles(pid: Int32) -> Set<String> {
        Set(windowTitles(pid: pid).map(norm).filter { !$0.isEmpty })
    }

    /// 该进程正常层窗口的「尺寸签名」（宽x高，去重）。
    ///
    /// 读窗口**标题**要屏幕录制权限，读**尺寸**不用。很多播放器（VidHub、Infuse）
    /// 暂停时会把文件句柄和播放断言一起交出去，系统层面跟「关掉了」一模一样，
    /// 唯一能分开的就是界面：播放窗口和媒体库窗口的尺寸通常差得很远。
    /// 拿不到标题时用它兜底 —— 只能用来「确认变了」，不能用来「确认没变」。
    private static func sizes(pid: Int32) -> Set<String> {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        var out = Set<String>()
        for w in list {
            guard let p = w[kCGWindowOwnerPID as String] as? Int32, p == pid,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.05
            else { continue }
            let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let h = b["Height"] as? Double ?? 0
            let wd = b["Width"] as? Double ?? 0
            guard h >= 120, wd >= 120 else { continue }
            out.insert("\(Int(wd))x\(Int(h))")
        }
        return out
    }

    /// 界面变化到什么程度。区分「确定关了」和「有点像变了」，
    /// 因为前者可以立刻回落，后者还得留点缓冲。
    enum InterfaceChange {
        /// 播放窗口没了 / 明显退回媒体库小窗 —— 一定是停止播放
        case gone
        /// 尺寸有明显变化，但还不够断定（拖窗口、切换布局）
        case altered
        /// 界面还在，就是那一块
        case same
    }

    private static let lock = NSLock()
    private static var baseline: [String: Set<String>] = [:]
    private static var sizeBaseline: [String: Set<String>] = [:]
    /// 最后一次「确定已关闭」的时间。上层据此把回落宽限压到很短。
    private static var closedAt: Date?
    /// 最后一次「缩成小窗」的时间，只用来给日志去重。
    private static var shrankAt: Date?

    /// 判「退回媒体库」时，新窗口还得多大才算数（平方点）。
    /// 媒体库窗口是正常大小的窗口，怎么也有 1000×600 以上；迷你播放器只有
    /// 几百点见方（Infuse 实测 500×500 = 250000）。取 700000 把两者分开。
    private static let goneFloorArea = 700_000

    static func closedRecently(_ within: TimeInterval = 20) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let t = closedAt else { return false }
        return Date().timeIntervalSince(t) < within
    }

    private static func markGone(_ why: String) -> InterfaceChange {
        lock.lock()
        // 同一个「已关闭」不用每轮都喊一遍：播放器退回媒体库之后就一直是这个状态，
        // 反复记只会把日志刷满，也看不出别的线索。
        let repeated = closedAt.map { Date().timeIntervalSince($0) < 5 } ?? false
        closedAt = Date()
        lock.unlock()
        if !repeated {
            Log.write("界面判为已关闭（\(why)）· 按停止播放处理", force: true)
        }
        return .gone
    }

    /// 播放中记一份界面基线
    static func remember(pid: Int32, id: String) {
        let t = titles(pid: pid)
        let s = sizes(pid: pid)
        guard !t.isEmpty || !s.isEmpty else { return }
        lock.lock()
        let fresh = (baseline[id] ?? []).isEmpty && (sizeBaseline[id] ?? []).isEmpty
        if !t.isEmpty { baseline[id] = t }
        if !s.isEmpty { sizeBaseline[id] = s }
        // 又播起来了：上一场「已关闭」的记号作废，别把快速回落带进新一场。
        closedAt = nil
        lock.unlock()
        if fresh, s.count > 0, !titlesAvailable, Log.enabled {
            Log.write("界面基线（窗口尺寸）：\(s.sorted().joined(separator: " "))")
        }
    }

    /// 播放界面是否已经换掉。
    /// - .gone   换掉了 / 窗口全关了 → 片子关了（停止播放、退回媒体库）
    /// - .altered 有变化迹象，但不足以断定，交给调用方按短时限兜底
    /// - .same   还是那个界面 → 只是暂停
    /// - nil     读不到（没权限且尺寸也没变），交给调用方按时间兜底
    static func interfaceChanged(pid: Int32, id: String) -> InterfaceChange? {
        lock.lock()
        let base = baseline[id]
        let sBase = sizeBaseline[id]
        lock.unlock()

        if let base, !base.isEmpty, titlesAvailable {
            let raw = windowTitles(pid: pid)
            if raw.isEmpty { return markGone("播放窗口都没了") }
            let now = Set(raw.map(norm).filter { !$0.isEmpty })
            if !now.isEmpty {
                // 标题是精确证据：播放界面的标题一个都不在了，就是退出了播放。
                if now.isDisjoint(with: base) { return markGone("播放界面标题全变了") }
                return .same
            }
        }
        // 标题读不到（没授权）→ 退到尺寸签名：只能加速「变了」，不能断言「没变」。
        if let sBase, !sBase.isEmpty, let b = area(sBase) {
            let now = sizes(pid: pid)
            if now.isEmpty { return markGone("一个窗口都不剩") }
            guard let n = area(now) else { return nil }
            let ratio = Double(n) / Double(b)
            // 播放画面通常占满大半屏，退回媒体库只剩一个小窗 —— 面积差一个量级。
            // 阈值取 0.35：拖一下窗口、切全屏都不会误伤，退回媒体库一定命中。
            //
            // 但「变小」不等于「关了」。播放器失焦时常常缩成**迷你播放器**：
            // Infuse 实测从 2501632 缩到 250000 平方点，正好 9%，面积特征和
            // 「退回媒体库」一模一样，只看比例必然误判 —— 用户看到的现象就是
            // 「暂停后切个 App，HDR 就被收走了」。
            // 两者的区别在**新窗口本身还有多大**：媒体库仍是个正常大小的窗口，
            // 迷你播放器只有几百点见方。所以只有「换成另一个正常大小的窗口」
            // 才认作关片；小窗一律当「播放器还在，只是变小了」。
            if ratio <= 0.35, n >= goneFloorArea {
                return markGone("最大窗口 \(b) → \(n) 平方点（只剩 \(Int(ratio * 100))%）")
            }
            if ratio <= 0.35 {
                lock.lock()
                let repeated = shrankAt.map { Date().timeIntervalSince($0) < 60 } ?? false
                shrankAt = Date()
                lock.unlock()
                if !repeated {
                    Log.write("界面缩成小窗（最大窗口 \(b) → \(n) 平方点）· 当迷你播放器，不算关片",
                              force: true)
                }
                return .same
            }
            if ratio < 0.85 {
                Log.write("界面可能变了（最大窗口 \(b) → \(n) 平方点）· 暂不结论", force: true)
                return .altered
            }
            // 面积持平或变大：切全屏、拖大窗口 —— 界面还在，别当成关片。
            return .same
        }
        return nil
    }

    /// 尺寸集合里最大的一块面积（宽x高，取字符串里的两个数）
    private static func area(_ set: Set<String>) -> Int? {
        var maxV = 0
        for s in set {
            let parts = s.split(separator: "x")
            guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { continue }
            maxV = max(maxV, w * h)
        }
        return maxV > 0 ? maxV : nil
    }

    static func forget(id: String) {
        lock.lock()
        baseline[id] = nil
        sizeBaseline[id] = nil
        closedAt = nil
        shrankAt = nil
        lock.unlock()
    }
}

// MARK: - 播放检测

struct MediaSession {
    enum Kind {
        case player      // 专门用来放片的播放器
        case streaming   // 浏览器 / 音乐类，拿不到画质信息
        case appStreaming // 原生流媒体客户端（腾讯视频）：有 App 内判据
    }

    let appName: String
    let path: String?
    let verdict: HDRVerdict
    let detail: String
    let kind: Kind
    /// 判定依据可靠程度（实读色彩标记 / 文件名 / 无从判断）
    let evidence: Evidence
    /// 活跃度：2 = 持有防休眠断言（真正在播），1 = 当前前台，0 = 只是开着文件
    let activity: Int
    /// 这一条是「暂停」而不是「在播」。
    /// 暂停时画质经常读不到（控件被收起、播放器释放了解码器），判定会变成
    /// 「未知」；而「未知」默认按 SDR 处理 —— HDR 就被收掉了。有了这个标记，
    /// 上层可以在「暂停 + 未知」时保持现状，而不是掉色。
    var paused: Bool = false

    var description: String {
        let file = path.map { ($0 as NSString).lastPathComponent } ?? "网络/无本地片源"
        return "\(appName) · \(file) · \(verdict.label)"
    }

    /// 「凭什么这么判」的一句话说明
    var basis: String {
        let how = activity >= 2 ? "播放中" : (activity == 1 ? "前台" : "已暂停")
        let what: String
        switch kind {
        case .player: what = "播放器"
        case .streaming: what = "浏览器"
        case .appStreaming: what = "流媒体客户端"
        }
        return "\(evidence.label) · \(how) · \(what)"
    }
}

enum PlaybackWatcher {
    /// 专门用来放视频的播放器
    static let localPlayers: [String] = [
        "com.colliderli.iina",
        "com.firecore.infuse",
        "com.apple.QuickTimePlayerX",
        "com.apple.TV",
        "org.videolan.vlc",
        "com.movist.Movist",
        "com.plexapp.plex",
        "com.sodaplayer.SodaPlayer"
    ]

    /// 下载器 / 传输工具：长期持有媒体文件句柄（下载中、做种中），但从不播放。
    /// 不排除的话，一下 HDR 片源就会被当成「在播 HDR」，屏幕被切过去。
    private static let downloaderIDs: Set<String> = [
        "org.qbittorrent.qbittorrent",
        "com.transmissionbt.transmission",
        "org.deluge-torrent.deluge",
        "com.bittorrent.utorrent",
        "com.bitcomet.bitcomet",
        "com.thunder.thunder",
        "com.xunlei.thunder",
        "net.motrix.motrix",
        "com.folx.folx",
        "com.downie.downie",
        "org.freedownloadmanager.fdm",
        "com.baidu.baidunetdisk",
        "com.alibaba.aliyundrive"
    ]

    /// 名称兜底：认不出的下载客户端（含各种魔改版、命令行版）也能拦住
    private static let downloaderKeywords: [String] = [
        "torrent", "transmission", "deluge", "bitcomet", "aria2", "motrix",
        "thunder", "xunlei", "迅雷", "qbittorrent", "utorrent", "folx",
        "downie", "netdisk", "网盘", "下载"
    ]

    /// 浏览器：网页视频的色彩信息在进程内存里，外部读不到，
    /// 因此这类 App 只有「拿到本地片源」时才能精确判定 HDR/SDR。
    static let streamingApps: [String] = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta",
        "com.microsoft.edgemac.Dev",
        "company.thebrowser.Browser",     // Arc
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "com.brave.Browser",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "org.chromium.Chromium",
        "com.apple.Music"
    ]

    /// 原生流媒体客户端：不是浏览器，拿不到网页；但播放内核会把自己的
    /// 内容级 HDR 判定写进日志，可以读（见 TencentVideoProbe）。
    /// 这类 App 单独归一档，避免被当成「网页视频」去跑 AppleScript。
    static let nativeStreamingApps: [String] = [
        "com.tencent.tenvideo"      // 腾讯视频
    ]

    /// 上一轮被排除的下载器名称，只给 `why` / `sessions` 显示用
    private(set) static var ignoredApps: [String] = []
    private static let ignoredLock = NSLock()

    static func isDownloader(_ app: NSRunningApplication, id: String) -> Bool {
        if downloaderIDs.contains(id.lowercased()) { return true }
        let hay = ((app.localizedName ?? "") + " " + id + " "
                   + (app.executableURL?.lastPathComponent ?? "")).lowercased()
        return downloaderKeywords.contains { hay.contains($0) }
    }

    static func sessions(includeStreaming: Bool = true) -> [MediaSession] {
        var result: [MediaSession] = []
        var skipped: [String] = []

        // 候选 = 白名单里的播放器 + 任何第三方 App。
        // 后者是为了兼容列表之外的播放器（Movist Pro / Elmedia / 未来新出的），
        // 它们不一定在白名单里，但只要有文件句柄或播放断言就能被识别。
        let candidates: [(app: NSRunningApplication, kind: MediaSession.Kind)] =
            NSWorkspace.shared.runningApplications.compactMap { app in
                guard let id = app.bundleIdentifier else { return nil }
                if localPlayers.contains(id) { return (app, .player) }
                if includeStreaming && streamingApps.contains(id) { return (app, .streaming) }
                // 腾讯视频这类原生流媒体：自己的播放内核会写 HDR 判定日志，
                // 走单独一档，别让它落进下面的「任意第三方 App」里被判成播放器。
                if nativeStreamingApps.contains(id) {
                    return includeStreaming ? (app, .appStreaming) : nil
                }
                // 系统 App 太多且不会放本地视频，跳过以免每个都去查句柄
                if id.hasPrefix("com.apple.") { return nil }
                if id == Bundle.main.bundleIdentifier { return nil }
                // 下载器永不播放，直接排除：它们会一直开着 .mkv 的句柄
                if isDownloader(app, id: id) {
                    skipped.append(app.localizedName ?? id)
                    return nil
                }
                return (app, .player)
            }

        ignoredLock.lock()
        ignoredApps = skipped
        ignoredLock.unlock()

        // 诊断：自动模式长期拿不到会话时，看这里就知道是「系统没给出运行中
        // App」还是「候选都过滤掉了」
        if Log.enabled {
            let total = NSWorkspace.shared.runningApplications.count
            let ids = candidates.map { $0.app.bundleIdentifier ?? "?" }
            Log.write("  候选: 运行中 \(total) 个 → 候选 \(candidates.count) 个 [\(ids.joined(separator: ", "))]")
        }

        guard !candidates.isEmpty else { return [] }

        // 电源断言一次性取回，避免每个 App 查一遍
        let asserting = DisplayAssertions.playingPids()
        let webBundles = DisplayAssertions.webPlaybackBundles()
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier

        // 系统「正在播放」：播放器也要查 —— Infuse 这类走网络 / 共享的播放器，
        // 进程里既没有句柄也不一定一直持断言，这份注册是它主动给的「我在放」信号。
        var nowPlaying: (playing: Bool, pid: Int32)?
        if let playing = MediaRemote.isPlaying(), let pid = MediaRemote.nowPlayingPid() {
            nowPlaying = (playing, pid)
        }

        // smbd 的句柄表一轮只读一次（读一次要起一回特权小工具，别每个 App 都来一遍）。
        // 顺便和上一轮比一比：还重叠着说明这条片子在被持续读取，不是扫封面扫一下就关。
        let smbNow: [String] = candidates.contains { $0.kind == .player }
            ? SMBService.openMediaPaths().filter { shouldCountAsMedia($0) } : []
        let smbSustained = !smbNow.isEmpty && !Set(smbNow).isDisjoint(with: lastSmbSet)
        lastSmbSet = Set(smbNow)

        for item in candidates {
            let app = item.app
            let pid = app.processIdentifier
            let name = app.localizedName ?? "播放器"
            let appID = app.bundleIdentifier ?? name

            // 「在播」必须有硬证据：防休眠断言、系统「正在播放」且确实在播、网页媒体断言。
            // 光开着 App、光开着文件都不算 —— 那是「准备播」，不是「在播」。
            let hasAssert = asserting.contains(pid)
            let isFront = pid == frontPid
            let remotePlaying = (nowPlaying?.playing ?? false) && nowPlaying?.pid == pid
            // WebKit 的「Media Playback」断言：浏览器页内视频在播而不上报系统媒体信息时靠它
            let webPlaying = item.kind == .streaming && webBundles.contains(appID)
            var playing = hasAssert || remotePlaying || webPlaying

            // 腾讯视频：防休眠断言在**暂停和关掉片子之后都不撤**（实测挂着断言
            // 回到首页也照样在），光看它分不出「还在放」和「已经关了」。日志里
            // 那条内容判定才是准的 —— 停播时播放内核先打 kStop、之后没人再更新，
            // 探针就返回 nil；正放着或暂停着时判定都还在。
            //
            // 所以这一类要求「断言 + 日志判定」同时成立才算在播：
            //   · 都在   → 在播，按日志判 HDR/SDR
            //   · 有断言、无判定（回首页翻片）→ 不算在播，HDR 该回落就回落
            //   · 无断言、有判定（暂停）→ 走下面的暂停分支，保持不掉色
            let tvResult: ProbeResult?
            if item.kind == .appStreaming {
                tvResult = TencentVideoProbe.probe()
                if Log.enabled {
                    Log.write("  腾讯视频: probe=\(tvResult?.detail ?? "nil") hasAssert=\(hasAssert) remote=\(remotePlaying) live=\(TencentVideoProbe.isLive()) 句柄=\(ProcFiles.openPaths(pid: pid).count)")
                }
                if tvResult == nil {
                    playing = false
                } else if !playing && TencentVideoProbe.isLive() {
                    // 没有断言但日志一直在写、播放位置在走 —— 这是在播，
                    // 不是「暂停」。腾讯视频播广告/部分片源时确实不持断言。
                    playing = true
                }
            } else {
                tvResult = nil
            }

            // 活跃度：2 = 在播，1 = 只是前台开着，0 = 后台且没在播（多半是暂停）
            let activity = (playing ? 2 : 0) + (isFront ? 1 : 0)

            let openPaths = ProcFiles.openPaths(pid: pid)
            let mediaPaths = openPaths.filter {
                shouldCountAsMedia($0)
            }
            // 诊断：播放内核的中间文件被排掉时留个痕，省得以后又以为是「读不到片源」。
            // 只记**本来会被当成视频**的那些（扩展名对得上）—— 否则每个 App 的
            // sqlite / 日志文件都会上榜，一秒刷六行，把有用的记录挤没了。
            if Log.enabled {
                let junk = openPaths.filter {
                    MediaProbe.mediaExtensions.contains(($0 as NSString).pathExtension.lowercased())
                        && isTransientMedia($0)
                }
                if !junk.isEmpty {
                    let names = junk.prefix(3).map { ($0 as NSString).lastPathComponent }
                    Log.write("  \(name): 忽略临时片源文件 \(junk.count) 个 [\(names.joined(separator: ", "))]")
                }
            }

            // 进程自己没有句柄时，片源可能由本机 smbd 代持 —— Infuse 走共享播放
            // 就是这种：真正 open() 文件的是服务端，播放器手里一个 fd 都没有。
            // 但 smbd 的句柄不能单独当证据：播放器打开媒体库、生成缩略图时也会让
            // 服务端 open() 一堆视频，那些文件一个字节都没往屏幕上送 —— 之前「一
            // 打开 Infuse 就跳 HDR」就是这么来的。所以只在「确实在播」或「要判暂停」
            // 时才去读它。
            var smbPaths: [String] = []
            if mediaPaths.isEmpty && item.kind == .player && (playing || keepPaused) {
                smbPaths = smbNow
            }

            // 光有 smbd 句柄还不够：播放器扫媒体库、读封面时也会让服务端 open()。
            // 再加一条「它确实把媒体挂给了系统」—— 控制中心里能看到那个正在播放的东西，
            // 说明是真的加载了一条片，而不是在后台翻目录。
            // 注册碰上个别不登记的播放器也不至于全废：句柄上一轮就在（持续在读）也算。
            let registered = smbPaths.isEmpty ? false : MediaRemote.isLoaded(bundleID: appID)
            let smbTrusted = playing && (hasAssert || remotePlaying)
                && (registered || smbSustained)

            // 刚确认「真的在播」的片源记一笔：暂停时靠它确认「还是那个片子」
            if playing {
                // 真的播起来了 → 上一场「已结束」的记号作废（哪怕这一轮没读到片源）
                clearEnded(appID)
                markLive(appID, paths: mediaPaths + smbPaths)
                // 同时记下「这个 App 会往系统「正在播放」里注册内容」——
                // 之后关片时那份注册会被清空，正好拿来区分「暂停」和「关了」。
                if MediaRemote.hasContent(),
                   let owner = MediaRemote.contentBundleID(),
                   owner.caseInsensitiveCompare(appID) == .orderedSame {
                    noteRegisteredContent(appID)
                }
                // 顺带记下播放界面：之后界面一换（退回媒体库 / 关掉片子）
                // 就是「停止播放」而不是「暂停」，可以立刻回落。
                if item.kind == .player { WindowProbe.remember(pid: pid, id: appID) }
            }

            // 暂停但片源还开着 → 继续往下判定（activity = 0，详情里标「已暂停」）
            var heldPaused = false

            if !playing {
                // 腾讯视频暂停：防休眠断言被收回，但片子还挂在那儿。
                // 它既没有窗口标题可读（没有屏幕录制权限），也没有网页可问，
                // 所以回日志里再看一眼：只要最后一条内容判定没有落在
                // 「停止播放」之后，就还是那一条片子 —— 按暂停处理，别掉色。
                if item.kind == .appStreaming {
                    guard keepPaused, let tv = tvResult else { continue }
                    let s = MediaSession(appName: name, path: nil,
                                         verdict: tv.verdict,
                                         detail: tv.detail + " · 已暂停",
                                         kind: .appStreaming, evidence: .appLog,
                                         activity: 0, paused: true)
                    result.append(s)
                    if tv.verdict != .unknown { touchJudge(name) }
                    continue
                }

                // 网页暂停：页面里的 <video> 还在，只是时间轴停住了。
                // 回页面里问一句拿它的画质，HDR 的就别收回去。切换标签、
                // 切到别的 App 都不算结束 —— 只看那个网页有没有被关掉。
                if item.kind == .streaming {
                    let (state, web) = WebProbe.outcome(bundleID: appID)
                    // 页面明确在播，只是这一轮没抓到系统的「媒体播放」断言
                    // （切到后台、断言还没立起来、或者刚重建过播放器）。
                    // 这种情况当然不能当成播放结束。
                    //
                    // 读不到画质（`web == nil`，比如暂停刚恢复、控件还没铺开）时
                    // 也必须交一条会话上去：直接往下走会被 `guard keepPaused,
                    // item.kind == .player` 拦掉，上层看到的是「这一路没有会话」，
                    // 宽限一到 HDR 就掉 —— 表现就是「在播着，屏幕忽然暗一下」。
                    if state == .playing {
                        let s = MediaSession(appName: name, path: nil,
                                             verdict: web?.verdict ?? .unknown,
                                             detail: web?.detail ?? "网页播放中 · 画质未读到",
                                             kind: .streaming, evidence: .webProbe,
                                             activity: 2 + (isFront ? 1 : 0))
                        result.append(s)
                        if let v = web?.verdict, v != .unknown { noteJudge(s) }
                        continue
                    }
                    if keepPaused, let web, state == .paused {
                        var verdict = web.verdict
                        var detail = web.detail
                        // 暂停在哪一页很重要：如果暂停的是**另一条**视频
                        // （首页的预览、另一条普通视频），说明刚才那条 HDR
                        // 已经不在看了 —— 不能拿上一次的判定替它续命，
                        // 否则「关掉网页」和「暂停在别处」就分不开，HDR 会一直挂着。
                        // 页面读不到路径（标签被挂起那种）时按同一页处理：
                        // 那条路是 `stillOpen` 判出来的，本来就要求路径对得上。
                        let hdrPage = WebProbe.lastPath(bundleID: appID)
                        let samePage = web.path.isEmpty
                            || (hdrPage != nil && web.path == hdrPage)
                        // 暂停后控件可能被收起来，画质读不到；也可能读到个「1080P」
                        // 之类的降级标签。同一页、暂停着，就沿用刚才判过的 HDR ——
                        // 真要看 SDR 的话，用户一按播放就会读到，那时再收也不迟。
                        if verdict != .hdr, samePage, let last = lastJudge(name),
                           last.verdict == .hdr {
                            verdict = last.verdict
                            detail = last.detail + " · 页面还开着"
                        }
                        if verdict == .unknown && !samePage {
                            continue
                        }
                        let s = MediaSession(appName: name, path: nil,
                                             verdict: verdict,
                                             detail: detail + " · 已暂停",
                                             kind: .streaming, evidence: .webProbe,
                                             activity: 0, paused: true)
                        result.append(s)
                        // 续一下判定的时间戳：暂停能挂很久（用户就是要挂很久），
                        // 不续的话 10 分钟「探测暂不可用」的沿用期会先到，
                        // 后面只要探测再抖一下，HDR 就掉了。
                        if verdict != .unknown { touchJudge(name) }
                        continue
                    }
                    // 探测这次没跑通（超时 / 授权被拒 / 浏览器正忙）。
                    // 以前一律当成「页面关了」，于是探测一抖屏幕就掉色 ——
                    // 用户看到的就是「暂停后切个页面 HDR 就没了」。
                    // 没读到 ≠ 关掉了：短时间内沿用上次判定，别把会话丢掉。
                    if keepPaused, state == .failed {
                        // 前提是「那条 HDR 页还被认为开着」。页面被确认关掉后
                        // `lastPath` 会被清空，这里就再也接不上了 —— 否则一轮
                        // 抓空就能把会话复活，表现就是「关掉网页 HDR 一直挂着」。
                        let pageOpen = WebProbe.lastPath(bundleID: appID) != nil
                        if pageOpen, let last = lastJudge(name),
                           Date().timeIntervalSince(last.at) < webBlindGrace {
                            let s = MediaSession(appName: name, path: nil,
                                                 verdict: last.verdict,
                                                 detail: last.detail + " · 已暂停（探测暂不可用）",
                                                 kind: .streaming, evidence: .webProbe,
                                                 activity: 0, paused: true)
                            result.append(s)
                            touchJudge(name)
                            continue
                        }
                        // 连历史判定都没有（比如 App 刚重启），但这一路不久前确实
                        // 还有页面在，而且屏幕现在就是 HDR —— 那多半是这一路自己
                        // 开的。探测抓空不该让它掉色，先按「未知 + 暂停」交上去，
                        // 上层会保持现状；超过宽容期还没有任何证据才认输。
                        if WebProbe.displayHDR,
                           let at = WebProbe.lastActivityAt(bundleID: appID),
                           Date().timeIntervalSince(at) < webBlindGrace {
                            result.append(MediaSession(appName: name, path: nil,
                                                       verdict: .unknown,
                                                       detail: "网页探测暂不可用 · 保持现状",
                                                       kind: .streaming, evidence: .webProbe,
                                                       activity: 0, paused: true))
                            continue
                        }
                    }
                    // state == .empty：确实读到了页面、也确认那一页已经不在标签
                    // 列表里了 —— 那个网页被关掉了，这才该回落。
                }

                // 本地播放器暂停：断言被收回、焦点也可能不在它身上。
                // 前提是「它刚才真的在播」（liveAt）—— 否则刚打开 App 就会承接
                // 上一场的判定，表现就是「一打开 Infuse 屏幕就跳 HDR」。
                guard keepPaused, item.kind == .player, let playedAt = liveAt(appID)
                else { continue }

                // 这一场已经判过结束了：不再拿旧判定当「暂停」复活。
                // 真的重新播起来会走 markLive 把这个记号清掉。
                guard !endedRecently(appID) else { continue }

                // 播放界面已经换掉了（退回媒体库 / 关掉片子 / 播放窗口没了）：
                // 这是「停止播放」，不是「暂停」。以前只按时间硬撑，于是片子关掉
                // 之后 HDR 还挂着，非得把播放器整个退掉才回落。
                let ui = WindowProbe.interfaceChanged(pid: pid, id: appID)
                if ui == .gone {
                    noteEnded(appID)
                    continue
                }
                // 界面还在 → 真暂停，可以长时间保持；读不到界面（没有屏幕录制
                // 权限 / 播放器不设窗口标题）就只能按时间兜，别兜太久。
                //
                // 三种情况分开算：
                //   .same    窗口还是那一块（含缩成迷你播放器）→ 暂停，保持
                //   .altered 窗口明显变小但没小到「媒体库」那份上 —— 多半是退回
                //            媒体库途中/小窗媒体库。给 20 秒确认，不立刻回落
                //   nil      完全读不到 → 按 8 分钟兜底
                let limit: TimeInterval
                switch ui {
                case .same?: limit = pausedMaxAge
                case .altered?: limit = alteredSoftAge
                case .gone?, nil: limit = pausedSoftAge
                }
                guard Date().timeIntervalSince(playedAt) < limit else { continue }

                let openPaths = mediaPaths.isEmpty ? smbPaths : mediaPaths
                if !wasPlaying(appID, paths: openPaths) {
                    // 句柄还在，只是换成了**另一个文件** —— 下一集 / 手动换片。
                    // 这不是关片，按「还在播」重新记账，直接往下走正常判定。
                    // （早先这里只比对「是不是原来那一个」，换集那几秒会被当成
                    //  句柄消失，只好把宽限拉到十几秒来兜，回落就跟着变慢。）
                    if !openPaths.isEmpty {
                        markLive(appID, paths: openPaths)
                        clearNoLive(appID)
                        heldPaused = true
                    } else if hasLivePaths(appID) {
                        // 一个句柄都没有了。
                        //
                        // 这一场里确实见到过句柄（Infuse 播共享：句柄在 smbd 手里），
                        // 现在全没了 —— 播放器把片源交回去了，就是真的关了。
                        // 以前这里只拿「上一次判定」按时间续命，于是关掉片子之后
                        // 照样算暂停，HDR 一挂就是半小时，用户看到「关了不回落」。
                        let since = markNoLive(appID)
                        let gone = Date().timeIntervalSince(since)
                        guard gone > noHandleGrace else {
                            // 宽限期内：缓冲 / smbd 收摊会抖一下，
                            // 沿用上一次判定，别让画面跟着抖。
                            if let last = lastJudge(name) {
                                result.append(MediaSession(appName: name, path: last.path,
                                                           verdict: last.verdict,
                                                           detail: last.detail + " · 已暂停",
                                                           kind: item.kind, evidence: last.evidence,
                                                           activity: 0, paused: true))
                            }
                            continue
                        }
                        if Log.enabled {
                            Log.write("  \(name): 片源句柄已消失 \(Int(gone)) 秒"
                                      + "（界面=\(ui == .same ? "还在" : ui == .altered ? "变了" : "未知")）"
                                      + "· 按停止播放处理")
                        }
                        noteEnded(appID)
                        continue
                    } else {
                    // 这一场从头到尾没见过句柄（网页播放 / 纯网络串流）：
                    // 只能看系统「正在播放」里那条还在不在 —— 暂停时它还挂着
                    // （控制中心仍显示片名和进度），停止播放才清空。
                    let loaded = MediaRemote.hasContent()
                    let owner = MediaRemote.contentBundleID()
                    let mineNow = loaded && (owner?.caseInsensitiveCompare(appID) == .orderedSame)
                    // 只有「亲眼见过它往系统里注册过内容」才拿这条当证据，
                    // 否则会把不支持 Now Playing 的播放器（暂停时不注册的那种）
                    // 一律当成关片，暂停就掉色。
                    if hasRegisteredContent(appID) && !mineNow {
                        if Log.enabled {
                            Log.write("  \(name): 系统「正在播放」已清空"
                                      + "（内容=\(loaded ? (owner ?? "?") : "无")）· 按停止播放处理")
                        }
                        noteEnded(appID)
                        continue
                    }
                    guard let last = lastJudge(name) else {
                        noteEnded(appID)
                        continue
                    }
                    let age = Date().timeIntervalSince(last.at)
                    guard age < limit else {
                        if Log.enabled {
                            Log.write("  \(name): 暂停已超时（\(Int(age))s > \(Int(limit))s"
                                      + "，界面=\(ui == .same ? "还在" : ui == .altered ? "变了" : "未知")"
                                      + "）· 按停止播放处理")
                        }
                        noteEnded(appID)
                        continue
                    }
                    result.append(MediaSession(appName: name, path: last.path,
                                               verdict: last.verdict,
                                               detail: last.detail + " · 已暂停"
                                                   + (ui == .same ? " · 界面还在" : " · 界面未知"),
                                               kind: item.kind, evidence: last.evidence,
                                               activity: 0, paused: true))
                    continue
                    }
                }
                // 句柄还对得上 → 是暂停，继续往下判定（activity = 0，详情会标「已暂停」）
                clearNoLive(appID)
                heldPaused = true
            }

            if !mediaPaths.isEmpty {
                // 能拿到文件 → 精确判定画质（浏览器同样走这条，打开本地片源时可用）
                var best: MediaSession?
                for path in mediaPaths {
                    let probe = MediaProbe.shared.probe(path: path)
                    var detail = probe.detail
                    if activity == 0 { detail += heldPaused ? " · 已暂停（片源句柄仍在）" : " · 已暂停" }
                    let s = MediaSession(appName: name, path: path, verdict: probe.verdict,
                                         detail: detail, kind: item.kind,
                                         evidence: probe.evidence, activity: activity,
                                         paused: !playing)
                    if best == nil || rank(s.verdict) > rank(best!.verdict) { best = s }
                }
                if let best = best {
                    result.append(best)
                    noteJudge(best)
                }
                continue
            }

            // 播放器进程里没有句柄，但文件来自「本机 SMB 共享」：
            // 真正 open() 它的是服务端 smbd，从这里取（需要完全磁盘访问权限）。
            // 暂停时同样走这条 —— 句柄还在，说明片源没关，只是不推进时间轴。
            if !smbPaths.isEmpty, smbTrusted || heldPaused {
                var best: MediaSession?
                for path in smbPaths {
                    let probe = MediaProbe.shared.probe(path: path)
                    var detail = probe.detail + " · 经 SMB 共享"
                    if activity == 0 { detail += heldPaused ? " · 已暂停（片源句柄仍在）" : " · 已暂停" }
                    let s = MediaSession(appName: name, path: path, verdict: probe.verdict,
                                         detail: detail, kind: item.kind,
                                         evidence: probe.evidence, activity: activity,
                                         paused: !playing)
                    if best == nil || rank(s.verdict) > rank(best!.verdict) { best = s }
                }
                if let best = best {
                    result.append(best)
                    noteJudge(best)
                    continue
                }
            }

            // 拿不到文件（网络串流 / 网页播放）→ 只能判断「在播没播」。
            // 网页视频再试一步：回页面里问一句（读播放器的清晰度标签 / 色彩信息）。
            if playing {
                // 共享播放时 smbd 的句柄是时有时无的，换集也会空一下 —— 这一轮
                // 抓不到就沿用刚才判过的结果，别让画面跟着一抖一抖。
                if mediaPaths.isEmpty, item.kind == .player,
                   let last = lastJudge(name),
                   Date().timeIntervalSince(last.at) < carryMaxAge {
                    result.append(MediaSession(appName: name, path: last.path,
                                               verdict: last.verdict,
                                               detail: last.detail + " · 本轮未读到片源，沿用",
                                               kind: item.kind, evidence: last.evidence,
                                               activity: activity))
                    // 续时间戳：整部片子都读不到句柄时（Infuse 播 DV 全程只留临时文件），
                    // 不续就会在开场 30 分钟后「沿用」到期，看一半忽然掉色。
                    // 这里只在「确实在播」时续，停止播放不会走到这一段。
                    touchJudge(name)
                    continue
                }
                var verdict = HDRVerdict.unknown
                var detail: String
                switch item.kind {
                case .streaming: detail = "网页播放中 · 色彩未知"
                case .appStreaming: detail = "腾讯视频播放中 · 画质未读到"
                case .player: detail = "播放中 · 无本地片源"
                }
                var evidence = Evidence.none
                if item.kind == .streaming,
                   let web = WebProbe.probe(bundleID: app.bundleIdentifier ?? "") {
                    verdict = web.verdict
                    detail = web.detail
                    evidence = .webProbe
                }
                // 腾讯视频：用前面已经读到的那条内容级判定
                if let tv = tvResult {
                    verdict = tv.verdict
                    detail = tv.detail
                    evidence = .appLog
                }
                let s = MediaSession(appName: name, path: nil, verdict: verdict,
                                     detail: detail, kind: item.kind,
                                     evidence: evidence, activity: activity)
                result.append(s)
                // 这一条没有片源依据，不覆盖之前读到的判定
                if verdict != .unknown { noteJudge(s) }
            }
        }

        // 活跃度优先：正在看的那一路排第一，避免「后台还开着 HDR 文件」把判定顶掉
        return result.sorted {
            ($0.activity, rank($0.verdict)) > ($1.activity, rank($1.verdict))
        }
    }

    /// 上一轮 smbd 打开的视频文件（判断「是持续在读」还是「扫一下就关」）
    private static var lastSmbSet: Set<String> = []

    private static func rank(_ v: HDRVerdict) -> Int {
        switch v {
        case .hdr: return 2
        case .unknown: return 1
        case .sdr: return 0
        }
    }

    // MARK: 暂停

    /// 读不到片源的播放器，暂停后最多沿用上次判定多久。
    /// 有了「播放界面还在不在」这条之后，暂停可以被准确识别；这里只是兜底：
    /// 万一某个 App 一直不清注册、窗口标题又读不到，也不至于把 HDR 无限期挂着。
    private static let pausedMaxAge: TimeInterval = 30 * 60

    /// 正在播、但这一轮读不到片源时，沿用上次判定多久。
    /// Infuse 播共享片源时 smbd 的句柄是时有时无的，读不到不等于没在播。
    private static let carryMaxAge: TimeInterval = 30 * 60

    /// 暂停、既没有片源句柄也没有播放界面证据时，还沿用多久。
    /// 这是「分辨不出暂停和关片」时的取舍：设短了暂停会掉色，设长了关掉片子
    /// 还要挂很久（用户之前抱怨「非得退出整个 App 才回落」）。8 分钟是个折中 ——
    /// 授权屏幕录制后这条基本用不上了，界面一变就立刻回落。
    private static let pausedSoftAge: TimeInterval = 8 * 60

    /// 暂停中「界面明显变小但还没小到媒体库那份上」时的确认期。
    /// 这一类基本是「正在退回媒体库」或者用了小窗媒体库 —— 片子已经关了，
    /// 但不该在第一帧就断定。20 秒足够看清，也不至于让用户等半分钟还亮着。
    private static let alteredSoftAge: TimeInterval = 20

    /// 网页探测「暂时读不到」时还沿用上次判定多久。
    ///
    /// 读不到不等于页面关了：Safari 正忙、标签页太多导致脚本超时、自动化授权
    /// 被系统重新询问，都会让这一轮拿不到结果。以前一律当成「播放结束」，
    /// 于是探测一抖屏幕就掉色 —— 用户看到的就是「暂停后切个页面 HDR 就没了」。
    /// 明确读到「页面里没有视频」（.empty）才是真的关了，那时立刻回落。
    private static let webBlindGrace: TimeInterval = 10 * 60

    /// 每个 App 最近一次判出的结果（暂停且读不到片源时沿用）。
    private static let judgeLock = NSLock()
    private static var judgeByName: [String: (verdict: HDRVerdict, detail: String,
                                              path: String?, evidence: Evidence, at: Date)] = [:]

    private static func noteJudge(_ s: MediaSession) {
        judgeLock.lock()
        defer { judgeLock.unlock() }
        judgeByName[s.appName] = (s.verdict, s.detail, s.path, s.evidence, Date())
        if judgeByName.count > 32 {
            let now = Date()
            for (k, v) in judgeByName where now.timeIntervalSince(v.at) > 6 * 3600 {
                judgeByName[k] = nil
            }
        }
    }

    /// 只把「上一次判定」的时间戳续到此刻，不动内容。
    ///
    /// 暂停能挂很久（用户就是要它挂很久），而「探测暂不可用」只沿用 10 分钟。
    /// 不续时间戳的话，挂上一会儿之后再碰上一次探测抖动，HDR 就掉了。
    /// 注意不要用 noteJudge 来续 —— 它会把带「· 已暂停」这类后缀的详情写回去，
    /// 每轮都往后拼一截，日志里的详情会越滚越长。
    private static func touchJudge(_ name: String) {
        judgeLock.lock()
        defer { judgeLock.unlock() }
        guard let old = judgeByName[name] else { return }
        judgeByName[name] = (old.verdict, old.detail, old.path, old.evidence, Date())
    }

    private static func lastJudge(_ name: String)
        -> (verdict: HDRVerdict, detail: String, path: String?, evidence: Evidence, at: Date)? {
        judgeLock.lock()
        defer { judgeLock.unlock() }
        return judgeByName[name]
    }

    /// 片源还开着、但没在播 —— 是否当作「暂停」保持 HDR（默认开）。
    /// 关掉后回到旧行为：暂停即视为播放结束，宽限期一到就退回 SDR。
    static var keepPaused: Bool {
        UserDefaults.standard.object(forKey: "autoKeepPaused") as? Bool ?? true
    }

    /// 每个播放器「最后一次确认真的在播」的片源路径。
    ///
    /// 暂停时防休眠断言会被收回、焦点也可能不在播放器上，唯一稳定的信号是
    /// 「那个文件还开着」——而它可能开在播放器自己手里（IINA 播本地文件），
    /// 也可能开在 smbd 手里（Infuse 播本机共享，进程里一个 fd 都没有）。
    /// 所以记下「谁播的是哪个文件」，暂停时拿现在的句柄去比对：
    /// 还能对上 → 是暂停，保持；对不上 → 片源换了或关了，正常回落。
    private static let liveLock = NSLock()
    private static var livePaths: [String: Set<String>] = [:]
    private static var liveSeenAt: [String: Date] = [:]

    private static func markLive(_ id: String, paths: [String]) {
        guard !paths.isEmpty else { return }
        liveLock.lock()
        defer { liveLock.unlock() }
        livePaths[id] = Set(paths)
        liveSeenAt[id] = Date()
        // 又真的播起来了：上一场「已结束」的记号作废。
        endedAt[id] = nil
        if livePaths.count > 64 {
            let now = Date()
            for (k, t) in liveSeenAt where now.timeIntervalSince(t) > 6 * 3600 {
                livePaths[k] = nil
                liveSeenAt[k] = nil
            }
        }
    }

    /// 这个 App 最近一次「真的在播」的时刻。播放器一启动 / 退出就清掉，
    /// 于是「刚打开 App」永远不会被当成「暂停中」。
    private static func liveAt(_ id: String) -> Date? {
        liveLock.lock()
        defer { liveLock.unlock() }
        return liveSeenAt[id]
    }

    /// 哪些 App 会把自己注册进系统「正在播放」（播放时观察到的）。
    /// 只对这类 App 用「注册被清空」当作关片证据 —— 不支持 Now Playing 的
    /// 播放器暂停时本来就是空的，拿它当证据会让暂停也掉色。
    private static var registeredContent: Set<String> = []

    /// 判定「这一场播放已经结束」的时刻。
    ///
    /// 记这个是因为：判完结束之后，上一场的判定还留在 judgeByName 里，
    /// 而「暂停保持」只要没有反证就会把它接着用。播放器的窗口尺寸又一直在
    /// `.same` / `.altered` 之间抖（实测 Infuse：同一部片子，面积一会儿
    /// 2508175、一会儿 250000），于是每一轮都在「判结束 → 回落 → 又算暂停
    /// → 切回来」之间来回抽，用户看到的就是「明明没在播，屏幕自己切 HDR」。
    ///
    /// 所以一旦判过结束，就不再从旧判定复活：必须等到**真的重新在播**
    /// （markLive 里清掉）才能再切上去。
    private static var endedAt: [String: Date] = [:]

    /// 判过一次结束之后，隔多久才允许旧判定重新被当作「暂停」。
    /// 这么长是因为：真正的重新播放一定会走 markLive 把记号清掉，
    /// 这个时限只影响「用户什么也没做」的情况。
    private static let endedCooldown: TimeInterval = 2 * 3600

    private static func noteEnded(_ id: String) {
        liveLock.lock()
        defer { liveLock.unlock() }
        endedAt[id] = Date()
    }

    private static func clearEnded(_ id: String) {
        liveLock.lock()
        defer { liveLock.unlock() }
        endedAt[id] = nil
        noLiveSince[id] = nil
    }

    private static func endedRecently(_ id: String) -> Bool {
        liveLock.lock()
        defer { liveLock.unlock() }
        guard let t = endedAt[id] else { return false }
        return Date().timeIntervalSince(t) < endedCooldown
    }

    /// 从「还在播」变成「看不见句柄」的那一刻。
    ///
    /// 句柄是「暂停」和「关片」之间唯一靠得住的区别：暂停时片源还开着
    /// （Infuse 走共享是 smbd 代持，播放器自己一个 fd 都没有），关片后
    /// 播放器就把文件交回去了。缓冲、smbd 收摊会让它抖个一两秒，
    /// 所以先记下「从什么时候开始没了」，宽限过了还没回来才算结束。
    private static var noLiveSince: [String: Date] = [:]

    /// 句柄全没了之后给多长宽限（秒）。
    ///
    /// 换集已经不靠它兜了（句柄换成别的文件时按「还在播」处理），
    /// 所以这里只用来吸收缓冲、smbd 收摊那一下的抖动 —— 短一点，
    /// 关掉片子之后屏幕就掉得干脆。实测 Infuse 关片后 4 秒足够稳。
    private static let noHandleGrace: TimeInterval = 4

    private static func markNoLive(_ id: String) -> Date {
        liveLock.lock()
        defer { liveLock.unlock() }
        if let t = noLiveSince[id] { return t }
        let now = Date()
        noLiveSince[id] = now
        return now
    }

    private static func clearNoLive(_ id: String) {
        liveLock.lock()
        defer { liveLock.unlock() }
        noLiveSince[id] = nil
    }

    /// 这一场里有没有真的见到过片源句柄。没见过的（网页播放、纯网络串流）
    /// 不能用「句柄没了」当结束证据 —— 那种播放器全程都没有句柄。
    private static func hasLivePaths(_ id: String) -> Bool {
        liveLock.lock()
        defer { liveLock.unlock() }
        return !(livePaths[id]?.isEmpty ?? true)
    }

    private static func noteRegisteredContent(_ id: String) {
        liveLock.lock()
        defer { liveLock.unlock() }
        registeredContent.insert(id)
    }

    private static func hasRegisteredContent(_ id: String) -> Bool {
        liveLock.lock()
        defer { liveLock.unlock() }
        return registeredContent.contains(id)
    }

    private static func wasPlaying(_ id: String, paths: [String],
                                   within: TimeInterval = 6 * 3600) -> Bool {
        guard !paths.isEmpty else { return false }
        liveLock.lock()
        defer { liveLock.unlock() }
        guard let known = livePaths[id], let at = liveSeenAt[id],
              Date().timeIntervalSince(at) < within
        else { return false }
        return !known.isDisjoint(with: Set(paths))
    }

    /// 播放器启动 / 退出时把它的历史判定清干净。
    ///
    /// 不清的话：上一场看的 HDR 片，关掉播放器、过一会儿再打开，
    /// 「上次判的是 HDR」还留着，App 一露头就被当成「暂停中」把屏幕切到 HDR。
    /// 现在一打开就是干净的，只有真的播起来才算数。
    static func forget(bundleID: String?, name: String) {
        if let id = bundleID {
            liveLock.lock()
            livePaths[id] = nil
            liveSeenAt[id] = nil
            registeredContent.remove(id)
            endedAt[id] = nil
            noLiveSince[id] = nil
            liveLock.unlock()
            WindowProbe.forget(id: id)
        }
        judgeLock.lock()
        judgeByName[name] = nil
        judgeLock.unlock()
        MediaRemote.flushCaches()
        SMBService.invalidateCache()
    }

    /// 是不是「一个正在被播放的片源」。除了扩展名，还要排掉正在写入的文件：
    /// 下载器即使认不出来，它手上的文件也在不停变大，那不是播放。
    private static func shouldCountAsMedia(_ path: String) -> Bool {
        guard MediaProbe.mediaExtensions.contains((path as NSString).pathExtension.lowercased())
        else { return false }
        if isTransientMedia(path) { return false }
        return !MediaProbe.isBeingWritten(path)
    }

    /// 播放内核写到临时目录里的中间文件，不是片源本身。
    ///
    /// 这类文件有两个特征：名字是**光秃秃的 UUID**（`CE59E7FF-...-9D198FBC5CF7.m4v`），
    /// 路径在 tmp / TemporaryItems / .videoChunks 里。它们没有片名可推断，
    /// 通常也还没写完、读不出色彩标记，探出来永远是「无法判定」。
    ///
    /// 留在候选里的后果很具体：Infuse 播 Dolby Vision 时会边播边写这些中间文件，
    /// **而切换显示器模式那一下刚好会重建管线、换一个新的 UUID**。于是轮到它当
    /// 「当前片源」→ 判定变「无法判定」→ 屏幕刚亮 1 秒就被收回去。真片源（SMB 上
    /// 那个 `...DV...mkv`）明明还开着，却被这一条顶掉了。
    ///
    /// 排掉它们之后：真片源还在就按真片源判；一时读不到就走「沿用上次判定」
    /// （carryMaxAge 30 分钟），不会因为播放器内部重建而掉色。
    private static func isTransientMedia(_ path: String) -> Bool {
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        if UUID(uuidString: stem) != nil { return true }

        let lower = path.lowercased()
        for marker in ["/temporaryitems/", "/.videochunks/", "/private/var/folders/", "/tmp/"] {
            if lower.contains(marker) { return true }
        }
        return false
    }
}

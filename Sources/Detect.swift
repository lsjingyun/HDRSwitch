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
        if let c = cache, Date().timeIntervalSince(c.at) < 2 { return c.paths }

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
    case none           // 无从判断（网页流、网络串流）

    var label: String {
        switch self {
        case .colorTags: return "实读色彩标记"
        case .filenameHint: return "文件名推断"
        case .webProbe: return "网页实测"
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

    func probe(path: String) -> ProbeResult {
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
}

// MARK: - 播放检测

struct MediaSession {
    enum Kind {
        case player      // 专门用来放片的播放器
        case streaming   // 浏览器 / 音乐类，拿不到画质信息
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

    var description: String {
        let file = path.map { ($0 as NSString).lastPathComponent } ?? "网络/无本地片源"
        return "\(appName) · \(file) · \(verdict.label)"
    }

    /// 「凭什么这么判」的一句话说明
    var basis: String {
        let how = activity >= 2 ? "播放中" : (activity == 1 ? "前台" : "已暂停")
        return "\(evidence.label) · \(how) · \(kind == .streaming ? "浏览器" : "播放器")"
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

        guard !candidates.isEmpty else { return [] }

        // 电源断言一次性取回，避免每个 App 查一遍
        let asserting = DisplayAssertions.playingPids()
        let webBundles = DisplayAssertions.webPlaybackBundles()
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier

        // 系统「正在播放」只在有流媒体类 App 时才查
        var nowPlaying: (playing: Bool, pid: Int32)?
        if candidates.contains(where: { $0.kind == .streaming }),
           let playing = MediaRemote.isPlaying(), let pid = MediaRemote.nowPlayingPid() {
            nowPlaying = (playing, pid)
        }

        for item in candidates {
            let app = item.app
            let pid = app.processIdentifier
            let name = app.localizedName ?? "播放器"

            // 活跃度：只有「持防休眠断言」（真的在播）、「系统正在播放」或「当前前台」才算在用。
            // 光开着文件不算 —— 否则播放器退出后残留的文件句柄会让 HDR 一直挂着不放。
            // 唯一的例外是「暂停」，见下面那一段。
            let hasAssert = asserting.contains(pid)
            let isFront = pid == frontPid
            let remotePlaying = item.kind == .streaming
                && (nowPlaying?.playing ?? false) && nowPlaying?.pid == pid
            // WebKit 的「Media Playback」断言：浏览器页内视频在播而不上报系统媒体信息时靠它
            let webPlaying = item.kind == .streaming
                && webBundles.contains(app.bundleIdentifier ?? "")
            let playing = hasAssert || remotePlaying || webPlaying
            let activity = (playing ? 2 : 0) + (isFront ? 1 : 0)

            let mediaPaths = ProcFiles.openPaths(pid: pid).filter {
                shouldCountAsMedia($0)
            }

            // 刚确认「真的在播」的文件记一笔：后面判断暂停时，非白名单播放器靠它认
            if playing && !mediaPaths.isEmpty { markPlaying(mediaPaths) }

            // 暂停是 activity == 0 的常态：IINA / VLC 一按暂停就收回防休眠断言，
            // 此刻若又不在前台，以前整条会话会被丢掉 → 宽限期一到就退回 SDR。
            // 现在只要「文件还开着、确实是播放器」就按暂停留在场上。
            if activity == 0 {
                guard keepPaused, item.kind == .player, !mediaPaths.isEmpty,
                      canHoldWhilePaused(id: app.bundleIdentifier ?? "", paths: mediaPaths)
                else { continue }
            }

            if !mediaPaths.isEmpty {
                // 能拿到文件 → 精确判定画质（浏览器同样走这条，打开本地片源时可用）
                var best: MediaSession?
                for path in mediaPaths {
                    let probe = MediaProbe.shared.probe(path: path)
                    let s = MediaSession(appName: name, path: path, verdict: probe.verdict,
                                         detail: probe.detail, kind: item.kind,
                                         evidence: probe.evidence, activity: activity)
                    if best == nil || rank(s.verdict) > rank(best!.verdict) { best = s }
                }
                if let best = best { result.append(best) }
                continue
            }

            // 播放器进程里没有句柄，但文件可能来自「本机 SMB 共享」：
            // 真正 open() 它的是服务端 smbd，从这里取（需要完全磁盘访问权限）
            if playing && item.kind == .player {
                let smbPaths = SMBService.openMediaPaths().filter { shouldCountAsMedia($0) }
                if !smbPaths.isEmpty {
                    var best: MediaSession?
                    for path in smbPaths {
                        let probe = MediaProbe.shared.probe(path: path)
                        let s = MediaSession(appName: name, path: path, verdict: probe.verdict,
                                             detail: probe.detail + " · 经 SMB 共享",
                                             kind: item.kind, evidence: probe.evidence,
                                             activity: activity)
                        if best == nil || rank(s.verdict) > rank(best!.verdict) { best = s }
                    }
                    if let best = best {
                        result.append(best)
                        continue
                    }
                }
            }

            // 拿不到文件（网络串流 / 网页播放）→ 只能判断「在播没播」。
            // 网页视频再试一步：回页面里问一句（读播放器的清晰度标签 / 色彩信息）。
            if playing {
                var verdict = HDRVerdict.unknown
                var detail = item.kind == .streaming ? "网页播放中 · 色彩未知" : "播放中 · 无本地片源"
                var evidence = Evidence.none
                if item.kind == .streaming,
                   let web = WebProbe.probe(bundleID: app.bundleIdentifier ?? "") {
                    verdict = web.verdict
                    detail = web.detail
                    evidence = .webProbe
                }
                result.append(MediaSession(appName: name, path: nil, verdict: verdict,
                                           detail: detail, kind: item.kind,
                                           evidence: evidence, activity: activity))
            }
        }

        // 活跃度优先：正在看的那一路排第一，避免「后台还开着 HDR 文件」把判定顶掉
        return result.sorted {
            ($0.activity, rank($0.verdict)) > ($1.activity, rank($1.verdict))
        }
    }

    private static func rank(_ v: HDRVerdict) -> Int {
        switch v {
        case .hdr: return 2
        case .unknown: return 1
        case .sdr: return 0
        }
    }

    // MARK: 暂停

    /// 片源还开着、但没在播 —— 是否当作「暂停」保持 HDR（默认开）。
    /// 关掉后回到旧行为：暂停即视为播放结束，宽限期一到就退回 SDR。
    static var keepPaused: Bool {
        UserDefaults.standard.object(forKey: "autoKeepPaused") as? Bool ?? true
    }

    /// 最近确认过「真的在播」的文件（路径 → 时间）。
    /// 用来认出白名单之外的播放器：它们暂停时同样会收回断言，
    /// 但只要它刚才确实播过这个文件，就可以放心当作暂停。
    private static let playingLock = NSLock()
    private static var playingPaths: [String: Date] = [:]

    private static func markPlaying(_ paths: [String]) {
        playingLock.lock()
        defer { playingLock.unlock() }
        let now = Date()
        for p in paths { playingPaths[p] = now }
        if playingPaths.count > 200 {
            playingPaths = playingPaths.filter { now.timeIntervalSince($0.value) < 12 * 3600 }
        }
    }

    private static func canHoldWhilePaused(id: String, paths: [String]) -> Bool {
        if localPlayers.contains(id) { return true }
        playingLock.lock()
        defer { playingLock.unlock() }
        let now = Date()
        return paths.contains { p in
            guard let t = playingPaths[p] else { return false }
            return now.timeIntervalSince(t) < 12 * 3600
        }
    }

    /// 是不是「一个正在被播放的片源」。除了扩展名，还要排掉正在写入的文件：
    /// 下载器即使认不出来，它手上的文件也在不停变大，那不是播放。
    private static func shouldCountAsMedia(_ path: String) -> Bool {
        guard MediaProbe.mediaExtensions.contains((path as NSString).pathExtension.lowercased())
        else { return false }
        return !MediaProbe.isBeingWritten(path)
    }
}

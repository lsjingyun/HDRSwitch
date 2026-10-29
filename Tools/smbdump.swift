// smbdump.swift — 以 root 运行的小工具
//
// 用途：Infuse / 其他 App 通过「本机 SMB 共享」播放视频时，播放器进程里没有
// 任何文件句柄（数据是 SMB 协议流进来的），但服务端 smbd 进程会一直持有被读
// 文件的 fd。普通用户读不到 root 进程的 fd，所以由这个 root 小工具代劳：
// 列出所有 smbd 进程当前打开的媒体文件路径。
//
// 输出：每行一个绝对路径（已去重、按路径排序）。没有则输出空。
// 只读、不修改任何东西，只做 proc_pidinfo 查询。

import Foundation

@_silgen_name("proc_listpids")
private func proc_listpids(_ type: UInt32, _ typeinfo: UInt32,
                           _ buffer: UnsafeMutableRawPointer?, _ buffersize: Int32) -> Int32

@_silgen_name("proc_name")
private func proc_name(_ pid: Int32, _ buffer: UnsafeMutableRawPointer?,
                       _ buffersize: UInt32) -> Int32

@_silgen_name("proc_pidinfo")
private func proc_pidinfo(_ pid: Int32, _ flavor: Int32, _ arg: UInt64,
                          _ buffer: UnsafeMutableRawPointer?, _ size: Int32) -> Int32

@_silgen_name("proc_pidfdinfo")
private func proc_pidfdinfo(_ pid: Int32, _ fd: Int32, _ flavor: Int32,
                            _ buffer: UnsafeMutableRawPointer?, _ size: Int32) -> Int32

private let PROC_ALL_PIDS: UInt32 = 1
private let PROC_PIDLISTFDS: Int32 = 1
private let PROC_PIDFDVNODEPATHINFO: Int32 = 2
/// vnode_fdinfowithpath 里 vip_path 的偏移（proc_fileinfo 24 + vnode_info 152）
private let pathOffset = 176

private let mediaExt: Set<String> = [
    "mkv", "mp4", "mov", "m4v", "avi", "ts", "m2ts", "mts", "webm",
    "flv", "wmv", "mpg", "mpeg", "iso", "rmvb", "divx", "ogv", "vob"
]

private func allPids() -> [Int32] {
    let bytes = proc_listpids(PROC_ALL_PIDS, 0, nil, 0)
    guard bytes > 0 else { return [] }
    var buf = [Int32](repeating: 0, count: Int(bytes) / 4 + 64)
    let got = buf.withUnsafeMutableBytes {
        proc_listpids(PROC_ALL_PIDS, 0, $0.baseAddress, Int32($0.count))
    }
    guard got > 0 else { return [] }
    return buf.prefix(Int(got) / 4).filter { $0 > 0 }
}

private func processName(_ pid: Int32) -> String {
    var buf = [CChar](repeating: 0, count: 128)
    let n = buf.withUnsafeMutableBytes { proc_name(pid, $0.baseAddress, 128) }
    guard n > 0 else { return "" }
    return String(cString: buf)
}

private func openPaths(pid: Int32) -> [String] {
    var size = 64 * 1024
    var raw = [UInt8](repeating: 0, count: size)
    var got = raw.withUnsafeMutableBytes {
        proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32(size))
    }
    if got > Int32(size) {
        size = Int(got) + 8192
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

// MARK: - main

var found = Set<String>()
for pid in allPids() {
    let name = processName(pid)
    // 兼容 Apple 的 smbd 与 samba 的 smbd-*
    guard name == "smbd" || name.hasPrefix("smbd") else { continue }
    for path in openPaths(pid: pid) {
        let ext = (path as NSString).pathExtension.lowercased()
        guard mediaExt.contains(ext) else { continue }
        // 排除系统字体/资源目录里的误报
        if path.hasPrefix("/System/") { continue }
        found.insert(path)
    }
}

for path in found.sorted() {
    print(path)
}

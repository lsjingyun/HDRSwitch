// 从一张方图（圆角矩形 + 白底）生成 macOS 应用图标。
//
// 用法：swift Tools/makeicon-toggle.swift <源图> <输出 1024 png>
//
// 两条规矩，都是踩出来的：
//  1. **满幅**：图形必须铺满整张画布，圆角矩形自己画，四角之外透明。
//     macOS 26/27 会把「留白」当成空白区，额外套一层白色玻璃底板 ——
//     图标就成了「白框里塞一块深色」，在深色 Dock 上尤其难看。
//  2. **边缘要削**：源图边缘那圈抗锯齿是和白底混出来的，不削掉会在深色
//     背景上留一道浅色描边。所以遮罩比画布内缩 3px 再羽化 1.5px。
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let srcPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "icon-source.jpg"
let outPath = CommandLine.arguments.count > 2
    ? CommandLine.arguments[2]
    : "icon-1024.png"

let canvas = 1024
let trim: CGFloat = 3      // 边缘内缩（切掉与白底混合的抗锯齿像素）
let feather: CGFloat = 1.5 // 内缩后的羽化宽度
let n: CGFloat = 5         // 超椭圆指数，5 最接近 macOS 的连续圆角

guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: srcPath) as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    FileHandle.standardError.write("读不到源图：\(srcPath)\n".data(using: .utf8)!)
    exit(1)
}

let cs = CGColorSpace(name: CGColorSpace.sRGB)!

// ── 1. 找圆角矩形本体的包围盒（本体很暗，白底与投影很亮，0.55 分得开）
let W = img.width, H = img.height
let bpr = W * 4
var buf = [UInt8](repeating: 0, count: bpr * H)
guard let readCtx = CGContext(data: &buf, width: W, height: H, bitsPerComponent: 8,
                              bytesPerRow: bpr, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    exit(1)
}
readCtx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))

var minX = W, maxX = -1, minY = H, maxY = -1
for y in 0..<H {
    for x in 0..<W {
        let i = y * bpr + x * 4
        let lum = (0.2126 * Double(buf[i]) + 0.7152 * Double(buf[i + 1]) + 0.0722 * Double(buf[i + 2])) / 255.0
        if lum < 0.55 {
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
    }
}
guard maxX > minX, maxY > minY else {
    FileHandle.standardError.write("没找到图标本体\n".data(using: .utf8)!)
    exit(1)
}

// ── 2. 居中裁成正方形（留 2px 余量，别把边缘切掉）
let side = Double(max(maxX - minX + 1, maxY - minY + 1))
let cx = Double(minX + maxX + 1) / 2.0
let cy = Double(minY + maxY + 1) / 2.0
let cropRect = CGRect(x: cx - side / 2 - 2, y: cy - side / 2 - 2,
                      width: side + 4, height: side + 4)
guard let cropped = img.cropping(to: cropRect) else { exit(1) }

// ── 3. 铺满整张画布
guard let out = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8,
                          bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    exit(1)
}
out.interpolationQuality = .high
out.draw(cropped, in: CGRect(x: -trim, y: -trim,
                             width: CGFloat(canvas) + trim * 2,
                             height: CGFloat(canvas) + trim * 2))

// ── 4. 超椭圆遮罩：切掉四角的白底与投影，同时削掉边缘那圈白
let ppr = out.bytesPerRow
let p = out.data!.bindMemory(to: UInt8.self, capacity: ppr * canvas)
let halfDraw = CGFloat(canvas) / 2 + trim

for y in 0..<canvas {
    for x in 0..<canvas {
        let i = y * ppr + x * 4
        let lx = (CGFloat(x) - CGFloat(canvas) / 2) / halfDraw
        let ly = (CGFloat(y) - CGFloat(canvas) / 2) / halfDraw
        let d = pow(pow(abs(lx), n) + pow(abs(ly), n), 1.0 / n)
        let dist = d * halfDraw            // 到中心的「半径」，d=1 时正好是画布边缘
        var cov = (halfDraw - trim - dist) / feather
        cov = max(0, min(1, cov))

        let orig = Int(p[i + 3])
        if orig == 0 { continue }
        let na = UInt8((CGFloat(orig) * cov).rounded())
        if na == 0 {
            p[i] = 0; p[i + 1] = 0; p[i + 2] = 0; p[i + 3] = 0
        } else {
            // 缓冲区是预乘 alpha，RGB 按同一比例缩放
            let f = CGFloat(na) / CGFloat(orig)
            p[i] = UInt8(min(255, (CGFloat(p[i]) * f).rounded()))
            p[i + 1] = UInt8(min(255, (CGFloat(p[i + 1]) * f).rounded()))
            p[i + 2] = UInt8(min(255, (CGFloat(p[i + 2]) * f).rounded()))
            p[i + 3] = na
        }
    }
}

// ── 5. 输出
guard let final = out.makeImage() else { exit(1) }
let url = URL(fileURLWithPath: outPath)
try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                 UTType.png.identifier as CFString, 1, nil) else {
    exit(1)
}
CGImageDestinationAddImage(dest, final, nil)
CGImageDestinationFinalize(dest)
print("已写出 \(outPath)（\(canvas)×\(canvas)，满幅）")

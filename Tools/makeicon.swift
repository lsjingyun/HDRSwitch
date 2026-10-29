// makeicon.swift — 生成 HDRSwitch 的应用图标
//
// 为什么用 CoreGraphics 手画而不是找一张图：图标要能出整套尺寸（16～1024），
// 还要能随时调色/调比例。这里在 2048 的画布上画，再缩到 1024，边缘干净。
//
// 设计：深色圆角底上放一颗被 45° 斜切的球 —— 左下半沉在暗部，右上半被强光
// 照亮，交界处一道高光线，外面一圈高光溢出。HDR 的本质就是「同一画面里既
// 有极暗又有极亮」，一颗球就够了；不用字母、不用文字，缩到 16px 也认得出来。
//
// 用法：swift Tools/makeicon.swift <输出.png>

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let SS = 2048                        // 超采样画布
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let cs = CGColorSpace(name: CGColorSpace.sRGB)!

func col(_ hex: UInt32, _ a: CGFloat = 1.0) -> CGColor {
    return CGColor(colorSpace: cs,
                   components: [CGFloat((hex >> 16) & 0xFF) / 255.0,
                                CGFloat((hex >> 8) & 0xFF) / 255.0,
                                CGFloat(hex & 0xFF) / 255.0,
                                a])!
}

func grad(_ stops: [(UInt32, CGFloat)], _ locs: [CGFloat]) -> CGGradient {
    let colors = stops.map { col($0.0, $0.1) } as CFArray
    return CGGradient(colorsSpace: cs, colors: colors, locations: locs)!
}

/// 超椭圆（squircle）：|x/a|^n + |y/b|^n = 1，n≈5 时最接近 macOS 图标的连续圆角
func squircle(cx: CGFloat, cy: CGFloat, half h: CGFloat, n: CGFloat = 5.0, steps: Int = 1440) -> CGPath {
    let p = CGMutablePath()
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + h * copysign(pow(abs(ct), 2.0 / n), ct)
        let y = cy + h * copysign(pow(abs(st), 2.0 / n), st)
        if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
    }
    p.closeSubpath()
    return p
}

guard let ctx = CGContext(data: nil, width: SS, height: SS, bitsPerComponent: 8,
                          bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("无法创建绘图上下文")
}
ctx.setShouldAntialias(true)
ctx.setAllowsAntialiasing(true)

let c = CGPoint(x: CGFloat(SS) / 2, y: CGFloat(SS) / 2)
// macOS 26/27 的图标规范是**满幅**：图形铺满整张画布，圆角由系统裁。
// 早先按旧规范留了 100px 透明边距，结果系统把透明区当成空白、额外套了一层
// 白色玻璃底板，图标变成「白框里塞一块深色」，只能改成满幅。
let fullBleed = true
let half: CGFloat = fullBleed ? CGFloat(SS) / 2 : 824
let R: CGFloat = fullBleed ? 578 : 470
let k: CGFloat = R / 470            // 其他偏移量随球半径等比缩放

// ── 1. 底：深蓝黑，顶部一点冷光，像一块背光面板
ctx.saveGState()
if !fullBleed {
    ctx.addPath(squircle(cx: c.x, cy: c.y, half: half))
    ctx.clip()
}
ctx.drawLinearGradient(grad([(0x252D42, 1), (0x161B29, 1), (0x0A0D15, 1)], [0, 0.48, 1]),
                       start: CGPoint(x: c.x, y: c.y + half),
                       end: CGPoint(x: c.x, y: c.y - half), options: [])
// 顶部内高光，让面板有厚度
ctx.drawLinearGradient(grad([(0xFFFFFF, 0.14), (0xFFFFFF, 0.0)], [0, 1]),
                       start: CGPoint(x: c.x, y: c.y + half),
                       end: CGPoint(x: c.x, y: c.y + half * 0.45), options: [])

// ── 2. 高光溢出：只在球右上方一圈暖金，模拟 HDR 峰值亮度外溢。
//    用叠加混合（plusLighter）而不是普通透明：普通 alpha 会把深色背板染成脏褐色，
//    叠加才是「光加在暗底上」的真实观感，暗的地方仍然暗。
ctx.saveGState()
ctx.setBlendMode(.plusLighter)
ctx.drawRadialGradient(grad([(0xFFA848, 0.34), (0xFF8A2E, 0.13), (0xFF8A2E, 0.0)], [0, 0.45, 1]),
                       startCenter: CGPoint(x: c.x + 130 * k, y: c.y + 150 * k), startRadius: 0,
                       endCenter: CGPoint(x: c.x + 130 * k, y: c.y + 150 * k), endRadius: 560 * k, options: [])
ctx.restoreGState()

// 背板内描边：深色桌面/深色列表里，没有这圈容易和背景粘在一起
if !fullBleed {
    ctx.setStrokeColor(col(0xFFFFFF, 0.075))
    ctx.setLineWidth(6)
    ctx.addPath(squircle(cx: c.x, cy: c.y, half: half - 3))
    ctx.strokePath()
}
ctx.restoreGState()

// ── 3. 球体
let ball = CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2)

// 3a. 暗部基底：深蓝紫，越靠左下越沉
ctx.saveGState()
ctx.addEllipse(in: ball); ctx.clip()
ctx.drawLinearGradient(grad([(0x303C5C, 1), (0x1A2133, 1), (0x0B0E18, 1)], [0, 0.5, 1]),
                       start: CGPoint(x: c.x - 130 * k, y: c.y + R),
                       end: CGPoint(x: c.x + 130 * k, y: c.y - R), options: [])

// 3b. 亮面：45° 斜切，法线指向右上
let nx: CGFloat = 0.70710678, ny: CGFloat = 0.70710678      // 面法线（指向亮侧）
let dx: CGFloat = 0.70710678, dy: CGFloat = -0.70710678     // 切线方向
let big: CGFloat = 3000
let q1 = CGPoint(x: c.x + dx * big, y: c.y + dy * big)
let q2 = CGPoint(x: c.x + dx * big + nx * big, y: c.y + dy * big + ny * big)
let q3 = CGPoint(x: c.x - dx * big + nx * big, y: c.y - dy * big + ny * big)
let q4 = CGPoint(x: c.x - dx * big, y: c.y - dy * big)
let halfPlane = CGMutablePath()
halfPlane.move(to: q1); halfPlane.addLine(to: q2)
halfPlane.addLine(to: q3); halfPlane.addLine(to: q4)
halfPlane.closeSubpath()
ctx.addPath(halfPlane); ctx.clip()
ctx.drawLinearGradient(grad([(0xFFFDF8, 1), (0xFFE3AC, 1), (0xFFB35E, 1), (0xF2762F, 1), (0xD2492A, 1)],
                            [0, 0.24, 0.56, 0.84, 1]),
                       start: CGPoint(x: c.x + nx * R, y: c.y + ny * R),
                       end: CGPoint(x: c.x - nx * R, y: c.y - ny * R), options: [])
ctx.restoreGState()

// 3b2. 球面弧度：越靠外侧越暗，免得亮面看起来像一张平纸
ctx.saveGState()
ctx.addEllipse(in: ball); ctx.clip()
ctx.drawRadialGradient(grad([(0x000000, 0.0), (0x000000, 0.06), (0x000000, 0.30)], [0, 0.62, 1]),
                       startCenter: CGPoint(x: c.x + 170 * k, y: c.y - 150 * k), startRadius: 0,
                       endCenter: CGPoint(x: c.x + 170 * k, y: c.y - 150 * k), endRadius: R * 1.85, options: [])

// 3c. 溢光：只落在亮面一侧 —— 暗面那半必须保持干净，否则整颗球会糊成灰雾
ctx.saveGState()
ctx.addPath(halfPlane); ctx.clip()
ctx.drawLinearGradient(grad([(0xFFFFFF, 0.0), (0xFFFFFF, 0.22), (0xFFFFFF, 0.0)], [0, 0.5, 1]),
                       start: CGPoint(x: c.x + nx * 215 * k, y: c.y + ny * 215 * k),
                       end: CGPoint(x: c.x - nx * 215 * k, y: c.y - ny * 215 * k), options: [])
ctx.drawLinearGradient(grad([(0xFFFFFF, 0.0), (0xFFFFFF, 0.42), (0xFFFFFF, 0.0)], [0, 0.5, 1]),
                       start: CGPoint(x: c.x + nx * 80 * k, y: c.y + ny * 80 * k),
                       end: CGPoint(x: c.x - nx * 80 * k, y: c.y - ny * 80 * k), options: [])
ctx.restoreGState()

// 3d. 暗部右下一道很淡的冷色反光，避免左下死黑
ctx.drawRadialGradient(grad([(0x9FB6FF, 0.13), (0x9FB6FF, 0.0)], [0, 1]),
                       startCenter: CGPoint(x: c.x + 215 * k, y: c.y - 235 * k), startRadius: 0,
                       endCenter: CGPoint(x: c.x + 215 * k, y: c.y - 235 * k), endRadius: 400 * k, options: [])

// ── 4. 明暗交界的那道高光线：整张图的视觉焦点
ctx.setShadow(offset: .zero, blur: 70 * k, color: col(0xFFC069, 1.0))
ctx.setStrokeColor(col(0xFFFDF4, 0.97))
ctx.setLineWidth(8 * k)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: c.x - dx * R, y: c.y - dy * R))
ctx.addLine(to: CGPoint(x: c.x + dx * R, y: c.y + dy * R))
ctx.strokePath()
ctx.restoreGState()

// ── 5. 边缘光：亮侧一道暖白弧光，暗侧只留极细轮廓
ctx.saveGState()
let rimRect = ball.insetBy(dx: 3 * k, dy: 3 * k)
ctx.setStrokeColor(col(0xFFFFFF, 0.13))
ctx.setLineWidth(3 * k)
ctx.addEllipse(in: rimRect)
ctx.strokePath()

ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 28 * k, color: col(0xFFD79A, 0.85))
ctx.setStrokeColor(col(0xFFF8EA, 0.78))
ctx.setLineWidth(8 * k)
ctx.setLineCap(.round)
ctx.addArc(center: c, radius: rimRect.width / 2, startAngle: 0.28, endAngle: 1.98, clockwise: false)
ctx.strokePath()
ctx.restoreGState()
ctx.restoreGState()

// ── 输出：2048 → 1024（高质量重采样），配 sRGB 与透明背景
guard let bigImage = ctx.makeImage() else { fatalError("渲染失败") }
let W = 1024
guard let out = CGContext(data: nil, width: W, height: W, bitsPerComponent: 8,
                          bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("无法创建输出上下文")
}
out.interpolationQuality = .high
out.setShouldAntialias(true)
out.draw(bigImage, in: CGRect(x: 0, y: 0, width: W, height: W))
guard let img = out.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL,
                                                 UTType.png.identifier as CFString, 1, nil) else {
    fatalError("无法写出 PNG")
}
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("已生成 \(outPath)")

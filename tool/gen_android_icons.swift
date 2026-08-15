// 从 macOS 的 1024 源图生成 Android 全套启动器图标。
// 用法: swift gen_android_icons.swift <source.png> <android/res 目录>
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 3 else { fatalError("usage: gen_android_icons.swift <src> <resDir>") }
let srcPath = args[1]
let resDir = args[2]

guard let srcs = CGImageSourceCreateWithURL(URL(fileURLWithPath: srcPath) as CFURL, nil),
      let source = CGImageSourceCreateImageAtIndex(srcs, 0, nil) else {
    fatalError("cannot load \(srcPath)")
}

func makeContext(_ w: Int, _ h: Int) -> CGContext {
    guard let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("cannot create context") }
    ctx.interpolationQuality = .high
    return ctx
}

func savePNG(_ image: CGImage, _ path: String) {
    let dir = (path as NSString).deletingLastPathComponent
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else { fatalError("cannot create dest \(path)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("cannot write \(path)") }
    print("wrote \(image.width)x\(image.height) \(path)")
}

// 把源图按 scale（占画布比例）居中渲染进 SxS RGBA 缓冲。
func renderScaled(_ S: Int, scale: Double) -> [UInt8] {
    let ctx = makeContext(S, S)
    let inner = Double(S) * scale
    ctx.clear(CGRect(x: 0, y: 0, width: S, height: S))
    ctx.draw(source, in: CGRect(
        x: (Double(S) - inner) / 2, y: (Double(S) - inner) / 2, width: inner, height: inner))
    let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
    return Array(UnsafeBufferPointer(start: data, count: S * S * 4))
}

func pixelsToImage(_ buf: [UInt8], _ S: Int) -> CGImage {
    let ctx = makeContext(S, S)
    let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
    buf.withUnsafeBufferPointer { src in data.update(from: src.baseAddress!, count: S * S * 4) }
    guard let img = ctx.makeImage() else { fatalError("makeImage failed") }
    return img
}

// 自适应图标前景：源图缩到画布 84%（图案落进 66dp 安全区），边缘用
// 边界像素外推补齐（源图边缘是平滑的深蓝渐变，外推看不出接缝）。
let fgScale = 0.84
func foregroundPixels(_ S: Int) -> [UInt8] {
    var buf = renderScaled(S, scale: fgScale)
    let m = Int((Double(S) * (1.0 - fgScale)) / 2.0)
    for y in 0..<S {
        let iy = min(max(y, m), S - 1 - m)
        for x in 0..<S {
            let ix = min(max(x, m), S - 1 - m)
            if x == ix && y == iy { continue }
            let s = (iy * S + ix) * 4
            let d = (y * S + x) * 4
            for k in 0..<4 { buf[d + k] = buf[s + k] }
        }
    }
    return buf
}

// 主题图标（Android 13+ 单色层）：按亮度平滑阈值提取亮色图案。
func monochromePixels(_ S: Int) -> [UInt8] {
    let p = foregroundPixels(S)
    var out = p
    for i in 0..<(S * S) {
        let o = i * 4
        let l = (0.299 * Double(p[o]) + 0.587 * Double(p[o + 1]) + 0.114 * Double(p[o + 2])) / 255.0
        var a = (l - 0.40) / (0.58 - 0.40)
        a = min(max(a, 0), 1)
        a = a * a * (3 - 2 * a) // smoothstep
        out[o] = 255; out[o + 1] = 255; out[o + 2] = 255
        out[o + 3] = UInt8(a * 255)
    }
    return out
}

// 传统位图：整幅源图 + 自带遮罩（圆角矩形 / 圆形）。
func legacyImage(_ S: Int, round: Bool) -> CGImage {
    let ctx = makeContext(S, S)
    let rect = CGRect(x: 0, y: 0, width: S, height: S)
    ctx.clear(rect)
    ctx.saveGState()
    if round {
        ctx.addEllipse(in: rect)
    } else {
        let r = Double(S) * 0.2237 // 与 iOS/macOS 圆角比例一致
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
    }
    ctx.clip()
    ctx.draw(source, in: rect)
    ctx.restoreGState()
    guard let img = ctx.makeImage() else { fatalError("legacy makeImage failed") }
    return img
}

// 背景色：四角 8px 取样平均（自适应图标背景层 + 视差时露出的兜底色）。
do {
    let S = 64
    let ctx = makeContext(S, S)
    ctx.draw(source, in: CGRect(x: 0, y: 0, width: S, height: S))
    let d = ctx.data!.assumingMemoryBound(to: UInt8.self)
    var acc = [0, 0, 0]
    for (cx, cy) in [(4, 4), (S - 5, 4), (4, S - 5), (S - 5, S - 5)] {
        for (dx, dy) in [(0, 0), (4, 0), (0, 4), (4, 4)] {
            let o = ((cy + dy) * S + (cx + dx)) * 4
            acc[0] += Int(d[o]); acc[1] += Int(d[o + 1]); acc[2] += Int(d[o + 2])
        }
    }
    let n = 16
    let hex = acc.map { String(format: "%02X", $0 / n) }.joined()
    print("BACKGROUND_HEX=#\(hex)")
}

// (密度, 传统尺寸 px, 自适应 108dp 画布尺寸 px)
let densities: [(String, Int, Int)] = [
    ("mdpi", 48, 108), ("hdpi", 72, 162), ("xhdpi", 96, 216),
    ("xxhdpi", 144, 324), ("xxxhdpi", 192, 432),
]
for (name, legacyS, fgS) in densities {
    let dir = "\(resDir)/mipmap-\(name)"
    savePNG(legacyImage(legacyS, round: false), "\(dir)/ic_launcher.png")
    savePNG(legacyImage(legacyS, round: true), "\(dir)/ic_launcher_round.png")
    savePNG(pixelsToImage(foregroundPixels(fgS), fgS), "\(dir)/ic_launcher_foreground.png")
    savePNG(pixelsToImage(monochromePixels(fgS), fgS), "\(dir)/ic_launcher_monochrome.png")
}

import CoreGraphics
import ImageIO
import Foundation

// ---------------------------------------------------------------------------
// 程序化生成 btTool 的应用图标。
//
// 为什么不用 AI 生成的图：图像生成模型会在输出图右下角**打水印**，
// 那种图不能当图标用；而且带渐变/噪点的位图压缩率很差（1.6M）。
// 这里全部用 CoreGraphics 画纯色块：无水印、体积小、改配色只需改数组。
//
// 用法：make icon        （会编译本文件并运行，产物写到 Resources/AppIcon.icns）
// ---------------------------------------------------------------------------

/// Apple 的图标规范：1024 画布里，图标主体约 824×824 居中，圆角半径约主体的 22.4%
let canvasInsetRatio: CGFloat = 0.098
let cornerRadiusRatio: CGFloat = 0.2237

/// 主体背景（近白）
let bg = (r: 0.970, g: 0.970, b: 0.985)
/// 主体的极淡描边：浅色底在白色的 Finder / Dock 背景上会失去轮廓，描一圈才看得出边界
let bgStroke = (r: 0.855, g: 0.855, b: 0.890)
/// Touch Bar 条的槽底色 —— **浅灰**。
///    ⚠️ 真实硬件的面板是纯黑的，按真实感这里该用近黑；但那样整块深色压在图标中央，
///    缩到 Dock 尺寸就是一团黑。所以提亮成浅灰，把深色**只留给按钮**：
///    面积小、够聚焦，小尺寸下依然撑得起对比。
let slot = (r: 0.870, g: 0.870, b: 0.895)

/// 按钮本体的填充色。
///    真实 Touch Bar 的按钮**不是彩色的** —— 是深灰半透明的小圆角块，
///    内容才是白色（图标或文字）。所以这里用深灰按钮 + 白色符号。
let btnFill = (r: 0.330, g: 0.330, b: 0.360)
/// 按钮内的符号 / 文字色
let btnGlyph = (r: 0.960, g: 0.960, b: 0.980)

func drawIcon(pixelSize: CGFloat) -> CGImage {
    let S = pixelSize
    guard let ctx = CGContext(
        data: nil, width: Int(S), height: Int(S),
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("无法创建 CGContext") }

    // 画布保持透明：图标主体之外不该有不透明像素
    ctx.clear(CGRect(x: 0, y: 0, width: S, height: S))

    // ① 主体圆角矩形
    let inset = S * canvasInsetRatio
    let body = CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
    let bodyRadius = body.width * cornerRadiusRatio
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: bodyRadius,
                       cornerHeight: bodyRadius, transform: nil))
    ctx.setFillColor(CGColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1))
    ctx.setStrokeColor(CGColor(red: bgStroke.r, green: bgStroke.g, blue: bgStroke.b, alpha: 1))
    ctx.setLineWidth(S * 0.006)
    ctx.drawPath(using: .fillStroke)

    // ② Touch Bar 条（居中横条）
    let barW = body.width * 0.70
    let barH = body.width * 0.145
    let bar = CGRect(x: body.midX - barW / 2, y: body.midY - barH / 2,
                     width: barW, height: barH)
    let barRadius = barH * 0.30
    ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barRadius,
                       cornerHeight: barRadius, transform: nil))
    ctx.setFillColor(CGColor(red: slot.r, green: slot.g, blue: slot.b, alpha: 1))
    ctx.fillPath()

    // ③ 条上的按钮——按真实 Touch Bar 的布局来：
    //    最左是 Esc，中间一组功能键，最右是控制条（音量 / 亮度等）。
    //    小尺寸下不画按钮内的白色符号（会糊成一团），只保留深灰色块。
    //
    //    每个元素：(相对宽度, 内部符号)  符号: 0=无 1=横线 2=圆点 3=双横线
    let detailed = S >= 128
    let items: [(w: CGFloat, glyph: Int)] = detailed
        ? [(0.9, 1),                                  // Esc
           (1.0, 2), (1.0, 3), (1.0, 1), (1.0, 2),     // 中间功能键
           (0.7, 0), (0.7, 0)]                         // 右侧控制条
        : [(1.0, 0), (1.0, 0), (1.0, 0)]

    let pad = barH * 0.16
    let gap = barH * 0.13
    let btnH = barH - 2 * pad

    var totalW: CGFloat = 0
    for it in items { totalW += it.w }
    let unit = (bar.width - 2 * pad - gap * CGFloat(items.count - 1)) / totalW

    var x = bar.minX + pad
    for item in items {
        let w = unit * item.w
        let btn = CGRect(x: x, y: bar.minY + pad, width: w, height: btnH)
        let br = btnH * 0.26
        ctx.addPath(CGPath(roundedRect: btn, cornerWidth: br, cornerHeight: br, transform: nil))
        ctx.setFillColor(CGColor(red: btnFill.r, green: btnFill.g, blue: btnFill.b, alpha: 1))
        ctx.fillPath()

        if detailed {
            ctx.setFillColor(CGColor(red: btnGlyph.r, green: btnGlyph.g,
                                     blue: btnGlyph.b, alpha: 0.92))
            let cx = btn.midX, cy = btn.midY
            switch item.glyph {
            case 1:                      // 一条横线：代表文字标签
                let lw = w * 0.52, lh = btnH * 0.11
                ctx.fill(CGRect(x: cx - lw / 2, y: cy - lh / 2, width: lw, height: lh))
            case 2:                      // 圆点：代表图标按钮
                let d = btnH * 0.34
                ctx.fillEllipse(in: CGRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d))
            case 3:                      // 两条短横线
                let lw = w * 0.46, lh = btnH * 0.09
                ctx.fill(CGRect(x: cx - lw / 2, y: cy - lh - lh * 0.5, width: lw, height: lh))
                ctx.fill(CGRect(x: cx - lw / 2, y: cy + lh * 0.5, width: lw, height: lh))
            default:
                break
            }
        }
        x += w + gap
    }

    guard let image = ctx.makeImage() else { fatalError("无法生成 CGImage") }
    return image
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw NSError(domain: "MakeIcon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "无法创建 PNG 输出：\(url.path)"])
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "MakeIcon", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "PNG 写出失败：\(url.path)"])
    }
}

// MARK: - 主流程

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("btTool.iconset")

try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

// iconset 要求的 10 个尺寸（@2x 是 Retina 用的双倍图）
let specs: [(Int, String)] = [
    (16, "icon_16x16"),     (32, "icon_16x16@2x"),
    (32, "icon_32x32"),     (64, "icon_32x32@2x"),
    (128, "icon_128x128"),  (256, "icon_128x128@2x"),
    (256, "icon_256x256"),  (512, "icon_256x256@2x"),
    (512, "icon_512x512"),  (1024, "icon_512x512@2x"),
]

for (px, name) in specs {
    let image = drawIcon(pixelSize: CGFloat(px))
    try writePNG(image, to: iconset.appendingPathComponent("\(name).png"))
}

// 顺便留一张 1024 预览图，方便直接看效果
let previewDir = root.appendingPathComponent("build/icon-work")
try? fm.createDirectory(at: previewDir, withIntermediateDirectories: true)
try writePNG(drawIcon(pixelSize: 1024), to: previewDir.appendingPathComponent("icon-preview.png"))

let output = root.appendingPathComponent("Resources/AppIcon.icns")
try? fm.removeItem(at: output)

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try task.run()
task.waitUntilExit()

guard task.terminationStatus == 0 else {
    fputs("❌ iconutil 失败（退出码 \(task.terminationStatus)）\n", stderr)
    exit(1)
}

let size = (try? fm.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0
print("==> 已生成 \(output.lastPathComponent)（\(size / 1024) KB，\(specs.count) 个尺寸）")
print("==> 预览图：build/icon-work/icon-preview.png")

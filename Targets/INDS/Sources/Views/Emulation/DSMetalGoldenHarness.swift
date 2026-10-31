#if DEBUG
//
//  DSMetalGoldenHarness.swift
//  eDuo
//
//  Golden-image check for the Metal presentation of the DS screens, launched by
//  scripts/ds_metal_golden_check.sh (`-eDuoMetalGolden record|check <fixtures> <out>`).
//
//  record  renders every case with the LEGACY path (UIImageView + magnificationFilter +
//          scanline CALayer, drawn with layer.render(in:)) and writes the PNG references.
//  check   renders the same cases with the Metal path (same shader/uniforms as on screen, into
//          an offscreen texture) and compares against the references.
//
//  Synthetic patterns only. Cases = layouts (phone, iPad, fill, single, fractional, iPhone Duo
//  with the hinge band) x filters (crisp, smooth, scanlines).
//

import UIKit
import Metal

enum DSMetalGoldenHarness {

    // Tolerance per case (same shape as iNES's harness), measured on the 1-pixel-tolerant error (see `compare`).
    static let maxMAE = 0.5          // mean abs error over RGB, /255
    static let maxPctOver8 = 0.5     // % of pixels with any channel off by more than 8
    static let maxDiff = 32          // no channel anywhere off by more than this

    struct LayoutCase {
        let name: String
        let size: CGSize
        let mode: DSScreenLayoutMode
        var swap = false
        var stretch = false
        var band: DSHingeBand?
    }

    static let layouts: [LayoutCase] = [
        LayoutCase(name: "phone-portrait", size: CGSize(width: 390, height: 844), mode: .stacked),
        LayoutCase(name: "phone-landscape", size: CGSize(width: 844, height: 390), mode: .sideBySide),
        LayoutCase(name: "ipad-portrait-swap", size: CGSize(width: 820, height: 1180), mode: .stacked, swap: true),
        LayoutCase(name: "fill-stacked", size: CGSize(width: 700, height: 840), mode: .stacked, stretch: true),
        LayoutCase(name: "single-top", size: CGSize(width: 844, height: 390), mode: .topOnly),
        LayoutCase(name: "fractional", size: CGSize(width: 701, height: 571), mode: .sideBySide),
        // Duo inner display, content rect (safe area removed): portrait 669x835 (band centre 475.5-82),
        // book 867x669 (band centre 475.5).
        LayoutCase(name: "duo-portrait-hinge", size: CGSize(width: 669, height: 835), mode: .stacked,
                   band: DSHingeBand(isVertical: false, center: 393.5, half: 20)),
        LayoutCase(name: "duo-landscape-hinge", size: CGSize(width: 867, height: 669), mode: .sideBySide,
                   band: DSHingeBand(isVertical: true, center: 475.5, half: 20)),
    ]

    static let filters: [(String, NDSDisplayFilter)] = [("crisp", .crisp), ("smooth", .smooth), ("scanlines", .scanlines)]

    // MARK: Patterns (256x192, UInt32 0xAARRGGBB = bytes B,G,R,A)

    static func pattern(_ index: Int) -> [UInt32] {
        var px = [UInt32](repeating: 0, count: 256 * 192)
        for y in 0 ..< 192 {
            for x in 0 ..< 256 {
                var r = 0, g = 0, b = 0
                switch index % 4 {
                case 0: // gradient
                    r = x; g = y * 255 / 191; b = (x + y) & 255
                case 1: // checker 8px with a 1px red frame
                    let on = ((x / 8) + (y / 8)) % 2 == 0
                    (r, g, b) = on ? (230, 230, 230) : (20, 20, 40)
                    if x == 0 || y == 0 || x == 255 || y == 191 { (r, g, b) = (255, 0, 0) }
                case 2: // colour bars + fine alternating lines at the bottom
                    let bars: [(Int, Int, Int)] = [(255, 255, 255), (255, 255, 0), (0, 255, 255), (0, 255, 0),
                                                   (255, 0, 255), (255, 0, 0), (0, 0, 255), (0, 0, 0)]
                    (r, g, b) = bars[x / 32]
                    if y >= 160 { (r, g, b) = (y % 2 == 0) ? (255, 255, 255) : (0, 0, 0) }
                default: // 1px grid on mid blue
                    (r, g, b) = (x % 16 == 0 || y % 16 == 0) ? (250, 250, 120) : (30, 60, 140)
                }
                px[y * 256 + x] = 0xFF00_0000 | UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
            }
        }
        return px
    }

    static func cgImage(_ px: [UInt32]) -> CGImage? {
        let data = px.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: 256, height: 192, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 256 * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: Rendering

    private static func makeView(_ c: LayoutCase, filter: NDSDisplayFilter, legacy: Bool) -> DSDualScreenView {
        UserDefaults.standard.set(legacy, forKey: "eDuoLegacyDSRender")
        defer { UserDefaults.standard.removeObject(forKey: "eDuoLegacyDSRender") }
        let dual = DSDualScreenView(frame: CGRect(origin: .zero, size: c.size))
        dual.reservesControlBand = true
        dual.applyDisplayFilter(filter)
        return dual
    }

    private static func layout(_ dual: DSDualScreenView, _ c: LayoutCase) {
        DSHingeState.override = c.band.map { .band($0) } ?? .none
        dual.applyLayout(mode: c.mode, swap: c.swap, stretch: c.stretch, animated: false)
        dual.layoutIfNeeded()
        dual.applyLayout(mode: c.mode, swap: c.swap, stretch: c.stretch, animated: false)
    }

    static func legacyImage(_ c: LayoutCase, filter: NDSDisplayFilter, top: [UInt32], bottom: [UInt32], scale: CGFloat) -> UIImage {
        let dual = makeView(c, filter: filter, legacy: true)
        precondition(!dual.isMetalEnabled)
        dual.topScreenView.image = cgImage(top).map { UIImage(cgImage: $0) }
        dual.bottomScreenView.image = cgImage(bottom).map { UIImage(cgImage: $0) }
        return hosted(dual, size: c.size) { root in
            layout(dual, c)
            DSHingeState.override = nil
            return snapshot(root, size: c.size, scale: scale)
        }
    }

    /// The window the legacy views are put in so that they go through the REAL Core Animation
    /// render path: `layer.render(in:)` ignores `magnificationFilter = .nearest`.
    static var scene: UIWindowScene?
    static var lastFrames = ""

    /// Puts `view` in a window of `size` (so safe-area insets and layout are the real ones), runs `body`,
    /// and tears the window down again.
    static func hosted<T>(_ view: UIView, size: CGSize, _ body: (UIView) -> T) -> T {
        let window: UIWindow
        if let scene { window = UIWindow(windowScene: scene) } else { window = UIWindow(frame: CGRect(origin: .zero, size: size)) }
        let root = UIViewController()
        root.view.backgroundColor = .black
        window.rootViewController = root
        window.isHidden = false
        window.frame = CGRect(origin: .zero, size: size)
        root.view.frame = CGRect(origin: .zero, size: size)
        view.frame = root.view.bounds
        root.view.addSubview(view)
        root.view.layoutIfNeeded()
        defer { view.removeFromSuperview(); window.isHidden = true }
        return body(root.view)
    }

    static func snapshot(_ root: UIView, size: CGSize, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            root.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
    }

    /// The real on-screen Metal path: frames pushed through `presentFrames` into the CAMetalLayers,
    /// composited by Core Animation, captured with drawHierarchy.
    static func liveMetalImage(_ c: LayoutCase, filter: NDSDisplayFilter, top: [UInt32], bottom: [UInt32], scale: CGFloat) -> UIImage? {
        let dual = makeView(c, filter: filter, legacy: false)
        guard dual.isMetalEnabled else { return nil }
        return hosted(dual, size: c.size) { root in
            layout(dual, c)
            DSHingeState.override = nil
            lastFrames = "top \(dual.topScreenView.frame) bottom \(dual.bottomScreenView.frame) topMetal \(dual.topMetalView?.frame ?? .zero) bottomMetal \(dual.bottomMetalView?.frame ?? .zero)"
            var tookFrame = false
            top.withUnsafeBufferPointer { t in bottom.withUnsafeBufferPointer { b in
                tookFrame = dual.presentFrames { copy in copy(t.baseAddress!, b.baseAddress!); return true }
            } }
            guard tookFrame else { return nil }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            return snapshot(root, size: c.size, scale: scale)
        }
    }

    static func metalImage(_ c: LayoutCase, filter: NDSDisplayFilter, top: [UInt32], bottom: [UInt32], scale: CGFloat) -> UIImage? {
        guard let renderer = DSMetalRenderer.shared else { return nil }
        let dual = makeView(c, filter: filter, legacy: false)
        guard let topMetal = dual.topMetalView, let bottomMetal = dual.bottomMetalView else { return nil }
        return hosted(dual, size: c.size) { _ in
            layout(dual, c)
            DSHingeState.override = nil
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            format.opaque = true
        format.preferredRange = .standard
            return UIGraphicsImageRenderer(size: c.size, format: format).image { ctx in
                UIColor.black.setFill()
                ctx.fill(CGRect(origin: .zero, size: c.size))
                ctx.cgContext.interpolationQuality = .none
                for (screen, metal, px) in [(dual.topScreenView, topMetal, top), (dual.bottomScreenView, bottomMetal, bottom)] where !screen.isHidden {
                    let pixelSize = CGSize(width: metal.bounds.width * scale, height: metal.bounds.height * scale)
                    let img = px.withUnsafeBufferPointer { renderer.renderOffscreen(pixels: $0.baseAddress!, view: metal, pixelSize: pixelSize) }
                    guard let img else { continue }
                    UIImage(cgImage: img, scale: scale, orientation: .up).draw(at: CGPoint(x: screen.frame.minX + metal.frame.minX, y: screen.frame.minY + metal.frame.minY))
                }
            }
        }
    }

    // MARK: Compare

    static func rgba(_ image: UIImage) -> (px: [UInt8], w: Int, h: Int)? {
        guard let cg = image.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (buf, w, h)
    }

    /// Amplified absolute difference (x4) for looking at failures.
    static func diffImage(_ a: UIImage, _ b: UIImage) -> UIImage? {
        guard let x = rgba(a), let y = rgba(b), x.w == y.w, x.h == y.h else { return nil }
        var out = [UInt8](repeating: 255, count: x.w * x.h * 4)
        for i in 0 ..< x.w * x.h {
            for ch in 0 ..< 3 { out[i * 4 + ch] = UInt8(min(255, abs(Int(x.px[i * 4 + ch]) - Int(y.px[i * 4 + ch])) * 4)) }
        }
        guard let ctx = CGContext(data: &out, width: x.w, height: x.h, bitsPerComponent: 8, bytesPerRow: x.w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let cg = ctx.makeImage() else { return nil }
        return UIImage(cgImage: cg)
    }

    struct Stats { var mae = 0.0, pctOver8 = 0.0, maxDiff = 0, strictMAE = 0.0, strictMax = 0, ok = true, note = "" }

    /// Strict stats (info) and pass/fail on the 1-pixel-tolerant error: each pixel is compared with the
    /// best match among the reference's 3x3 neighbourhood. Core Animation and the shader disagree by at
    /// most one pixel in two places that cannot be matched bit for bit: texel boundaries that fall exactly
    /// on a pixel centre (nearest filter, float rounding) and the partially covered row/column at a
    /// screen's fractional edge (Core Animation anti-aliases it, the 1:1 drawable does not).
    static func compare(_ a: UIImage, _ b: UIImage) -> Stats {
        guard let x = rgba(a), let y = rgba(b), x.w == y.w, x.h == y.h else {
            return Stats(ok: false, note: "size mismatch")
        }
        let w = x.w, h = x.h
        var strictSum = 0, sum = 0, over8 = 0, mx = 0, strictMax = 0
        for py in 0 ..< h {
            for px in 0 ..< w {
                let i = (py * w + px) * 4
                var d0 = 0, dmax = 0
                for ch in 0 ..< 3 {
                    let d = abs(Int(x.px[i + ch]) - Int(y.px[i + ch]))
                    d0 += d; dmax = max(dmax, d)
                }
                strictSum += d0; strictMax = max(strictMax, dmax)
                var bestSum = d0, bestMax = dmax
                if d0 > 0 {
                    for dy in -1 ... 1 {
                        for dx in -1 ... 1 where dx != 0 || dy != 0 {
                            let qx = px + dx, qy = py + dy
                            guard qx >= 0, qy >= 0, qx < w, qy < h else { continue }
                            let j = (qy * w + qx) * 4
                            var s = 0, m = 0
                            for ch in 0 ..< 3 {
                                let d = abs(Int(x.px[j + ch]) - Int(y.px[i + ch]))
                                s += d; m = max(m, d)
                            }
                            if s < bestSum { bestSum = s; bestMax = m }
                        }
                    }
                }
                sum += bestSum
                if bestMax > 8 { over8 += 1 }
                mx = max(mx, bestMax)
            }
        }
        let n = w * h
        var s = Stats()
        s.mae = Double(sum) / Double(n * 3)
        s.pctOver8 = Double(over8) * 100 / Double(n)
        s.maxDiff = mx
        s.strictMAE = Double(strictSum) / Double(n * 3)
        s.strictMax = strictMax
        s.ok = s.mae <= maxMAE && s.pctOver8 <= maxPctOver8 && mx <= maxDiff
        return s
    }

    // MARK: Entry point

    static func runIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard args.firstIndex(of: "-eDuoMetalGolden") != nil else { return }
        // Needs a window scene (real Core Animation path for the legacy references).
        func go() {
            if let s = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
                scene = s
                run()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { go() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { go() }
    }

    private static func run() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-eDuoMetalGolden"), args.count > i + 3 else { exit(2) }
        let mode = args[i + 1]
        let fixtures = URL(fileURLWithPath: args[i + 2], isDirectory: true)
        let out = URL(fileURLWithPath: args[i + 3], isDirectory: true)
        try? FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // Pixel scale of the references: part of the file name, the scanline rows are 1 pt tall.
        let scale = UIScreen.main.scale
        let tag = "@\(Int(scale))x"
        var report: [String] = ["scale \(scale), mode \(mode)"]
        var failures = 0
        var idx = 0
        for c in layouts {
            for (fname, filter) in filters {
                idx += 1
                let top = pattern(idx), bottom = pattern(idx + 2)
                let name = "\(fname)__\(c.name)\(tag)"
                let refURL = fixtures.appendingPathComponent("\(name).png")
                if mode == "record" {
                    let img = legacyImage(c, filter: filter, top: top, bottom: bottom, scale: scale)
                    try? img.pngData()?.write(to: refURL)
                    report.append("recorded \(name)")
                    continue
                }
                let rendered = mode == "live"
                    ? liveMetalImage(c, filter: filter, top: top, bottom: bottom, scale: scale)
                    : metalImage(c, filter: filter, top: top, bottom: bottom, scale: scale)
                guard let metal = rendered else {
                    report.append("FAIL \(name): no Metal image"); failures += 1; continue
                }
                try? metal.pngData()?.write(to: out.appendingPathComponent("\(name).png"))
                guard let data = try? Data(contentsOf: refURL), let ref = UIImage(data: data) else {
                    report.append("FAIL \(name): missing reference (record first, scale \(scale))"); failures += 1; continue
                }
                let s = compare(ref, metal)
                report.append(String(format: "%@ %@ mae %.3f pct>8 %.3f%% max %d (strict mae %.3f max %d) %@", s.ok ? "ok  " : "FAIL", name, s.mae, s.pctOver8, s.maxDiff, s.strictMAE, s.strictMax, s.note))
                if !s.ok {
                    report.append("     \(lastFrames)")
                    failures += 1
                    try? diffImage(ref, metal)?.pngData()?.write(to: out.appendingPathComponent("\(name).diff.png"))
                }
            }
        }
        report.append(failures == 0 ? "RESULT OK" : "RESULT FAIL \(failures)")
        try? report.joined(separator: "\n").write(to: out.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        exit(failures == 0 ? 0 : 1)
    }
}
#endif

/// Main-thread CPU cost of `presentFrame` (CPU time of the call) and of the whole main thread
/// (CPU time / wall time between ticks, i.e. including the Core Animation commit). Enabled by the
/// Debug-only `-eDuoPerfProbe` launch argument (also written to Documents/perf-probe.txt every 5 s)
/// or, in every build, by the Settings "Performance overlay" toggle (UserDefaults
/// `eDuoPerfOverlay`, read once per game launch via `refresh()`). Costs one Bool test per frame when off.
enum DSPerfProbe {
    static let overlayKey = "eDuoPerfOverlay"
    /// Only Debug and TestFlight builds expose the hidden diagnostics section (the overlay itself is public).
    static var isTestBuild: Bool {
#if DEBUG || PERF_LOCAL
        return true
#else
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
#endif
    }
#if DEBUG
    private static let argEnabled = ProcessInfo.processInfo.arguments.contains("-eDuoPerfProbe")
#else
    private static let argEnabled = false
#endif
    private(set) static var enabled = false
    /// Called once per second with the overlay text while enabled.
    static var onSample: ((String) -> Void)?
    private static var frames = 0
    private static var emuFrames = 0
    private static var bodyCPU: UInt64 = 0
    private static var startWall = DispatchTime.now().uptimeNanoseconds
    private static var startCPU = threadCPU()
    private static var lastFileWall = DispatchTime.now().uptimeNanoseconds

    static func refresh() {
        enabled = argEnabled || UserDefaults.standard.bool(forKey: overlayKey)
        frames = 0; emuFrames = 0; bodyCPU = 0
        startWall = DispatchTime.now().uptimeNanoseconds; startCPU = threadCPU(); lastFileWall = startWall
    }

    private static func threadCPU() -> UInt64 {
        var ts = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
        return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
    }

    static func begin() -> UInt64 {
        guard enabled else { return 0 }
        return threadCPU()
    }

    /// A new emulated frame was picked up by the presenter.
    static func noteEmuFrame() {
        guard enabled else { return }
        emuFrames += 1
    }

    static func end(_ t0: UInt64) {
        guard enabled else { return }
        let now = threadCPU()
        bodyCPU &+= now &- t0
        frames += 1
        let wall = DispatchTime.now().uptimeNanoseconds &- startWall
        guard wall > 1_000_000_000 else { return }
        let secs = Double(wall) / 1e9
        let total = now &- startCPU
        let text = String(format: "display %.0f fps  emu %.0f fps\nmain CPU %.0f %%  present %.0f us",
                          Double(frames) / secs, Double(emuFrames) / secs,
                          Double(total) * 100 / Double(wall), Double(bodyCPU) / Double(frames) / 1000)
        onSample?(text)
        // Lets a tethered run (devicectl --console) record the same numbers.
        print("[perf]", DSMetalRenderer.legacyForced ? "legacy" : "metal", text.replacingOccurrences(of: "\n", with: "  "))
#if DEBUG
        if argEnabled, DispatchTime.now().uptimeNanoseconds &- lastFileWall > 5_000_000_000 {
            lastFileWall = DispatchTime.now().uptimeNanoseconds
            let line = (DSMetalRenderer.legacyForced ? "legacy " : "metal ") + text.replacingOccurrences(of: "\n", with: " ") + "\n"
            if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                let url = docs.appendingPathComponent("perf-probe.txt")
                if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile() }
                else { try? line.write(to: url, atomically: true, encoding: .utf8) }
            }
        }
#endif
        frames = 0; emuFrames = 0; bodyCPU = 0; startWall = DispatchTime.now().uptimeNanoseconds; startCPU = now
    }
}

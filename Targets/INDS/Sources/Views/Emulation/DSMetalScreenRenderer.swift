//
//  DSMetalScreenRenderer.swift
//  eDuo
//
//  Native Metal presentation of the DS framebuffers (replaces the per-frame
//  CGImage -> UIImage -> UIImageView path). `DSMetalScreenView` is a plain
//  UIView backed by a CAMetalLayer that lives inside each screen's image view,
//  so screen frames, hinge layouts, gestures and accessibility stay exactly
//  where they were. `DSMetalRenderer` owns the device, the pipeline and a ring
//  of source textures that are filled straight from the bridge's slot buffers.
//
//  Force the old path with UserDefaults `eDuoLegacyDSRender` (bool).
//

import UIKit
import Metal
import QuartzCore
import simd

/// Must match `DSUniforms` in DSScreenShaders.metal.
struct DSUniforms {
    var rectOrigin = SIMD2<Float>(0, 0)
    var rectSize = SIMD2<Float>(1, 1)
    var scale: Float = 1
    var scanAlpha: Float = 0
    var nearest: UInt32 = 0
    var pad: UInt32 = 0
    var layerShift = SIMD2<Float>(0, 0)
    var background = SIMD4<Float>(0.05, 0.05, 0.05, 1)
}

final class DSMetalRenderer {

    static let framebufferWidth = 256
    static let framebufferHeight = 192
    static let ringCount = 3
    /// Brightness of the letterbox / screen background (`UIColor(white: 0.05)`).
    static let backgroundWhite: Float = 0.05
    /// Black overlay alpha of every second 1 pt row in `.scanlines`.
    static let scanlineAlpha: Float = 0.18

    /// nil when this device has no Metal (or the pipeline fails): callers fall back to the UIImage path.
    static let shared: DSMetalRenderer? = DSMetalRenderer()

    /// UserDefaults `eDuoLegacyDSRender`: force the CGImage/UIImageView path.
    static var legacyForced: Bool { UserDefaults.standard.bool(forKey: "eDuoLegacyDSRender") }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var rings: [[MTLTexture]] = [[], []]   // [top, bottom][slot]
    private var slot = 0
    private let inflight = DispatchSemaphore(value: DSMetalRenderer.ringCount)

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let lib = device.makeDefaultLibrary(),
              let vs = lib.makeFunction(name: "dsScreenVertex"),
              let fs = lib.makeFunction(name: "dsScreenFragment") else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = vs
        d.fragmentFunction = fs
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: d) else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: Self.framebufferWidth, height: Self.framebufferHeight, mipmapped: false)
        td.usage = .shaderRead
        td.storageMode = .shared
        for screen in 0 ..< 2 {
            for _ in 0 ..< Self.ringCount {
                guard let t = device.makeTexture(descriptor: td) else { return nil }
                rings[screen].append(t)
            }
        }
    }

    // MARK: Frame

    /// Reserves a ring slot without blocking. false = the GPU is 3 frames behind: skip this tick.
    func acquireSlot() -> Bool { inflight.wait(timeout: .now()) == .success }
    func releaseSlot() { inflight.signal() }

    /// Copies both framebuffers into the next ring slot. Call between `acquireSlot()` and `commit`.
    func upload(top: UnsafePointer<UInt32>, bottom: UnsafePointer<UInt32>) -> (top: MTLTexture, bottom: MTLTexture) {
        slot = (slot + 1) % Self.ringCount
        let region = MTLRegionMake2D(0, 0, Self.framebufferWidth, Self.framebufferHeight)
        let bpr = Self.framebufferWidth * 4
        rings[0][slot].replace(region: region, mipmapLevel: 0, withBytes: top, bytesPerRow: bpr)
        rings[1][slot].replace(region: region, mipmapLevel: 0, withBytes: bottom, bytesPerRow: bpr)
        return (rings[0][slot], rings[1][slot])
    }

    /// Draws one frame to the views that are on screen, then presents. Releases the slot taken by `acquireSlot()`.
    func present(_ draws: [(DSMetalScreenView, MTLTexture)], waitUntilCompleted: Bool = false) {
        guard let cb = queue.makeCommandBuffer() else { releaseSlot(); return }
        var drawn = 0
        for (view, texture) in draws {
            let layer = view.metalLayer
            guard view.bounds.width > 0, view.bounds.height > 0, let drawable = layer.nextDrawable() else { continue }
            encode(source: texture, target: drawable.texture, uniforms: view.uniforms(), commandBuffer: cb)
            cb.present(drawable)
            view.lastTexture = texture
            view.hasContent = true
            drawn += 1
        }
        cb.addCompletedHandler { [inflight] _ in inflight.signal() }
        cb.commit()
        if waitUntilCompleted && drawn > 0 { cb.waitUntilCompleted() }
    }

    /// Re-renders the last frame of `view` (bounds, filter or layout changed with no new frame to draw).
    func redraw(_ view: DSMetalScreenView) {
        guard view.hasContent, let texture = view.lastTexture else { return }
        // Blocking is fine here (layout/filter changes only) and it guarantees the ring
        // slot behind `lastTexture` is not overwritten while this pass reads it.
        guard inflight.wait(timeout: .now() + 0.05) == .success else { return }
        present([(view, texture)], waitUntilCompleted: true)
    }

    private func encode(source: MTLTexture, target: MTLTexture, uniforms: DSUniforms, commandBuffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare      // the shader writes every pixel
        pass.colorAttachments[0].storeAction = .store
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var u = uniforms
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(source, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<DSUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

#if DEBUG
    /// Golden harness: renders `pixels` (256x192 BGRA) with `view`'s current filter/aspect at
    /// `pixelSize` into an offscreen texture and reads it back. Same shader, same uniforms as on screen.
    func renderOffscreen(pixels: UnsafePointer<UInt32>, view: DSMetalScreenView, pixelSize: CGSize) -> CGImage? {
        let w = Int(pixelSize.width), h = Int(pixelSize.height)
        let src = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: Self.framebufferWidth, height: Self.framebufferHeight, mipmapped: false)
        src.storageMode = .shared
        let dst = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        dst.usage = [.renderTarget, .shaderRead]
        dst.storageMode = .shared
        guard let source = device.makeTexture(descriptor: src), let target = device.makeTexture(descriptor: dst),
              let cb = queue.makeCommandBuffer() else { return nil }
        source.replace(region: MTLRegionMake2D(0, 0, Self.framebufferWidth, Self.framebufferHeight), mipmapLevel: 0,
                       withBytes: pixels, bytesPerRow: Self.framebufferWidth * 4)
        encode(source: source, target: target, uniforms: view.uniforms(), commandBuffer: cb)
        cb.commit()
        cb.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        target.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
#endif
}

/// One DS screen, drawn by Metal. Sits on top of its `UIImageView` (which keeps the frame,
/// the gestures and the accessibility element) and is hidden until the first frame is drawn.
final class DSMetalScreenView: UIView {

    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    var nearest = false {
        didSet {
            guard nearest != oldValue else { return }
            // Core Animation resamples the layer once more when it sits at a fractional position:
            // the same filter as the picture keeps hard edges hard (Crisp).
            metalLayer.magnificationFilter = nearest ? .nearest : .linear
            metalLayer.minificationFilter = nearest ? .nearest : .linear
            redrawLast()
        }
    }
    var scanlines = false { didSet { if scanlines != oldValue { redrawLast() } } }
    /// "Fill screen": scaleToFill instead of aspect fit.
    var stretch = false { didSet { if stretch != oldValue { redrawLast() } } }

    /// The screen's exact (fractional) size in points: the picture is laid out in it, while the
    /// view itself is `snappedSize` of it (whole pixels, never larger).
    var exactSize: CGSize = .zero

    /// Where the picture starts inside the drawable, in pixels (the layer sits on a whole pixel, the
    /// picture on the screen's exact fractional position).
    private var pictureShift = SIMD2<Float>(0, 0)

    /// Puts the view over its screen: `screenFrame` is the screen's (fractional) frame in a container
    /// whose origin is `containerOrigin` in the window. The layer is placed on a whole window pixel and
    /// sized to whole pixels, so Core Animation shows the drawable 1:1 (never resampled); the picture is
    /// drawn at the screen's exact position and size inside it, like the image the UIImageView drew.
    func place(screenFrame: CGRect, containerOrigin: CGPoint) {
        let s = pixelScale
        exactSize = screenFrame.size
        let ax = (containerOrigin.x + screenFrame.minX) * s, ay = (containerOrigin.y + screenFrame.minY) * s
        // Core Animation lights a pixel when its centre is inside the frame [a, a + size): whole
        // pixels from ceil(a - 0.5) up to (not including) ceil(a + size - 0.5).
        func edge(_ v: CGFloat) -> CGFloat { (v - 0.5).rounded(.up) }
        let lx = edge(ax), ly = edge(ay)
        let rx = edge(ax + screenFrame.width * s), ry = edge(ay + screenFrame.height * s)
        pictureShift = SIMD2(Float(ax - lx), Float(ay - ly))
        frame = CGRect(x: (lx - ax) / s, y: (ly - ay) / s, width: (rx - lx) / s, height: (ry - ly) / s)
    }

    fileprivate var lastTexture: MTLTexture?
    var hasContent = false { didSet { isHidden = !hasContent } }

    init(device: MTLDevice) {
        super.init(frame: .zero)
        isHidden = true
        isOpaque = true
        isUserInteractionEnabled = false
        let l = metalLayer
        l.device = device
        l.pixelFormat = .bgra8Unorm
        l.framebufferOnly = true
        l.isOpaque = true
        l.maximumDrawableCount = 3
        // The drawable is exactly the layer's size in pixels (see `snappedSize`), so Core Animation
        // shows it 1:1: a resampled drawable would blur every texel edge.
        l.contentsGravity = .topLeft
        // The CGImage the old path drew was DeviceRGB (sRGB-like) and Core Animation colour-matched
        // it for the display. Tagging the layer the same way keeps wide-colour phones from showing
        // an over-saturated picture.
        l.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    var pixelScale: CGFloat { window?.screen.scale ?? UIScreen.main.scale }

    override func layoutSubviews() {
        super.layoutSubviews()
        let s = pixelScale
        metalLayer.contentsScale = s
        let size = CGSize(width: max(1, (bounds.width * s).rounded()), height: max(1, (bounds.height * s).rounded()))
        if metalLayer.drawableSize != size {
            metalLayer.drawableSize = size
            redrawLast()
        }
    }

    private func redrawLast() { DSMetalRenderer.shared?.redraw(self) }

    /// Shader parameters from the view's exact (fractional) size in pixels.
    func uniforms() -> DSUniforms {
        var u = DSUniforms()
        let exact = exactSize == .zero ? bounds.size : exactSize
        let w = Float(exact.width * pixelScale), h = Float(exact.height * pixelScale)
        if stretch {
            u.rectOrigin = pictureShift
            u.rectSize = SIMD2(w, h)
        } else {
            let aspect = Float(DSMetalRenderer.framebufferWidth) / Float(DSMetalRenderer.framebufferHeight)
            var rw = w, rh = w / aspect
            if rh > h { rh = h; rw = h * aspect }
            u.rectSize = SIMD2(rw, rh)
            u.rectOrigin = pictureShift + SIMD2((w - rw) / 2, (h - rh) / 2)
        }
        u.scale = Float(pixelScale)
        u.layerShift = pictureShift
        u.scanAlpha = scanlines ? DSMetalRenderer.scanlineAlpha : 0
        u.nearest = nearest ? 1 : 0
        let bg = DSMetalRenderer.backgroundWhite
        u.background = SIMD4(bg, bg, bg, 1)
        return u
    }
}

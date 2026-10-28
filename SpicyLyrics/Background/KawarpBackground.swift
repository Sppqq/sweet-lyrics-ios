import MetalKit
import SwiftUI
import UIKit

/// The original's moving background (Kawarp, `@kawarp/core`, as in the extension and the
/// Android port): the cover, blurred small, warped like liquid by drifting noise and
/// cross-faded from song to song. It flows while a song plays and slows to a tenth on pause.
/// Drawn by Metal at the original's 300×150 and stretched over the screen, as the browser
/// stretches its canvas: a few thousand pixels a frame, next to nothing for the GPU.
struct KawarpBackground: UIViewRepresentable {
    let image: UIImage?
    let imageID: String
    let animated: Bool
    let playing: Bool
    var speed: Double = 1
    var blur: Double = 1
    var saturation: Double = 1

    static var isSupported: Bool { KawarpSurface.isSupported }

    func makeUIView(context: Context) -> KawarpSurface { KawarpSurface() }

    func updateUIView(_ view: KawarpSurface, context: Context) {
        view.speedScale = max(0.1, speed)
        view.saturationScale = saturation
        view.playing = playing
        view.animated = animated
        view.setImage(image, id: imageID, blur: blur)
    }
}

final class KawarpSurface: ShaderSurface {
    static let isSupported: Bool = {
        guard let library = ShaderSurface.library else { return false }
        return library.makeFunction(name: "kawarpFragment") != nil
    }()

    private struct Uniforms {
        var time: Float
        var blend: Float
        var intensity: Float
        var saturation: Float
        var dithering: Float
        var scale: Float
        var frame: Float
    }

    private static let transitionDuration: Double = 1
    private let black = KawarpSurface.makeTexture(nil)
    private var current: MTLTexture?
    private var incoming: MTLTexture?
    private var transitionStart: CFTimeInterval?
    /// The warp's clock: advances at `currentSpeed`, which eases toward 1 playing, 0.1 paused.
    private var time: Double = 0
    private var currentSpeed: Double = 0.1
    private var frameIndex: Float = 0
    private var imageKey: String?
    private var processing: Task<Void, Never>?

    var animated = true { didSet { if animated != oldValue { updatePausing() } } }
    var playing = false { didSet { if playing != oldValue { updatePausing() } } }
    var speedScale: Double = 1
    var saturationScale: Double = 1 { didSet { if saturationScale != oldValue { redrawIfStill() } } }

    init() {
        super.init(fragment: "kawarpFragment")
        drawableSize = CGSize(width: 300, height: 150)
        current = black
        incoming = black
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { processing?.cancel() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updatePausing()
        redrawIfStill()
    }

    /// A new cover cross-fades in; the same cover with a new blur just replaces itself.
    func setImage(_ image: UIImage?, id: String, blur: Double) {
        let passes = max(1, min(40, Int((8 * blur).rounded())))
        let key = image == nil ? "" : "\(id)|\(passes)"
        guard key != imageKey else { return }
        let sameCover = image != nil && imageKey?.hasPrefix(id + "|") == true
        imageKey = key
        processing?.cancel()
        guard let image else {
            if let black { show(black, crossfade: true) }
            return
        }
        processing = Task.detached(priority: .userInitiated) { [weak self] in
            guard let pixels = KawarpBlur.process(image, passes: passes), !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.imageKey == key, let texture = Self.makeTexture(pixels) else { return }
                self.show(texture, crossfade: !sameCover)
            }
        }
    }

    private func show(_ texture: MTLTexture, crossfade: Bool) {
        if crossfade {
            current = incoming
            incoming = texture
            transitionStart = MediaClock.now()
        } else {
            incoming = texture
            if transitionStart == nil { current = texture }
        }
        updatePausing()
        redrawIfStill()
    }

    override func encode(_ encoder: MTLRenderCommandEncoder, dt: Double, now: CFTimeInterval) {
        // Per-frame smoothing like the original's (5 % a frame at 60 fps).
        let target = playing ? 1.0 : 0.1
        currentSpeed += (target - currentSpeed) * (1 - pow(0.95, dt * 60))
        if animated { time += dt * currentSpeed * speedScale }
        var blend = 1.0
        if let start = transitionStart {
            let progress = min(1, (now - start) / Self.transitionDuration)
            blend = 0.5 - 0.5 * cos(progress * .pi)
            if progress >= 1 {
                transitionStart = nil
                current = incoming
            }
        }
        frameIndex = (frameIndex + 1).truncatingRemainder(dividingBy: 10_000)
        var uniforms = Uniforms(time: Float(time), blend: Float(blend), intensity: 1,
                                saturation: Float(1.5 * saturationScale), dithering: 0.008, scale: 1, frame: frameIndex)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(current, index: 0)
        encoder.setFragmentTexture(incoming, index: 1)
    }

    override func didDraw(now: CFTimeInterval) {
        updatePausing()
    }

    /// Frames only while something moves: always when animated (30 fps playing, 12 paused: at a
    /// tenth of the speed nothing moves enough to need more),
    /// otherwise just while a new cover fades in.
    private func updatePausing() {
        let moving = (animated || transitionStart != nil) && window != nil
        if isPaused == moving {
            isPaused = !moving
            if moving { resetClock() }
        }
        let fps = playing || transitionStart != nil ? 30 : 12
        if preferredFramesPerSecond != fps { preferredFramesPerSecond = fps }
    }

    private func redrawIfStill() {
        guard isPaused, window != nil, bounds.width > 0 else { return }
        draw()
    }

    private static func makeTexture(_ pixels: [Float16]?) -> MTLTexture? {
        guard let device = sharedDevice else { return nil }
        let n = KawarpBlur.size
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: n, height: n,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        var data = pixels ?? {
            var black = [Float16](repeating: 0, count: n * n * 4)
            for i in stride(from: 3, to: black.count, by: 4) { black[i] = 1 }
            return black
        }()
        data.withUnsafeMutableBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0,
                            withBytes: bytes.baseAddress!, bytesPerRow: n * 4 * MemoryLayout<Float16>.size)
        }
        return texture
    }
}

/// @kawarp/core's image pipeline on the CPU, once per cover: down to 128×128, then Kawase blur
/// passes (four diagonal bilinear taps at ±(i + 0.5) texels), kept in half floats so the soft
/// gradients don't band.
enum KawarpBlur {
    static let size = 128

    static func process(_ image: UIImage, passes: Int) -> [Float16]? {
        guard let cgImage = image.cgImage else { return nil }
        let n = size
        var bytes = [UInt8](repeating: 0, count: n * n * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: n, height: n, bitsPerComponent: 8,
                                          bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard drawn else { return nil }

        var read = [Float](repeating: 1, count: n * n * 4)
        for i in 0..<(n * n) {
            read[i * 4] = Float(bytes[i * 4]) / 255
            read[i * 4 + 1] = Float(bytes[i * 4 + 1]) / 255
            read[i * 4 + 2] = Float(bytes[i * 4 + 2]) / 255
        }
        var write = read
        for pass in 0..<max(1, passes) {
            let offset = Float(pass) + 0.5
            read.withUnsafeBufferPointer { source in
                write.withUnsafeMutableBufferPointer { target in
                    for y in 0..<n {
                        for x in 0..<n {
                            var r: Float = 0, g: Float = 0, b: Float = 0
                            for tap in 0..<4 {
                                let sx = Float(x) + (tap & 1 == 0 ? -offset : offset)
                                let sy = Float(y) + (tap & 2 == 0 ? -offset : offset)
                                accumulate(source, n, sx, sy, &r, &g, &b)
                            }
                            let o = (y * n + x) * 4
                            target[o] = r * 0.25
                            target[o + 1] = g * 0.25
                            target[o + 2] = b * 0.25
                            target[o + 3] = 1
                        }
                    }
                }
            }
            swap(&read, &write)
        }
        return read.map { Float16($0) }
    }

    /// Adds the clamp-to-edge bilinear sample at pixel position (px, py), texel centres on integers.
    @inline(__always)
    private static func accumulate(_ image: UnsafeBufferPointer<Float>, _ n: Int, _ px: Float, _ py: Float,
                                   _ r: inout Float, _ g: inout Float, _ b: inout Float) {
        let fx0 = px.rounded(.down), fy0 = py.rounded(.down)
        let fx = px - fx0, fy = py - fy0
        let x0 = min(max(Int(fx0), 0), n - 1), x1 = min(max(Int(fx0) + 1, 0), n - 1)
        let y0 = min(max(Int(fy0), 0), n - 1), y1 = min(max(Int(fy0) + 1, 0), n - 1)
        let i00 = (y0 * n + x0) * 4, i10 = (y0 * n + x1) * 4
        let i01 = (y1 * n + x0) * 4, i11 = (y1 * n + x1) * 4
        let w00 = (1 - fx) * (1 - fy), w10 = fx * (1 - fy), w01 = (1 - fx) * fy, w11 = fx * fy
        r += image[i00] * w00 + image[i10] * w10 + image[i01] * w01 + image[i11] * w11
        g += image[i00 + 1] * w00 + image[i10 + 1] * w10 + image[i01 + 1] * w01 + image[i11 + 1] * w11
        b += image[i00 + 2] * w00 + image[i10 + 2] * w10 + image[i01 + 2] * w01 + image[i11 + 2] * w11
    }
}

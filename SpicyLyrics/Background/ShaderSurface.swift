import MetalKit
import QuartzCore
import UIKit

/// A Metal view that draws one full-screen fragment shader into a small drawable which the
/// compositor stretches over the view (with linear filtering). Subclasses fill in the uniforms.
class ShaderSurface: MTKView, MTKViewDelegate {
    static let sharedDevice = MTLCreateSystemDefaultDevice()
    static let library: MTLLibrary? = {
        guard let device = sharedDevice else { return nil }
        if let library = device.makeDefaultLibrary() { return library }
        #if SWIFT_PACKAGE
        // xtool cannot compile Metal on Linux; compile the bundled source on the device.
        guard let url = Bundle.main.url(forResource: "Shaders", withExtension: "metal"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return try? device.makeLibrary(source: source, options: nil)
        #else
        return nil
        #endif
    }()
    private static let commandQueue = sharedDevice?.makeCommandQueue()

    private var pipeline: MTLRenderPipelineState?
    private var lastFrame: CFTimeInterval?

    /// The view can draw (Metal is there and the shader compiled).
    var isReady: Bool { pipeline != nil }

    init(fragment: String) {
        super.init(frame: .zero, device: Self.sharedDevice)
        if let device = Self.sharedDevice, let library = Self.library,
           let vertexFunction = library.makeFunction(name: "surfaceVertex"),
           let fragmentFunction = library.makeFunction(name: fragment) {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
        }
        delegate = self
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        isOpaque = true
        backgroundColor = .black
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        autoResizeDrawable = false
        enableSetNeedsDisplay = false
        preferredFramesPerSecond = 30
        isUserInteractionEnabled = false
        layer.magnificationFilter = .linear
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = MediaClock.now()
        let dt = min(0.1, max(0, now - (lastFrame ?? now)))
        lastFrame = now
        guard let pipeline, let queue = Self.commandQueue,
              let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encode(encoder, dt: dt, now: now)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
        didDraw(now: now)
    }

    /// Sets the fragment's uniforms and textures for this frame.
    func encode(_ encoder: MTLRenderCommandEncoder, dt: Double, now: CFTimeInterval) {}

    func didDraw(now: CFTimeInterval) {}

    /// Restarts the frame clock (after a pause the first step would be huge).
    func resetClock() { lastFrame = nil }
}

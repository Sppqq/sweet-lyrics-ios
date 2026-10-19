import CoreImage
import QuartzCore
import SwiftUI
import UIKit

/// The cover behind the lyrics, flowing like liquid (the original's Kawarp, see
/// `KawarpBackground`) and cross-fading from song to song.
///
/// Kawarp draws only 300×150 pixels a frame; no full-screen live blur, which is what made an
/// earlier shader-based background heat the phone. Without Metal it falls back to blurred
/// copies of the cover drifting on Core Animation (`CoverBlobsView`).
struct DynamicBackground: View {
    let image: UIImage?
    let imageID: String
    /// The artist's photo for the "Фото артиста" style, once it has loaded.
    var artistImage: UIImage? = nil
    /// The song's Canvas for the "Canvas" style, when it has one.
    var canvasURL: URL? = nil
    let animated: Bool
    /// The flow slows to a tenth while the song is paused.
    var playing = true
    /// Black layer on top, keeps white lyrics readable on bright covers.
    var dim: Double = AppSettings.defaultBackgroundDim
    /// × the default drift speed.
    var speed: Double = 1
    /// × the default cover blur.
    var blur: Double = 1
    /// × the default cover saturation.
    var saturation: Double = 1
    @Environment(AppSettings.self) private var settings

    var body: some View {
        if let gradient = settings.appTheme.gradient {
            // A fixed theme: no cover, nothing moving.
            Rectangle().fill(gradient)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        } else {
            coverBackground
        }
    }

    private var style: BackgroundStyle { settings.background }

    /// The cover keeps flowing under the other styles until their picture is there.
    private var coverMoves: Bool { animated && style != .cover }

    /// A video needs more darkening than a blurred cover for white text to read on it.
    private var canvasShown: Bool { style == .canvas && canvasURL != nil && image != nil }

    private var coverBackground: some View {
        ZStack {
            Color(red: 0.07, green: 0.07, blue: 0.08)
            if KawarpBackground.isSupported {
                KawarpBackground(image: image, imageID: imageID, animated: coverMoves, playing: playing,
                                 speed: speed, blur: blur, saturation: saturation)
            } else {
                CoverBlobs(image: image, imageID: imageID, animated: coverMoves, speed: speed, blur: blur, saturation: saturation)
            }
            if style == .artist, let artistImage, image != nil {
                // `Image Blur`: the photo stays recognisable, just soft.
                Color.clear
                    .overlay {
                        Image(uiImage: artistImage)
                            .resizable()
                            .scaledToFill()
                            .blur(radius: 18 * blur, opaque: true)
                            .saturation(saturation)
                    }
                    .clipped()
                    .transition(.opacity)
            }
            if canvasShown, let canvasURL {
                CanvasVideoView(url: canvasURL, playing: playing)
                    .saturation(saturation)
                    .transition(.opacity)
            }
            Color.black.opacity(canvasShown ? min(0.85, dim + 0.15) : dim)
        }
        .animation(.easeInOut(duration: 0.8), value: artistImage)
        .animation(.easeInOut(duration: 0.8), value: canvasURL)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private struct CoverBlobs: UIViewRepresentable {
    let image: UIImage?
    let imageID: String
    let animated: Bool
    let speed: Double
    let blur: Double
    let saturation: Double

    func makeUIView(context: Context) -> CoverBlobsView { CoverBlobsView() }

    func updateUIView(_ view: CoverBlobsView, context: Context) {
        view.setAnimated(animated)
        view.setSpeed(speed)
        view.setImage(image, id: image == nil ? "" : imageID, blur: blur, saturation: saturation)
    }
}

final class CoverBlobsView: UIView {
    /// One full-bleed layer and three soft "blobs" on top, each turning and drifting at its own pace.
    private struct LayerSpec {
        var size: CGFloat          // × the view's diagonal
        var center: CGPoint        // fraction of the view
        var rotationPeriod: Double // seconds per turn; negative turns the other way
        var drift: CGSize          // ellipse radii, fraction of the view
        var driftPeriod: Double
        var isBlob: Bool
    }

    private static let specs: [LayerSpec] = [
        LayerSpec(size: 1.35, center: CGPoint(x: 0.5, y: 0.5), rotationPeriod: 60, drift: .zero, driftPeriod: 0, isBlob: false),
        LayerSpec(size: 0.95, center: CGPoint(x: 0.22, y: 0.24), rotationPeriod: -40, drift: CGSize(width: 0.16, height: 0.12), driftPeriod: 19, isBlob: true),
        LayerSpec(size: 0.85, center: CGPoint(x: 0.82, y: 0.68), rotationPeriod: 32, drift: CGSize(width: 0.14, height: 0.15), driftPeriod: 23, isBlob: true),
        LayerSpec(size: 0.75, center: CGPoint(x: 0.3, y: 0.86), rotationPeriod: -50, drift: CGSize(width: 0.15, height: 0.1), driftPeriod: 27, isBlob: true),
    ]

    /// CIContext is thread-safe; renders run off the main thread.
    nonisolated private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    private let container = CALayer()
    private var coverLayers: [CALayer] = []
    private var currentID: String?
    private var speed: Double = 1
    /// Size the running animations were built for; other layout passes leave them alone.
    private var animatedSize: CGSize = .zero
    /// Size the cover layers were laid out for.
    private var layoutSize: CGSize = .zero
    private var animated = true
    private var processing: Task<Void, Never>?
    private var foregroundObserver: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        layer.addSublayer(container)
        for _ in Self.specs {
            let cover = CALayer()
            cover.contentsGravity = .resizeAspectFill
            cover.magnificationFilter = .linear
            cover.minificationFilter = .linear
            container.addSublayer(cover)
            coverLayers.append(cover)
        }
        // Infinite animations are dropped while the app is in the background.
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.restartAnimations() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        processing?.cancel()
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // SwiftUI lays this view out often; restarting here kept snapping the layers back to
        // their first frame, so the background looked frozen. The layers are sized on their own
        // key: `didMoveToWindow` can start the animations before the first layout, and keying
        // the sizing on the animations then left the layers at zero size (a black background).
        guard bounds.size != layoutSize || bounds.size != animatedSize else { return }
        layoutSize = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = bounds
        let diagonal = hypot(bounds.width, bounds.height)
        for (cover, spec) in zip(coverLayers, Self.specs) {
            let side = diagonal * spec.size
            cover.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            cover.position = CGPoint(x: bounds.width * spec.center.x, y: bounds.height * spec.center.y)
        }
        CATransaction.commit()
        restartAnimations()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        restartAnimations()
    }

    func setAnimated(_ value: Bool) {
        guard value != animated else { return }
        animated = value
        restartAnimations()
    }

    /// Changes the drift speed without the layers jumping: the clock continues from where it is.
    func setSpeed(_ value: Double) {
        let value = max(0.1, value)
        guard value != speed else { return }
        speed = value
        let now = CACurrentMediaTime()
        let local = container.convertTime(now, from: nil)
        container.beginTime = now
        container.timeOffset = local
        container.speed = Float(value)
    }

    func setImage(_ image: UIImage?, id: String, blur: Double = 1, saturation: Double = 1) {
        // Blur and saturation are part of the key: changing them re-renders the cover.
        let key = image == nil ? "" : "\(id)|\(blur)|\(saturation)"
        guard key != currentID else { return }
        currentID = key
        processing?.cancel()
        guard let image else {
            apply(base: nil, blob: nil)
            return
        }
        let id = key
        processing = Task.detached(priority: .utility) { [weak self] in
            let rendered = CoverBlobsView.render(image, blur: blur, saturation: saturation)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.currentID == id else { return }
                self.apply(base: rendered?.base, blob: rendered?.blob)
            }
        }
    }

    // MARK: Rendering

    private func apply(base: CGImage?, blob: CGImage?) {
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 1.0
        container.add(fade, forKey: "crossfade")
        for (cover, spec) in zip(coverLayers, Self.specs) {
            cover.contents = spec.isBlob ? blob : base
        }
    }

    /// Small, saturated, pre-blurred copies: one opaque, one fading out radially for the blobs.
    /// Scaled up to fill the screen, a tiny image looks exactly like a heavy blur.
    nonisolated static func render(_ image: UIImage, blur: Double = 1, saturation: Double = 1) -> (base: CGImage, blob: CGImage)? {
        let blur = clamp(blur, 0.3, 3)
        let saturation = clamp(saturation, 0, 2)
        guard let cgImage = image.downscaled(to: CGFloat(96 / blur)).cgImage else { return nil }
        let input = CIImage(cgImage: cgImage)
        let extent = input.extent
        let colored = input.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 1.7 * saturation,
            kCIInputBrightnessKey: -0.03,
            kCIInputContrastKey: 1.05,
        ])
        let blurred = colored.clampedToExtent().applyingGaussianBlur(sigma: 4 * blur).cropped(to: extent)
        guard let base = ciContext.createCGImage(blurred, from: extent) else { return nil }

        let radius = min(extent.width, extent.height) / 2
        guard let gradient = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: extent.midX, y: extent.midY),
            "inputRadius0": radius * 0.3,
            "inputRadius1": radius,
            "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
            "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 0),
        ])?.outputImage?.cropped(to: extent) else { return nil }
        let blobImage = blurred.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: gradient,
        ])
        guard let blob = ciContext.createCGImage(blobImage, from: extent) else { return nil }
        return (base, blob)
    }

    // MARK: Motion

    private func restartAnimations() {
        for cover in coverLayers { cover.removeAllAnimations() }
        animatedSize = .zero
        guard animated, window != nil, bounds.width > 0 else { return }
        animatedSize = bounds.size
        // Slow motion looks the same at 30 fps and costs half as much.
        let frameRate = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)

        for (cover, spec) in zip(coverLayers, Self.specs) {
            let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
            rotation.fromValue = 0
            rotation.toValue = (spec.rotationPeriod < 0 ? -1 : 1) * 2 * Double.pi
            rotation.duration = abs(spec.rotationPeriod)
            rotation.repeatCount = .infinity
            rotation.isRemovedOnCompletion = false
            rotation.preferredFrameRateRange = frameRate
            cover.add(rotation, forKey: "rotation")

            guard spec.driftPeriod > 0 else { continue }
            let radii = CGSize(width: bounds.width * spec.drift.width, height: bounds.height * spec.drift.height)
            let center = cover.position
            let drift = CAKeyframeAnimation(keyPath: "position")
            drift.path = CGPath(ellipseIn: CGRect(x: center.x - radii.width, y: center.y - radii.height,
                                                  width: radii.width * 2, height: radii.height * 2), transform: nil)
            drift.calculationMode = .paced
            drift.duration = spec.driftPeriod
            drift.repeatCount = .infinity
            drift.isRemovedOnCompletion = false
            drift.preferredFrameRateRange = frameRate
            cover.add(drift, forKey: "drift")
        }
    }
}

extension UIImage {
    /// A small copy, drawn at scale 1.
    func downscaled(to maxSide: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxSide else { return self }
        let scale = maxSide / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

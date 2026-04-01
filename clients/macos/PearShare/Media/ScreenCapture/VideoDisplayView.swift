import SwiftUI
import MetalKit
import CoreVideo
import Combine

// MARK: - SwiftUI wrapper

struct VideoDisplayView: NSViewRepresentable {
    let renderer: VideoRenderer

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = renderer.device
        view.delegate = renderer
        view.framebufferOnly = true
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60
        view.colorPixelFormat = .bgra8Unorm
        // Opt into Retina rendering: match the CAMetalLayer's contentsScale to the display's
        // backing scale factor. MTKView.autoResizeDrawable (default true) then sizes the
        // drawable to physical pixels (2× on Retina), giving crisp 1:1 rendering.
        view.layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        renderer.view = view
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}
}

// MARK: - VideoRenderer

/// Metal-based renderer for decoded CVPixelBuffers.
/// Maintains a texture cache for zero-copy GPU access to CVPixelBuffers.
final class VideoRenderer: NSObject, MTKViewDelegate {

    let device: MTLDevice
    weak var view: MTKView?

    /// Set once on the first decoded frame. Dimensions are in physical pixels (not points).
    /// AppDelegate observes this to size the viewer window at 1:1 or scale-to-fit.
    @Published private(set) var sourceDimensions: CGSize? = nil

    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    private var currentPixelBuffer: CVPixelBuffer?
    private let bufferLock = NSLock()
    private var hasLoggedFirstDraw = false

    // MARK: - Init

    static func make() -> VideoRenderer? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertexFn = library.makeFunction(name: "vertexPassthrough"),
              let fragmentFn = library.makeFunction(name: "fragmentYCbCrToRGB") else {
            print("[VideoRenderer] Metal device/shaders not available")
            return nil
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertexFn
        desc.fragmentFunction = fragmentFn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        return VideoRenderer(device: device, commandQueue: queue, pipelineState: pipeline)
    }

    private init(device: MTLDevice, commandQueue: MTLCommandQueue, pipelineState: MTLRenderPipelineState) {
        self.device = device
        self.commandQueue = commandQueue
        self.pipelineState = pipelineState
        super.init()
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    }

    // MARK: - Feed decoded frames

    func enqueue(pixelBuffer: CVPixelBuffer) {
        if sourceDimensions == nil {
            let w = CVPixelBufferGetWidth(pixelBuffer)
            let h = CVPixelBufferGetHeight(pixelBuffer)
            sourceDimensions = CGSize(width: w, height: h)
            tapLog("[VIEWER-1] First decoded pixel buffer: \(w)×\(h) px")
        }
        bufferLock.lock()
        currentPixelBuffer = pixelBuffer
        bufferLock.unlock()
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        tapLog("[VIEWER-2] MTKView drawableSize → \(Int(size.width))×\(Int(size.height)) px  |  viewBounds=\(Int(view.bounds.width))×\(Int(view.bounds.height)) pts  |  contentsScale=\(view.layer?.contentsScale ?? -1)")
    }

    func draw(in view: MTKView) {
        bufferLock.lock()
        guard let pixelBuffer = currentPixelBuffer else {
            bufferLock.unlock()
            return
        }
        bufferLock.unlock()

        guard let cache = textureCache,
              let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        // Create Metal textures from the CVPixelBuffer planes (zero-copy via IOSurface)
        let width  = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        if !hasLoggedFirstDraw {
            hasLoggedFirstDraw = true
            let ds = view.drawableSize
            tapLog("[VIEWER-3] First draw: pixelBuffer=\(width)×\(height)  |  drawable=\(Int(ds.width))×\(Int(ds.height))  |  viewBounds=\(Int(view.bounds.width))×\(Int(view.bounds.height)) pts  |  contentsScale=\(view.layer?.contentsScale ?? 1.0)")
        }

        guard let yTexture  = makeTexture(from: pixelBuffer, cache: cache, planeIndex: 0, format: .r8Unorm,   width: width,    height: height),
              let uvTexture = makeTexture(from: pixelBuffer, cache: cache, planeIndex: 1, format: .rg8Unorm, width: width / 2, height: height / 2) else {
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(yTexture,  index: 0)
        encoder.setFragmentTexture(uvTexture, index: 1)

        // Draw fullscreen triangle strip (no vertex buffer needed — vertices in shader)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Texture creation

    private func makeTexture(
        from pixelBuffer: CVPixelBuffer,
        cache: CVMetalTextureCache,
        planeIndex: Int,
        format: MTLPixelFormat,
        width: Int,
        height: Int
    ) -> MTLTexture? {
        var metalTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pixelBuffer, nil,
            format, width, height, planeIndex,
            &metalTexture
        )
        guard status == kCVReturnSuccess, let metalTexture else { return nil }
        return CVMetalTextureGetTexture(metalTexture)
    }
}

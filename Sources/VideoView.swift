import AppKit
import Libmpv
import OpenGL.GL3

/// Draws mpv frames through the libmpv OpenGL render API.
///
/// The CGL context and the mpv render context are made up front, because
/// `vo=libmpv` fails to initialize when no render context exists at load time.
final class VideoLayer: CAOpenGLLayer {
    private let pixelFormat: CGLPixelFormatObj
    private let glContext: CGLContextObj
    private var renderContext: OpaquePointer?

    init(player: MPVPlayer) {
        let attributes: [CGLPixelFormatAttribute] = [
            kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(UInt32(kCGLOGLPVersion_3_2_Core.rawValue)),
            kCGLPFAAccelerated,
            kCGLPFADoubleBuffer,
            kCGLPFAAllowOfflineRenderers,
            CGLPixelFormatAttribute(0),
        ]
        var format: CGLPixelFormatObj?
        var count: GLint = 0
        CGLChoosePixelFormat(attributes, &format, &count)
        guard let format else { fatalError("No OpenGL pixel format") }

        var context: CGLContextObj?
        CGLCreateContext(format, nil, &context)
        guard let context else { fatalError("No OpenGL context") }

        pixelFormat = format
        glContext = context
        super.init()

        isAsynchronous = false
        isOpaque = true
        backgroundColor = NSColor.black.cgColor
        needsDisplayOnBoundsChange = true

        createRenderContext(player: player)
    }

    override init(layer: Any) {
        let other = layer as! VideoLayer
        pixelFormat = other.pixelFormat
        glContext = other.glContext
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func createRenderContext(player: MPVPlayer) {
        CGLLockContext(glContext)
        CGLSetCurrentContext(glContext)
        defer { CGLUnlockContext(glContext) }

        var initParams = mpv_opengl_init_params(
            get_proc_address: { _, name in
                guard let name else { return nil }
                let symbol = CFStringCreateWithCString(kCFAllocatorDefault, name, CFStringBuiltInEncodings.ASCII.rawValue)
                let bundle = CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString)
                return CFBundleGetFunctionPointerForName(bundle, symbol)
            },
            get_proc_address_ctx: nil
        )

        MPV_RENDER_API_TYPE_OPENGL.withCString { apiType in
            withUnsafeMutablePointer(to: &initParams) { initParamsPointer in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(mutating: apiType)),
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: initParamsPointer),
                    mpv_render_param(),
                ]
                guard mpv_render_context_create(&renderContext, player.handle, &params) >= 0 else {
                    fatalError("mpv_render_context_create failed")
                }
            }
        }

        mpv_render_context_set_update_callback(renderContext, { context in
            let layer = Unmanaged<VideoLayer>.fromOpaque(context!).takeUnretainedValue()
            DispatchQueue.main.async { layer.setNeedsDisplay() }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Must run before the player is destroyed.
    func destroy() {
        guard let renderContext else { return }
        self.renderContext = nil
        CGLLockContext(glContext)
        CGLSetCurrentContext(glContext)
        mpv_render_context_set_update_callback(renderContext, nil, nil)
        mpv_render_context_free(renderContext)
        CGLUnlockContext(glContext)
    }

    /// Give mpv the display's ICC profile, so it converts colors for that screen.
    func setICCProfile(_ profile: Data) {
        guard let renderContext else { return }
        CGLLockContext(glContext)
        CGLSetCurrentContext(glContext)
        defer { CGLUnlockContext(glContext) }

        var bytes = [UInt8](profile)
        bytes.withUnsafeMutableBytes { buffer in
            var array = mpv_byte_array(data: buffer.baseAddress, size: buffer.count)
            withUnsafeMutablePointer(to: &array) { arrayPointer in
                let param = mpv_render_param(type: MPV_RENDER_PARAM_ICC_PROFILE, data: arrayPointer)
                mpv_render_context_set_parameter(renderContext, param)
            }
        }
        setNeedsDisplay()
    }

    // MARK: - CAOpenGLLayer

    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        CGLRetainPixelFormat(pixelFormat)
    }

    override func copyCGLContext(forPixelFormat pf: CGLPixelFormatObj) -> CGLContextObj {
        CGLRetainContext(glContext)
    }

    override func canDraw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                          forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool {
        renderContext != nil
    }

    override func draw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                       forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) {
        guard let renderContext else { return }

        var framebuffer: GLint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &framebuffer)
        var viewport = [GLint](repeating: 0, count: 4)
        glGetIntegerv(GLenum(GL_VIEWPORT), &viewport)

        var fbo = mpv_opengl_fbo(fbo: Int32(framebuffer), w: viewport[2], h: viewport[3], internal_format: 0)
        var flipY: CInt = 1
        withUnsafeMutablePointer(to: &fbo) { fboPointer in
            withUnsafeMutablePointer(to: &flipY) { flipPointer in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: fboPointer),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: flipPointer),
                    mpv_render_param(),
                ]
                mpv_render_context_render(renderContext, &params)
            }
        }
        glFlush()
    }
}

/// Hosts the video layer. Black letterboxing fills any space the video does not.
final class VideoView: NSView {
    let videoLayer: VideoLayer

    init(player: MPVPlayer) {
        videoLayer = VideoLayer(player: player)
        super.init(frame: .zero)
        layer = videoLayer
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isOpaque: Bool { true }

    func useColorProfile(of screen: NSScreen?) {
        guard let profile = screen?.colorSpace?.iccProfileData else { return }
        videoLayer.setICCProfile(profile)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        videoLayer.contentsScale = window?.backingScaleFactor ?? 2
        videoLayer.setNeedsDisplay()
    }
}

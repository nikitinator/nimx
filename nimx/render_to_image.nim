import image
import portable_gl
import context
import math
import opengl

type GlFrameState* = tuple[
    clearColor: array[4, GLfloat],
    viewportSize: array[4, GLint],
    renderbuffer: RenderbufferRef,
    framebuffer: FramebufferRef,
    bStencil: bool
]

proc bindFramebuffer*(gl: GL, i: SelfContainedImage, makeDepthAndStencil: bool = true) =
    if i.mRenderTarget.isNil:
        i.mRenderTarget = newImageRenderTarget()
    let rt = i.mRenderTarget
    if rt.framebuffer.isEmpty:
        var texCoords : array[4, GLfloat]
        var texture = i.getTextureQuad(gl, texCoords)

        if texture.isEmpty:
            texture = gl.createTexture()
            i.texture = texture

        rt.framebuffer = gl.createFramebuffer()
        gl.bindFramebuffer(gl.FRAMEBUFFER, rt.framebuffer)
        gl.bindTexture(gl.TEXTURE_2D, texture)
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)

        let texWidth = if isPowerOfTwo(i.size.width.int): i.size.width.int else: nextPowerOfTwo(i.size.width.int)
        let texHeight = if isPowerOfTwo(i.size.height.int): i.size.height.int else: nextPowerOfTwo(i.size.height.int)

        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA.GLint, texWidth.GLsizei, texHeight.GLsizei, 0, gl.RGBA, gl.UNSIGNED_BYTE, nil)
        gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, texture, 0)
        if makeDepthAndStencil:
            let depthBuffer = gl.createRenderbuffer()
            gl.bindRenderbuffer(gl.RENDERBUFFER, depthBuffer)

            let depthStencilFormat = when defined(js) or defined(emscripten): gl.DEPTH_STENCIL else: gl.DEPTH24_STENCIL8

            # TODO: The following is a very dirty fix for ES 2.0 devices that don't support DEPTH_STENCIL_ATTACHMENT
            # for such devices we provide only DEPTH attachment, which can result in artifacts when drawing relies
            # on stencil buffer. This should be fixed with refactoring of render-to-texture system.
            when NoAutoGLerrorCheck:
                discard gl.getError()
                gl.renderbufferStorage(gl.RENDERBUFFER, depthStencilFormat, texWidth.GLsizei, texHeight.GLsizei)
                if gl.getError() == 0.GLenum:
                    gl.framebufferRenderbuffer(gl.FRAMEBUFFER, gl.DEPTH_STENCIL_ATTACHMENT, gl.RENDERBUFFER, depthBuffer)
                else:
                    gl.renderbufferStorage(gl.RENDERBUFFER, gl.DEPTH_COMPONENT16, texWidth.GLsizei, texHeight.GLsizei)
                    gl.framebufferRenderbuffer(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, gl.RENDERBUFFER, depthBuffer)
            else:
                try:
                    gl.renderbufferStorage(gl.RENDERBUFFER, depthStencilFormat, texWidth.GLsizei, texHeight.GLsizei)
                    gl.framebufferRenderbuffer(gl.FRAMEBUFFER, gl.DEPTH_STENCIL_ATTACHMENT, gl.RENDERBUFFER, depthBuffer)
                except:
                    gl.renderbufferStorage(gl.RENDERBUFFER, gl.DEPTH_COMPONENT16, texWidth.GLsizei, texHeight.GLsizei)
                    gl.framebufferRenderbuffer(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, gl.RENDERBUFFER, depthBuffer)

            rt.renderbuffer = depthBuffer
    else:
        gl.bindFramebuffer(gl.FRAMEBUFFER, rt.framebuffer)

proc getGlFrameState*(gfs: var GlFrameState) =
    let gl = sharedGL()
    gfs.framebuffer = gl.boundFramebuffer()
    gfs.viewportSize = gl.getViewport()
    gfs.renderbuffer = gl.boundRenderbuffer()
    gfs.bStencil = gl.getParamb(gl.STENCIL_TEST)
    gl.getClearColor(gfs.clearColor)

proc setImageGlFrameState*(sci: SelfContainedImage) =
    let gl = sharedGL()
    gl.bindFramebuffer(sci)
    gl.viewport(0, 0, sci.size.width.GLsizei, sci.size.height.GLsizei)
    gl.stencilMask(0xFF) # Android requires setting stencil mask to clear
    gl.clearColor(0, 0, 0, 0)
    gl.clear(gl.COLOR_BUFFER_BIT or gl.DEPTH_BUFFER_BIT or gl.STENCIL_BUFFER_BIT)
    gl.stencilMask(0x00) # Android requires setting stencil mask to clear
    gl.disable(gl.STENCIL_TEST)

proc restoreGlFrameState*(gfs: var GlFrameState) =
    let gl = sharedGL()
    if gfs.bStencil:
        gl.enable(gl.STENCIL_TEST)
    gl.clearColor(gfs.clearColor[0], gfs.clearColor[1], gfs.clearColor[2], gfs.clearColor[3])
    gl.viewport(gfs.viewportSize)
    gl.bindRenderbuffer(gl.RENDERBUFFER, gfs.renderbuffer)
    gl.bindFramebuffer(gl.FRAMEBUFFER, gfs.framebuffer)

proc beginDraw*(sci: SelfContainedImage, gfs: var GlFrameState) =
    getGlFrameState(gfs)
    sci.setImageGlFrameState()

proc endDraw*(sci: SelfContainedImage, gfs: var GlFrameState) =
    restoreGlFrameState(gfs)

proc draw*(sci: SelfContainedImage, drawProc: proc()) =
    var gfs: GlFrameState
    beginDraw(sci, gfs)
    currentContext().withTransform ortho(0, sci.size.width, sci.size.height, 0, -1, 1):
        drawProc()
    endDraw(sci, gfs)
    # OpenGL framebuffer coordinate system is flipped comparing to how we load
    # and handle the rest of images. Compensate for that by flipping texture
    # coords here.
    if not sci.flipped:
        sci.flipVertically()

proc draw*(i: Image, drawProc: proc()) {.deprecated.} =
    let sci = SelfContainedImage(i)
    if sci.isNil:
        raise newException(Exception, "Not implemented: Can draw only to SelfContainedImage")
    sci.draw(drawProc)


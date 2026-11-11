package com.smart.aveditor.nativevideo

import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer

/**
 * Samples decoder OES textures and draws the composed frame into the Flutter
 * [SurfaceTexture] window. Runs on a dedicated GL thread owned by
 * [TimelineEngineSession].
 */
internal class EngineCompositor {
  private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
  private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
  private var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE
  private var program = 0
  private var aPos = 0
  private val uniforms = HashMap<String, Int>()
  private var texA = 0
  private var texB = 0
  private var stA: SurfaceTexture? = null
  private var stB: SurfaceTexture? = null
  var surfaceA: Surface? = null
    private set
  var surfaceB: Surface? = null
    private set
  private val quad: FloatBuffer = ByteBuffer.allocateDirect(8 * 4)
    .order(ByteOrder.nativeOrder())
    .asFloatBuffer()
    .put(floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f))
  private var ready = false

  fun init(output: Surface, width: Int, height: Int) {
    eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
    val ver = IntArray(2)
    EGL14.eglInitialize(eglDisplay, ver, 0, ver, 1)
    val attrib = intArrayOf(
      EGL14.EGL_RED_SIZE, 8,
      EGL14.EGL_GREEN_SIZE, 8,
      EGL14.EGL_BLUE_SIZE, 8,
      EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
      EGL14.EGL_NONE,
    )
    val configs = arrayOfNulls<EGLConfig>(1)
    val num = IntArray(1)
    EGL14.eglChooseConfig(eglDisplay, attrib, 0, configs, 0, 1, num, 0)
    val ctxAttr = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE)
    eglContext = EGL14.eglCreateContext(
      eglDisplay, configs[0], EGL14.EGL_NO_CONTEXT, ctxAttr, 0,
    )
    val surfAttr = intArrayOf(EGL14.EGL_NONE)
    eglSurface = EGL14.eglCreateWindowSurface(eglDisplay, configs[0], output, surfAttr, 0)
    EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)
    EGL14.eglSurfaceAttrib(
      eglDisplay, eglSurface, EGL14.EGL_SWAP_BEHAVIOR, EGL14.EGL_BUFFER_PRESERVED,
    )

    texA = genOesTex()
    texB = genOesTex()
    stA = SurfaceTexture(texA).also {
      it.setDefaultBufferSize(width, height)
      surfaceA = Surface(it)
    }
    stB = SurfaceTexture(texB).also {
      it.setDefaultBufferSize(width, height)
      surfaceB = Surface(it)
    }
    program = link(VERTEX, FRAGMENT)
    aPos = GLES20.glGetAttribLocation(program, "aPos")
    uniforms.clear()
    ready = true
  }

  /**
   * [blend] is the resolved transition pose for this frame when both tracks
   * are on screen; null draws whichever single track [mask] names.
   * [presentationNs] stamps the frame for an encoder input surface; without it
   * EGL uses the wall clock, so an export would last as long as it took to run.
   */
  fun draw(mask: Int, blend: BlendDraw?, presentationNs: Long? = null) {
    if (!ready) return
    EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)
    try {
      stA?.updateTexImage()
    } catch (_: Exception) {
    }
    try {
      stB?.updateTexImage()
    } catch (_: Exception) {
    }
    val w = IntArray(1)
    val h = IntArray(1)
    EGL14.eglQuerySurface(eglDisplay, eglSurface, EGL14.EGL_WIDTH, w, 0)
    EGL14.eglQuerySurface(eglDisplay, eglSurface, EGL14.EGL_HEIGHT, h, 0)
    GLES20.glViewport(0, 0, w[0].coerceAtLeast(1), h[0].coerceAtLeast(1))
    GLES20.glClearColor(0f, 0f, 0f, 1f)
    GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
    GLES20.glUseProgram(program)

    val dual = mask and 1 != 0 && mask and 2 != 0
    // Solo incoming track: swap units so mode 0 (copy side 0) shows track B.
    // Side 0 of the shader is always the outgoing clip. Solo track 1, and a
    // blend whose outgoing clip sits on track 1 (2nd, 4th… transition), swap units.
    val soloB = !dual && mask and 2 != 0
    val swap = soloB || (dual && blend?.outgoingTrack == 1)
    val d = if (dual) blend ?: BlendDraw(mode = 1, alphaA = 1f, alphaB = 1f) else BlendDraw()
    GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
    GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, if (swap) texB else texA)
    GLES20.glActiveTexture(GLES20.GL_TEXTURE1)
    GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, if (swap) texA else texB)
    u1i("uTex", 0)
    u1i("uIncoming", 1)
    u1i("uMode", if (dual) d.mode else 0)
    u1f("uAspect", w[0].coerceAtLeast(1).toFloat() / h[0].coerceAtLeast(1).toFloat())
    u1f("uT", d.t.coerceIn(0f, 1f))
    u1i("uEdge", d.edge)
    u1f("uAlphaA", d.alphaA)
    u1f("uAlphaB", d.alphaB)
    u1f("uScaleA", d.scaleA)
    u1f("uScaleB", d.scaleB)
    u1f("uRotA", d.rotA)
    u1f("uRotB", d.rotB)
    u2f("uTransA", d.txA, d.tyA)
    u2f("uTransB", d.txB, d.tyB)
    u1f("uBlurA", d.blurA)
    u1f("uBlurB", d.blurB)
    u1f("uZoomA", if (d.zoomA) 1f else 0f)
    u1f("uZoomB", if (d.zoomB) 1f else 0f)
    u1f("uWipeA", d.wipeA)
    u1f("uWipeB", d.wipeB)
    u1i("uWipeEdgeA", d.wipeEdgeA)
    u1i("uWipeEdgeB", d.wipeEdgeB)
    u1f("uBright", d.bright)
    u1f("uWhite", if (d.white) 1f else 0f)
    u1f("uRipple", d.ripple)
    u1f("uAOnTop", if (d.aOnTop) 1f else 0f)
    u1f("uCircleIncoming", if (d.circleIncoming) 1f else 0f)
    u1f("uCols", d.cols)
    u1f("uRows", d.rows)
    u1f("uGap", d.gap)
    u1f("uStagger", d.stagger)
    u1f("uRotYFrom", d.rotYFrom)
    u1f("uRotYTo", d.rotYTo)
    u1f("uHasFlip", if (d.hasFlip) 1f else 0f)
    u1f("uFlipFront", d.flipFront)
    u1i("uEase", d.ease)
    u1f("uReverse", if (d.reverse) 1f else 0f)
    u1f("uScaleFrom", d.scaleFrom)
    u1f("uScaleTo", d.scaleTo)
    u2f("uOffA", d.offAx, d.offAy)
    u2f("uOffB", d.offBx, d.offBy)

    quad.position(0)
    GLES20.glEnableVertexAttribArray(aPos)
    GLES20.glVertexAttribPointer(aPos, 2, GLES20.GL_FLOAT, false, 0, quad)
    GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
    GLES20.glDisableVertexAttribArray(aPos)
    if (presentationNs != null) {
      EGLExt.eglPresentationTimeANDROID(eglDisplay, eglSurface, presentationNs)
    }
    EGL14.eglSwapBuffers(eglDisplay, eglSurface)
  }

  private fun loc(name: String): Int =
    uniforms.getOrPut(name) { GLES20.glGetUniformLocation(program, name) }

  private fun u1f(name: String, v: Float) = GLES20.glUniform1f(loc(name), v)

  private fun u1i(name: String, v: Int) = GLES20.glUniform1i(loc(name), v)

  private fun u2f(name: String, x: Float, y: Float) = GLES20.glUniform2f(loc(name), x, y)

  fun release() {
    surfaceA?.release()
    surfaceB?.release()
    surfaceA = null
    surfaceB = null
    stA?.release()
    stB?.release()
    stA = null
    stB = null
    if (program != 0) GLES20.glDeleteProgram(program)
    program = 0
    if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
      EGL14.eglMakeCurrent(
        eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT,
      )
      if (eglSurface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(eglDisplay, eglSurface)
      if (eglContext != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(eglDisplay, eglContext)
      EGL14.eglTerminate(eglDisplay)
    }
    eglDisplay = EGL14.EGL_NO_DISPLAY
    eglContext = EGL14.EGL_NO_CONTEXT
    eglSurface = EGL14.EGL_NO_SURFACE
    ready = false
  }

  private fun genOesTex(): Int {
    val ids = IntArray(1)
    GLES20.glGenTextures(1, ids, 0)
    GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, ids[0])
    GLES20.glTexParameteri(
      GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR,
    )
    GLES20.glTexParameteri(
      GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR,
    )
    GLES20.glTexParameteri(
      GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE,
    )
    GLES20.glTexParameteri(
      GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE,
    )
    return ids[0]
  }

  private fun link(vertex: String, fragment: String): Int {
    fun compile(type: Int, src: String): Int {
      val s = GLES20.glCreateShader(type)
      GLES20.glShaderSource(s, src)
      GLES20.glCompileShader(s)
      val ok = IntArray(1)
      GLES20.glGetShaderiv(s, GLES20.GL_COMPILE_STATUS, ok, 0)
      if (ok[0] != GLES20.GL_TRUE) {
        val log = GLES20.glGetShaderInfoLog(s)
        GLES20.glDeleteShader(s)
        throw IllegalStateException("engine shader compile: $log")
      }
      return s
    }
    val vs = compile(GLES20.GL_VERTEX_SHADER, vertex)
    val fs = compile(GLES20.GL_FRAGMENT_SHADER, fragment)
    val p = GLES20.glCreateProgram()
    GLES20.glAttachShader(p, vs)
    GLES20.glAttachShader(p, fs)
    GLES20.glLinkProgram(p)
    GLES20.glDeleteShader(vs)
    GLES20.glDeleteShader(fs)
    return p
  }

  companion object {
    // vTex is y-up screen space, the convention of the shared transition GLSL.
    private const val VERTEX = """
      attribute vec4 aPos;
      varying vec2 vTex;
      void main() {
        gl_Position = aPos;
        vTex = aPos.xy * 0.5 + 0.5;
      }
    """
    private const val FRAGMENT = TransitionBlendGlsl.HEAD_OES + TransitionBlendGlsl.UNIFORMS +
      TransitionBlendGlsl.SAMPLE_OES + TransitionBlendGlsl.BODY
  }
}

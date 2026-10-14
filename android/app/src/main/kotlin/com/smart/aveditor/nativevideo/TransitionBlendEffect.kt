package com.smart.aveditor.nativevideo

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.GLES20
import android.opengl.GLUtils
import android.view.Surface
import android.util.Log
import androidx.media3.common.VideoFrameProcessingException
import androidx.media3.common.util.GlUtil
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BaseGlShaderProgram
import androidx.media3.effect.GlEffect
import androidx.media3.effect.GlShaderProgram
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executors
import kotlin.math.abs

/**
 * Draws the same transition decision tree as iOS [ExportFrameCompositor]:
 * doorway, puzzle, ripple, mosaic cells, wipe, blur, and pose layers.
 * The Media3 compositor places outgoing on the left half and incoming on the
 * right half during a blend. This pass paints the final frame.
 */
@UnstableApi
internal class TransitionBlendEffect(
  private val mix: TimelineMix,
) : GlEffect {
  override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram {
    return TransitionBlendProgram(useHdr, mix)
  }
}

@UnstableApi
private class TransitionBlendProgram(
  useHdr: Boolean,
  private val mix: TimelineMix,
) : BaseGlShaderProgram(useHdr, 1) {
  private val incoming = IncomingFrameSource()
  private var program = 0
  private var position = 0
  private var drawLogs = 0
  private var lastDrawKey = ""
  private var drawnBlendStart = -1L
  private var drawnSplit = false
  private val quad = ByteBuffer.allocateDirect(8 * 4)
    .order(ByteOrder.nativeOrder())
    .asFloatBuffer()
    .apply {
      put(floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f))
      position(0)
    }

  override fun configure(inputWidth: Int, inputHeight: Int): Size {
    return Size(inputWidth, inputHeight)
  }

  override fun drawFrame(inputTexId: Int, presentationTimeUs: Long) {
    ensureProgram()
    val ms = presentationTimeUs / 1000L
    val blend = mix.blends.firstOrNull { ms >= it.startMs && ms < it.startMs + it.durationMs }
    val t = if (blend == null || blend.durationMs <= 0L) {
      0f
    } else {
      ((ms - blend.startMs).toFloat() / blend.durationMs.toFloat()).coerceIn(0f, 1f)
    }
    val draw = if (blend == null) BlendDraw() else resolveBlend(blend, t)
    val nextBlend = if (blend == null) {
      mix.blends.firstOrNull { ms < it.startMs && ms >= it.startMs - 400L }
    } else {
      null
    }
    val sampleMs = blend?.let { ms } ?: nextBlend?.startMs
    val incomingTex = if (sampleMs != null && mix.sourcePath.isNotEmpty()) {
      incoming.texture(mix.sourcePath, mix.incomingSourceUs(sampleMs))
    } else {
      0
    }
    val split = incomingTex != 0
    val mode = if (blend != null && (mix.sourcePath.isEmpty() || split)) draw.mode else MODE_COPY
    val key = "${blend?.startMs ?: -1}:$mode:${ms / 250}:$split"
    if (drawLogs < 24 || key != lastDrawKey) {
      Log.i(
        "NativeVideoEngine",
        "blendShader tUs=$presentationTimeUs ms=$ms mode=$mode " +
          "packed=${blend != null && mix.sourcePath.isEmpty()} split=$split t=$t " +
          "effect=${blend?.effect ?: "-"} kind=${blend?.kind ?: "-"} " +
          "windows=${mix.blends.joinToString { "${it.startMs}+${it.durationMs}" }}",
      )
      drawLogs++
      lastDrawKey = key
    }
    GLES20.glUseProgram(program)
    GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
    GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, inputTexId)
    uniform1i("uTex", 0)
    if (split) {
      GLES20.glActiveTexture(GLES20.GL_TEXTURE1)
      GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, incomingTex)
      uniform1i("uIncoming", 1)
    }
    uniform1f("uPacked", if (blend != null && mix.sourcePath.isEmpty()) 1f else 0f)
    uniform1f("uSplit", if (split) 1f else 0f)
    uniform1i("uMode", mode)
    uniform1f("uT", draw.t)
    uniform1i("uEdge", draw.edge)
    uniform1f("uAlphaA", draw.alphaA)
    uniform1f("uAlphaB", draw.alphaB)
    uniform1f("uScaleA", draw.scaleA)
    uniform1f("uScaleB", draw.scaleB)
    uniform1f("uRotA", draw.rotA)
    uniform1f("uRotB", draw.rotB)
    uniform2f("uTransA", draw.txA, draw.tyA)
    uniform2f("uTransB", draw.txB, draw.tyB)
    uniform1f("uBlurA", draw.blurA)
    uniform1f("uBlurB", draw.blurB)
    uniform1f("uZoomA", if (draw.zoomA) 1f else 0f)
    uniform1f("uZoomB", if (draw.zoomB) 1f else 0f)
    uniform1f("uWipeA", draw.wipeA)
    uniform1f("uWipeB", draw.wipeB)
    uniform1i("uWipeEdgeA", draw.wipeEdgeA)
    uniform1i("uWipeEdgeB", draw.wipeEdgeB)
    uniform1f("uBright", draw.bright)
    uniform1f("uWhite", if (draw.white) 1f else 0f)
    uniform1f("uRipple", draw.ripple)
    if (blend == null) {
      drawnBlendStart = -1L
      drawnSplit = false
    } else if (blend.startMs != drawnBlendStart) {
      drawnBlendStart = blend.startMs
      drawnSplit = split
      Log.i(
        "NativeVideoEngine",
        "blendDraw enter ms=$ms window=${blend.startMs}+${blend.durationMs} " +
          "split=$split mode=$mode effect=${blend.effect}",
      )
    } else if (split && !drawnSplit) {
      drawnSplit = true
      Log.i(
        "NativeVideoEngine",
        "blendDraw incoming ms=$ms window=${blend.startMs}+${blend.durationMs}",
      )
    }
    uniform1f("uAOnTop", if (draw.aOnTop) 1f else 0f)
    uniform1f("uCircleIncoming", if (draw.circleIncoming) 1f else 0f)
    uniform1f("uCols", draw.cols)
    uniform1f("uRows", draw.rows)
    uniform1f("uGap", draw.gap)
    uniform1f("uStagger", draw.stagger)
    uniform1f("uRotYFrom", draw.rotYFrom)
    uniform1f("uRotYTo", draw.rotYTo)
    uniform1f("uHasFlip", if (draw.hasFlip) 1f else 0f)
    uniform1f("uFlipFront", draw.flipFront)
    uniform1i("uEase", draw.ease)
    uniform1f("uReverse", if (draw.reverse) 1f else 0f)
    uniform1f("uScaleFrom", draw.scaleFrom)
    uniform1f("uScaleTo", draw.scaleTo)
    uniform2f("uOffA", draw.offAx, draw.offAy)
    uniform2f("uOffB", draw.offBx, draw.offBy)
    quad.position(0)
    GLES20.glEnableVertexAttribArray(position)
    GLES20.glVertexAttribPointer(position, 2, GLES20.GL_FLOAT, false, 0, quad)
    GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
    GLES20.glDisableVertexAttribArray(position)
    GlUtil.checkGlError()
    mix.onDrawnMs?.invoke(ms)
  }

  override fun release() {
    incoming.release()
    super.release()
    if (program != 0) {
      GLES20.glDeleteProgram(program)
      program = 0
    }
  }

  private fun ensureProgram() {
    if (program != 0) return
    val vertex = compile(GLES20.GL_VERTEX_SHADER, VERTEX)
    val fragment = compile(GLES20.GL_FRAGMENT_SHADER, FRAGMENT)
    val linked = GLES20.glCreateProgram()
    GLES20.glAttachShader(linked, vertex)
    GLES20.glAttachShader(linked, fragment)
    GLES20.glLinkProgram(linked)
    val status = IntArray(1)
    GLES20.glGetProgramiv(linked, GLES20.GL_LINK_STATUS, status, 0)
    if (status[0] != GLES20.GL_TRUE) {
      val log = GLES20.glGetProgramInfoLog(linked)
      throw VideoFrameProcessingException("transition shader link: $log")
    }
    GLES20.glDeleteShader(vertex)
    GLES20.glDeleteShader(fragment)
    program = linked
    position = GLES20.glGetAttribLocation(program, "aFramePosition")
    Log.i("NativeVideoEngine", "blendShader linked program=$program")
  }

  private fun compile(type: Int, source: String): Int {
    val shader = GLES20.glCreateShader(type)
    GLES20.glShaderSource(shader, source)
    GLES20.glCompileShader(shader)
    val status = IntArray(1)
    GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, status, 0)
    if (status[0] != GLES20.GL_TRUE) {
      val log = GLES20.glGetShaderInfoLog(shader)
      throw VideoFrameProcessingException("transition shader compile: $log")
    }
    return shader
  }

  private fun loc(name: String): Int = GLES20.glGetUniformLocation(program, name)

  private fun uniform1f(name: String, value: Float) {
    GLES20.glUniform1f(loc(name), value)
  }

  private fun uniform1i(name: String, value: Int) {
    GLES20.glUniform1i(loc(name), value)
  }

  private fun uniform2f(name: String, x: Float, y: Float) {
    GLES20.glUniform2f(loc(name), x, y)
  }

  companion object {
    const val MODE_COPY = 0
    const val MODE_POSE = 1
    const val MODE_WIPE = 2
    const val MODE_CIRCLE = 3
    const val MODE_SLIDE = 4
    const val MODE_DIP = 5
    const val MODE_RIPPLE = 6
    const val MODE_CELLS = 7
    const val MODE_DOORWAY = 8
    const val MODE_PUZZLE = 9

    const val VERTEX = """
      attribute vec4 aFramePosition;
      varying vec2 vTex;
      void main() {
        gl_Position = aFramePosition;
        vTex = (aFramePosition.xy + 1.0) * 0.5;
      }
    """

    const val FRAGMENT = """
      precision mediump float;
      varying vec2 vTex;
      uniform sampler2D uTex;
      uniform sampler2D uIncoming;
      uniform float uPacked;
      uniform float uSplit;
      uniform int uMode;
      uniform float uT;
      uniform int uEdge;
      uniform float uAlphaA;
      uniform float uAlphaB;
      uniform float uScaleA;
      uniform float uScaleB;
      uniform float uRotA;
      uniform float uRotB;
      uniform vec2 uTransA;
      uniform vec2 uTransB;
      uniform float uBlurA;
      uniform float uBlurB;
      uniform float uZoomA;
      uniform float uZoomB;
      uniform float uWipeA;
      uniform float uWipeB;
      uniform int uWipeEdgeA;
      uniform int uWipeEdgeB;
      uniform float uBright;
      uniform float uWhite;
      uniform float uRipple;
      uniform float uAOnTop;
      uniform float uCircleIncoming;
      uniform float uCols;
      uniform float uRows;
      uniform float uGap;
      uniform float uStagger;
      uniform float uRotYFrom;
      uniform float uRotYTo;
      uniform float uHasFlip;
      uniform float uFlipFront;
      uniform int uEase;
      uniform float uReverse;
      uniform float uScaleFrom;
      uniform float uScaleTo;
      uniform vec2 uOffA;
      uniform vec2 uOffB;

      vec4 sampleRaw(vec2 uv) {
        if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) return vec4(0.0);
        return texture2D(uTex, uv);
      }

      vec4 sampleIncoming(vec2 uv) {
        if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) return vec4(0.0);
        return texture2D(uIncoming, vec2(uv.x, 1.0 - uv.y));
      }

      vec4 take(vec2 uv, float side) {
        if (uPacked >= 0.5) return sampleRaw(vec2(uv.x * 0.5 + side * 0.5, uv.y));
        if (uSplit >= 0.5 && side > 0.5) return sampleIncoming(uv);
        return sampleRaw(uv);
      }

      vec4 blurred(vec2 uv, float side, float radius, float zoom) {
        if (radius < 0.35) return take(uv, side);
        vec4 acc = vec4(0.0);
        float wsum = 0.0;
        for (int i = 0; i < 5; i++) {
          float o = float(i - 2) * radius * 0.0035;
          float w = 1.0 - abs(float(i - 2)) * 0.18;
          if (zoom > 0.5) {
            vec2 toward = (uv - vec2(0.5)) * o;
            acc += take(uv + toward, side) * w;
            wsum += w;
          } else {
            acc += take(uv + vec2(o, 0.0), side) * w;
            acc += take(uv + vec2(0.0, o), side) * w;
            wsum += w * 2.0;
          }
        }
        return acc / max(wsum, 0.001);
      }

      vec2 poseUv(vec2 uv, float scale, float rot, vec2 trans) {
        vec2 c = uv - 0.5;
        c -= vec2(trans.x, -trans.y);
        float cs = cos(rot);
        float sn = sin(rot);
        c = vec2(cs * c.x + sn * c.y, -sn * c.x + cs * c.y);
        c /= max(scale, 0.001);
        return c + 0.5;
      }

      float wipeKeep(vec2 uv, float wipe, int edge) {
        if (wipe <= 0.001) return 1.0;
        if (edge == 1) return uv.x < 1.0 - wipe ? 1.0 : 0.0;
        if (edge == 2) return uv.y < 1.0 - wipe ? 1.0 : 0.0;
        if (edge == 3) return uv.y > wipe ? 1.0 : 0.0;
        return uv.x > wipe ? 1.0 : 0.0;
      }

      vec4 posed(vec2 uv, float side, float alpha, float scale, float rot, vec2 trans, float blur, float zoom, float wipe, int edge) {
        vec2 p = poseUv(uv, scale, rot, trans);
        vec4 color = blurred(p, side, blur, zoom);
        color.a *= alpha * wipeKeep(uv, wipe, edge);
        color.rgb *= color.a;
        return color;
      }

      vec4 over(vec4 fg, vec4 bg) {
        return vec4(fg.rgb + bg.rgb * (1.0 - fg.a), 1.0);
      }

      float ease(float u) {
        float t = clamp(u, 0.0, 1.0);
        if (uEase == 1) return 1.0 - pow(1.0 - t, 3.0);
        if (uEase == 2) return t * t * t;
        if (uEase == 3) {
          if (t < 0.5) return 4.0 * t * t * t;
          float v = -2.0 * t + 2.0;
          return 1.0 - (v * v * v) / 2.0;
        }
        return t;
      }

      void main() {
        vec2 uv = vTex;
        if (uMode == 0) {
          gl_FragColor = sampleRaw(uv);
          return;
        }
        vec4 a = posed(uv - uOffA, 0.0, uAlphaA, uScaleA, uRotA, uTransA, uBlurA, uZoomA, uWipeA, uWipeEdgeA);
        vec4 b = posed(uv - uOffB, 1.0, uAlphaB, uScaleB, uRotB, uTransB, uBlurB, uZoomB, uWipeB, uWipeEdgeB);
        vec4 color;
        if (uMode == 2) {
          bool showB = false;
          if (uEdge == 1) showB = uv.x < uT;
          else if (uEdge == 2) showB = uv.y > 1.0 - uT;
          else if (uEdge == 3) showB = uv.y < uT;
          else showB = uv.x > 1.0 - uT;
          color = showB ? take(uv, 1.0) : take(uv, 0.0);
          color.a = 1.0;
        } else if (uMode == 3) {
          float r = distance(uv, vec2(0.5)) / 0.70710678;
          float radius = uCircleIncoming > 0.5 ? uT : 1.0 - uT;
          bool fgIn = uCircleIncoming > 0.5;
          color = r < radius ? (fgIn ? take(uv, 1.0) : take(uv, 0.0)) : (fgIn ? take(uv, 0.0) : take(uv, 1.0));
          color.a = 1.0;
        } else if (uMode == 5) {
          float amount = uT < 0.5 ? uT * 2.0 : (1.0 - uT) * 2.0;
          vec4 base = uT < 0.5 ? take(uv, 0.0) : take(uv, 1.0);
          vec3 veil = uWhite > 0.5 ? vec3(1.0) : vec3(0.0);
          color = vec4(mix(base.rgb, veil, amount), 1.0);
        } else if (uMode == 6) {
          vec2 p = uv - 0.5;
          p.x *= 0.5625;
          float rad = length(p);
          float front = uRipple * length(vec2(0.5625, 1.0)) * 0.62;
          float ring = 0.16;
          float env = sin(uRipple * 3.14159265);
          float mag = 0.0;
          if (rad > 0.01) {
            for (int k = 0; k < 3; k++) {
              float crest = front - float(k) * ring * 0.72;
              float dist = rad - crest;
              float sigma = max(ring * 0.42, 0.01);
              float band = exp(-(dist * dist) / (sigma * sigma));
              float wave = sin(dist / max(ring, 0.01) * 6.2831853);
              mag += wave * band * env * (k == 0 ? 1.0 : 0.45);
            }
          }
          mag = clamp(mag, -1.0, 1.0);
          vec2 dir = rad > 0.01 ? p / rad : vec2(0.0);
          vec2 shift = vec2(dir.x / 0.5625, dir.y) * mag * 0.08;
          float mixIn = 1.0 - smoothstep(front - ring * 0.9, front, rad);
          color = mix(take(uv - shift, 0.0), take(uv - shift, 1.0), mixIn);
          color.a = 1.0;
        } else if (uMode == 7) {
          float cols = max(uCols, 1.0);
          float rows = max(uRows, 1.0);
          vec2 cell = vec2(floor(uv.x * cols), floor((1.0 - uv.y) * rows));
          float index = cell.y * cols + cell.x;
          float phase = fract(index * 0.618034);
          float start = phase * clamp(uStagger, 0.0, 0.95);
          float spread = clamp(uStagger, 0.0, 0.95);
          float cellT = spread <= 0.001 ? uT : clamp((uT - start) / (1.0 - spread), 0.0, 1.0);
          cellT = ease(cellT);
          vec2 local = vec2(fract(uv.x * cols), fract(uv.y * rows));
          if (local.x < uGap || local.x > 1.0 - uGap || local.y < uGap || local.y > 1.0 - uGap) {
            color = vec4(0.0, 0.0, 0.0, 1.0);
          } else if (uHasFlip > 0.5) {
            float turns = mix(uRotYFrom, uRotYTo, cellT);
            float angle = turns * 6.2831853;
            float face = max(0.035, abs(cos(angle)));
            vec2 cuv = (local - 0.5) / face + 0.5;
            bool back = cos(angle) < 0.0;
            bool showB = uFlipFront > 0.5 ? !back : back;
            color = showB ? take(cuv, 1.0) : take(cuv, 0.0);
            color.a = 1.0;
          } else {
            color = uAOnTop > 0.5 ? over(a, b) : over(b, a);
          }
        } else if (uMode == 8) {
          float lin = clamp(uT, 0.0, 1.0);
          float doorU = lin < 0.5 ? 4.0 * lin * lin * lin : 1.0 - pow(-2.0 * lin + 2.0, 3.0) / 2.0;
          float door = 0.5 * (1.0 - doorU);
          float bScale = mix(uScaleFrom, uScaleTo, 1.0 - pow(1.0 - doorU, 3.0));
          vec4 inn = take(poseUv(uv, bScale, 0.0, vec2(0.0)), 1.0);
          if (uv.x < door || uv.x > 1.0 - door) color = take(uv, 0.0);
          else color = inn;
          color.a = 1.0;
        } else if (uMode == 9) {
          float col = floor(clamp(uv.x, 0.0, 0.999) * 3.0);
          float phase = uReverse > 0.5 ? col : (2.0 - col);
          float local = clamp((uT - phase / 3.0) * 3.0, 0.0, 1.0);
          float eased = 1.0 - pow(1.0 - local, 3.0);
          float shift = 1.0 - eased;
          vec2 suv = uv;
          float dir = uReverse > 0.5 ? 1.0 : -1.0;
          if (col > 0.5 && col < 1.5) suv.y -= dir * shift;
          else suv.x -= dir * shift / 3.0;
          bool landed = local > 0.001 && suv.x >= 0.0 && suv.x <= 1.0 && suv.y >= 0.0 && suv.y <= 1.0
            && abs(floor(clamp(suv.x, 0.0, 0.999) * 3.0) - col) < 0.1;
          color = landed ? take(suv, 1.0) : take(uv, 0.0);
          color.a = 1.0;
        } else {
          color = uAOnTop > 0.5 ? over(a, b) : over(b, a);
          float veil = abs(uBright);
          if (veil > 0.001) {
            vec3 tint = uBright >= 0.0 ? vec3(1.0) : vec3(0.0);
            color.rgb = mix(color.rgb, tint, clamp(veil, 0.0, 1.0));
          }
        }
        gl_FragColor = vec4(color.rgb, 1.0);
      }
    """
  }
}

private class BlendDraw(
  var mode: Int = 0,
  var t: Float = 0f,
  var edge: Int = 0,
  var alphaA: Float = 1f,
  var alphaB: Float = 1f,
  var scaleA: Float = 1f,
  var scaleB: Float = 1f,
  var rotA: Float = 0f,
  var rotB: Float = 0f,
  var txA: Float = 0f,
  var tyA: Float = 0f,
  var txB: Float = 0f,
  var tyB: Float = 0f,
  var blurA: Float = 0f,
  var blurB: Float = 0f,
  var zoomA: Boolean = false,
  var zoomB: Boolean = false,
  var wipeA: Float = 0f,
  var wipeB: Float = 0f,
  var wipeEdgeA: Int = 0,
  var wipeEdgeB: Int = 0,
  var bright: Float = 0f,
  var white: Boolean = false,
  var ripple: Float = 0f,
  var aOnTop: Boolean = false,
  var circleIncoming: Boolean = true,
  var cols: Float = 1f,
  var rows: Float = 1f,
  var gap: Float = 0f,
  var stagger: Float = 0f,
  var rotYFrom: Float = 0f,
  var rotYTo: Float = 0f,
  var hasFlip: Boolean = false,
  var flipFront: Float = 0f,
  var ease: Int = 0,
  var reverse: Boolean = false,
  var scaleFrom: Float = 0.84f,
  var scaleTo: Float = 1f,
  var offAx: Float = 0f,
  var offAy: Float = 0f,
  var offBx: Float = 0f,
  var offBy: Float = 0f,
)

private fun resolveBlend(blend: BlendWindow, t: Float): BlendDraw {
  val draw = BlendDraw(t = t, reverse = blend.reverse, scaleFrom = blend.scaleFrom, scaleTo = blend.scaleTo)
  val layers = blend.layers
  when {
    blend.kind == "doorway" -> {
      draw.mode = 8
      draw.ease = 3
    }
    blend.kind == "puzzle" -> draw.mode = 9
    layers.any { it.property == "ripple" } -> {
      draw.mode = 6
      val poses = evaluateMotionPoses(layers, t)
      draw.ripple = maxOf(poses.first.ripple, poses.second.ripple)
    }
    layers.any { it.columns > 0 || it.property == "rotationY" } -> {
      draw.mode = 7
      val grid = layers.firstOrNull { it.columns > 0 }
      val flip = layers.firstOrNull { it.property == "rotationY" }
      draw.cols = (grid?.columns ?: 1).toFloat()
      draw.rows = (grid?.rows ?: 1).toFloat()
      draw.gap = grid?.gap ?: 0f
      draw.stagger = when {
        flip != null && flip.stagger > 0f -> flip.stagger
        else -> grid?.stagger ?: 0f
      }
      draw.rotYFrom = flip?.from ?: 0f
      draw.rotYTo = flip?.to ?: 0f
      draw.hasFlip = flip != null
      draw.flipFront = if (flip?.target == "B") 1f else 0f
      draw.ease = easeId(flip?.easing ?: grid?.easing ?: "linear")
      applyPoseDraw(draw, layers, t)
    }
    layers.isNotEmpty() -> {
      draw.mode = 1
      applyPoseDraw(draw, layers, t)
    }
    else -> applyNamed(draw, blend.effect, blend.edge, t)
  }
  return draw
}

private fun applyPoseDraw(draw: BlendDraw, layers: List<MotionLayer>, t: Float) {
  val poses = evaluateMotionPoses(layers, t)
  val a = poses.first
  val b = poses.second
  draw.alphaA = a.opacity
  draw.alphaB = b.opacity
  draw.scaleA = a.scale
  draw.scaleB = b.scale
  draw.rotA = a.turns * 6.2831853f
  draw.rotB = b.turns * 6.2831853f
  draw.txA = a.tx
  draw.tyA = a.ty
  draw.txB = b.tx
  draw.tyB = b.ty
  draw.blurA = a.blur
  draw.blurB = b.blur
  draw.zoomA = a.blurMode == "zoom"
  draw.zoomB = b.blurMode == "zoom"
  draw.wipeA = a.wipe
  draw.wipeB = b.wipe
  draw.wipeEdgeA = edgeIndex(a.wipeEdge)
  draw.wipeEdgeB = edgeIndex(b.wipeEdge)
  draw.aOnTop = motionOutgoingOnTop(layers)
  val bright = if (abs(a.brightness) >= abs(b.brightness)) a.brightness else b.brightness
  if (abs(a.brightness - b.brightness) < 0.02f || abs(a.brightness) < 0.001f || abs(b.brightness) < 0.001f) {
    draw.bright = bright
  }
}

private fun applyNamed(draw: BlendDraw, effect: String, edge: String, t: Float) {
  draw.alphaA = 1f
  draw.alphaB = 1f
  when (effect) {
    "wipeleft" -> {
      draw.mode = 2
      draw.edge = 0
    }
    "wiperight" -> {
      draw.mode = 2
      draw.edge = 1
    }
    "wipeup" -> {
      draw.mode = 2
      draw.edge = 2
    }
    "wipedown" -> {
      draw.mode = 2
      draw.edge = 3
    }
    "circleclose" -> {
      draw.mode = 3
      draw.circleIncoming = false
    }
    "circleopen", "radial" -> {
      draw.mode = 3
      draw.circleIncoming = true
    }
    "slideleft", "pushleft" -> slide(draw, -t, 0f, 1f - t, 0f)
    "slideright", "pushright" -> slide(draw, t, 0f, -(1f - t), 0f)
    "slideup", "pushup" -> slide(draw, 0f, t, 0f, -(1f - t))
    "slidedown", "pushdown" -> slide(draw, 0f, -t, 0f, 1f - t)
    "coverleft" -> slide(draw, 0f, 0f, 1f - t, 0f)
    "coverright" -> slide(draw, 0f, 0f, -(1f - t), 0f)
    "coverup" -> slide(draw, 0f, 0f, 0f, -(1f - t))
    "coverdown" -> slide(draw, 0f, 0f, 0f, 1f - t)
    "fadeblack" -> {
      draw.mode = 5
      draw.white = false
    }
    "fadewhite" -> {
      draw.mode = 5
      draw.white = true
    }
    else -> {
      if (edge == "left" || edge == "right" || edge == "top" || edge == "bottom") {
        draw.mode = 2
        draw.edge = edgeIndex(edge)
      } else {
        draw.mode = 1
        draw.alphaA = 1f - t
        draw.alphaB = t
        draw.aOnTop = false
      }
    }
  }
}

private fun slide(draw: BlendDraw, ax: Float, ay: Float, bx: Float, by: Float) {
  draw.mode = 4
  draw.offAx = ax
  draw.offAy = ay
  draw.offBx = bx
  draw.offBy = by
}

private fun edgeIndex(name: String): Int {
  return when (name) {
    "right" -> 1
    "top", "up" -> 2
    "bottom", "down" -> 3
    else -> 0
  }
}

private fun easeId(name: String): Int {
  return when (name) {
    "easeOut" -> 1
    "easeIn" -> 2
    "easeInOut" -> 3
    else -> 0
  }
}

/**
 * Decodes one source time from the playing file for the frame callback.
 * The player frame is the outgoing picture. This is the incoming picture.
 */
private class IncomingFrameSource(
  private val ffmpegStills: Boolean = false,
) {
  private val worker = Executors.newSingleThreadExecutor()
  private val stills = if (ffmpegStills) FfmpegStill() else null
  @Volatile private var closed = false
  private val lock = Any()
  private var retriever: MediaMetadataRetriever? = null
  private var openPath = ""
  private var frame: Bitmap? = null
  private var frameUs = Long.MIN_VALUE
  @Volatile private var wantedUs = Long.MIN_VALUE
  private var running = false
  private var memory = emptyList<Pair<Long, Bitmap>>()
  private var memoryGen = 0
  private var texture = 0
  private var uploadedUs = Long.MIN_VALUE

  fun remember(path: String, rangesUs: List<Pair<Long, Long>>) {
    val still = stills ?: return
    val gen = synchronized(lock) {
      memoryGen += 1
      memoryGen
    }
    worker.execute {
      if (closed || gen != memoryGen) return@execute
      val next = ArrayList<Pair<Long, Bitmap>>()
      for ((startUs, endUs) in rangesUs) {
        if (closed || gen != memoryGen) {
          next.forEach { it.second.recycle() }
          return@execute
        }
        val frames = still.frames(
          path,
          startUs / 1000L,
          endUs / 1000L,
          40L,
          720,
        )
        for ((timeMs, bitmap) in frames) {
          next.add(timeMs * 1000L to bitmap)
        }
      }
      synchronized(lock) {
        if (closed || gen != memoryGen) {
          next.forEach { it.second.recycle() }
          return@synchronized
        }
        memory.forEach { it.second.recycle() }
        memory = next
        Log.i("NativeVideoEngine", "blendIncoming memory frames=${next.size}")
      }
    }
  }

  fun clearMemory() {
    synchronized(lock) {
      memoryGen += 1
      memory.forEach { it.second.recycle() }
      memory = emptyList()
    }
  }

  fun texture(path: String, timeUs: Long): Int {
    if (path.isEmpty() || !File(path).exists()) return 0
    if (stills != null) {
      synchronized(lock) {
        val cached = nearestMemory(timeUs) ?: return 0
        return upload(cached, frameUs)
      }
    }
    ensureOpen(path)
    if (kotlin.math.abs(frameUs - timeUs) > 120_000L) request(timeUs)
    synchronized(lock) {
      val bmp = frame ?: return 0
      val us = frameUs
      if (texture != 0 && uploadedUs == us) return texture
      if (texture == 0) {
        val ids = IntArray(1)
        GLES20.glGenTextures(1, ids, 0)
        texture = ids[0]
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, texture)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
      } else {
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, texture)
      }
      GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, bmp, 0)
      uploadedUs = us
      return texture
    }
  }

  fun release() {
    closed = true
    worker.shutdown()
    try {
      worker.awaitTermination(3, java.util.concurrent.TimeUnit.SECONDS)
    } catch (_: InterruptedException) {
    }
    stills?.close()
    synchronized(lock) {
      memory.forEach { it.second.recycle() }
      memory = emptyList()
      frame?.recycle()
      frame = null
      retriever?.release()
      retriever = null
    }
    if (texture != 0) {
      GLES20.glDeleteTextures(1, intArrayOf(texture), 0)
      texture = 0
    }
  }

  private fun ensureOpen(path: String) {
    if (stills != null) {
      if (openPath != path) {
        openPath = path
        frameUs = Long.MIN_VALUE
      }
      return
    }
    if (openPath == path && retriever != null) return
    synchronized(lock) {
      retriever?.release()
      val next = MediaMetadataRetriever()
      next.setDataSource(path)
      retriever = next
      openPath = path
      frameUs = Long.MIN_VALUE
      wantedUs = Long.MIN_VALUE
    }
  }

  private fun nearestMemory(timeUs: Long): Bitmap? {
    var best: Bitmap? = null
    var bestDistance = Long.MAX_VALUE
    for ((us, bitmap) in memory) {
      val distance = kotlin.math.abs(us - timeUs)
      if (distance < bestDistance) {
        bestDistance = distance
        best = bitmap
        frameUs = us
      }
    }
    return best
  }

  private fun upload(bmp: Bitmap, us: Long): Int {
    if (texture != 0 && uploadedUs == us) return texture
    if (texture == 0) {
      val ids = IntArray(1)
      GLES20.glGenTextures(1, ids, 0)
      texture = ids[0]
      GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, texture)
      GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
      GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
      GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
      GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
    } else {
      GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, texture)
    }
    GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, bmp, 0)
    uploadedUs = us
    return texture
  }

  private fun request(timeUs: Long) {
    wantedUs = timeUs
    synchronized(lock) {
      if (running) return
      running = true
    }
    Log.i("NativeVideoEngine", "blendIncoming request us=$timeUs")
    worker.execute {
      while (!closed) {
        val target = wantedUs
        val started = android.os.SystemClock.uptimeMillis()
        val bmp = try {
          if (stills != null) {
            stills.frame(openPath, target / 1000L, 720)
          } else {
            retriever?.getFrameAtTime(target, MediaMetadataRetriever.OPTION_CLOSEST)
          }
        } catch (e: RuntimeException) {
          Log.i(
            "NativeVideoEngine",
            "blendIncoming fail us=$target elapsedMs=${android.os.SystemClock.uptimeMillis() - started} " +
              "${e.javaClass.simpleName} ${e.message}",
          )
          null
        }
        val elapsed = android.os.SystemClock.uptimeMillis() - started
        Log.i(
          "NativeVideoEngine",
          "blendIncoming frame us=$target elapsedMs=$elapsed ok=${bmp != null} " +
            "${bmp?.width ?: 0}x${bmp?.height ?: 0}",
        )
        synchronized(lock) {
          if (bmp != null) {
            frame?.recycle()
            frame = bmp
            frameUs = target
          }
          if (closed || wantedUs == target) {
            running = false
            return@execute
          }
        }
      }
    }
  }
}

/**
 * Draws ffmpeg frames with the same transition shader CompositionPlayer uses.
 * The outgoing picture is the ffmpeg frame. The incoming picture is sampled
 * from the source file.
 */
internal class FfmpegTransitionPresenter(
  private val mix: TimelineMix,
) {
  private var surface: Surface? = null
  private var display = EGL14.EGL_NO_DISPLAY
  private var context = EGL14.EGL_NO_CONTEXT
  private var eglSurface = EGL14.EGL_NO_SURFACE
  private var program = 0
  private var position = 0
  private var outgoingTex = 0
  private var incoming = IncomingFrameSource(ffmpegStills = true)
  private var flip: java.nio.ByteBuffer? = null
  private var viewW = 0
  private var viewH = 0
  private var released = false
  private val quad = java.nio.ByteBuffer.allocateDirect(8 * 4)
    .order(java.nio.ByteOrder.nativeOrder())
    .asFloatBuffer()
    .apply {
      put(floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f))
      position(0)
    }

  fun setSurface(surface: Surface?) {
    this.surface = surface
  }

  fun prefetchIncoming() {
    val path = mix.sourcePath
    if (path.isEmpty() || mix.blends.isEmpty()) {
      incoming.clearMemory()
      return
    }
    val ranges = mix.blends.map { blend ->
      val endMs = (blend.startMs + blend.durationMs - 1L).coerceAtLeast(blend.startMs)
      mix.incomingSourceUs(blend.startMs) to mix.incomingSourceUs(endMs)
    }
    incoming.remember(path, ranges)
  }

  fun draw(rgba: java.nio.ByteBuffer, width: Int, height: Int, packedMs: Long) {
    if (released || width < 2 || height < 2) return
    val target = surface ?: return
    if (!ensureGl(target, width, height)) return
    uploadOutgoing(rgba, width, height)
    val blend = mix.blends.firstOrNull {
      packedMs >= it.startMs && packedMs < it.startMs + it.durationMs
    }
    val t = if (blend == null || blend.durationMs <= 0L) {
      0f
    } else {
      ((packedMs - blend.startMs).toFloat() / blend.durationMs.toFloat()).coerceIn(0f, 1f)
    }
    val draw = if (blend == null) BlendDraw() else resolveBlend(blend, t)
    val incomingTex = if (blend != null && mix.sourcePath.isNotEmpty()) {
      incoming.texture(mix.sourcePath, mix.incomingSourceUs(packedMs))
    } else {
      0
    }
    val split = incomingTex != 0
    val mode = if (blend != null && (mix.sourcePath.isEmpty() || split)) draw.mode else 0
    GLES20.glViewport(0, 0, width, height)
    GLES20.glClearColor(0f, 0f, 0f, 1f)
    GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
    GLES20.glUseProgram(program)
    GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
    GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, outgoingTex)
    uniform1i("uTex", 0)
    if (split) {
      GLES20.glActiveTexture(GLES20.GL_TEXTURE1)
      GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, incomingTex)
      uniform1i("uIncoming", 1)
    }
    uniform1f("uPacked", if (blend != null && mix.sourcePath.isEmpty()) 1f else 0f)
    uniform1f("uSplit", if (split) 1f else 0f)
    uniform1i("uMode", mode)
    uniform1f("uT", draw.t)
    uniform1i("uEdge", draw.edge)
    uniform1f("uAlphaA", draw.alphaA)
    uniform1f("uAlphaB", draw.alphaB)
    uniform1f("uScaleA", draw.scaleA)
    uniform1f("uScaleB", draw.scaleB)
    uniform1f("uRotA", draw.rotA)
    uniform1f("uRotB", draw.rotB)
    uniform2f("uTransA", draw.txA, draw.tyA)
    uniform2f("uTransB", draw.txB, draw.tyB)
    uniform1f("uBlurA", draw.blurA)
    uniform1f("uBlurB", draw.blurB)
    uniform1f("uZoomA", if (draw.zoomA) 1f else 0f)
    uniform1f("uZoomB", if (draw.zoomB) 1f else 0f)
    uniform1f("uWipeA", draw.wipeA)
    uniform1f("uWipeB", draw.wipeB)
    uniform1i("uWipeEdgeA", draw.wipeEdgeA)
    uniform1i("uWipeEdgeB", draw.wipeEdgeB)
    uniform1f("uBright", draw.bright)
    uniform1f("uWhite", if (draw.white) 1f else 0f)
    uniform1f("uRipple", draw.ripple)
    uniform1f("uAOnTop", if (draw.aOnTop) 1f else 0f)
    uniform1f("uCircleIncoming", if (draw.circleIncoming) 1f else 0f)
    uniform1f("uCols", draw.cols)
    uniform1f("uRows", draw.rows)
    uniform1f("uGap", draw.gap)
    uniform1f("uStagger", draw.stagger)
    uniform1f("uRotYFrom", draw.rotYFrom)
    uniform1f("uRotYTo", draw.rotYTo)
    uniform1f("uHasFlip", if (draw.hasFlip) 1f else 0f)
    uniform1f("uFlipFront", draw.flipFront)
    uniform1i("uEase", draw.ease)
    uniform1f("uReverse", if (draw.reverse) 1f else 0f)
    uniform1f("uScaleFrom", draw.scaleFrom)
    uniform1f("uScaleTo", draw.scaleTo)
    uniform2f("uOffA", draw.offAx, draw.offAy)
    uniform2f("uOffB", draw.offBx, draw.offBy)
    quad.position(0)
    GLES20.glEnableVertexAttribArray(position)
    GLES20.glVertexAttribPointer(position, 2, GLES20.GL_FLOAT, false, 0, quad)
    GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
    GLES20.glDisableVertexAttribArray(position)
    EGL14.eglSwapBuffers(display, eglSurface)
  }

  fun close() {
    released = true
  }

  fun releaseGl() {
    incoming.release()
    incoming = IncomingFrameSource(ffmpegStills = true)
    if (outgoingTex != 0) {
      GLES20.glDeleteTextures(1, intArrayOf(outgoingTex), 0)
      outgoingTex = 0
    }
    if (program != 0) {
      GLES20.glDeleteProgram(program)
      program = 0
    }
    if (display != EGL14.EGL_NO_DISPLAY) {
      EGL14.eglMakeCurrent(
        display,
        EGL14.EGL_NO_SURFACE,
        EGL14.EGL_NO_SURFACE,
        EGL14.EGL_NO_CONTEXT,
      )
      if (eglSurface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, eglSurface)
      if (context != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(display, context)
      EGL14.eglTerminate(display)
    }
    display = EGL14.EGL_NO_DISPLAY
    context = EGL14.EGL_NO_CONTEXT
    eglSurface = EGL14.EGL_NO_SURFACE
    surface = null
  }

  private fun ensureGl(target: Surface, width: Int, height: Int): Boolean {
    if (display != EGL14.EGL_NO_DISPLAY && program != 0) {
      GLES20.glViewport(0, 0, width, height)
      viewW = width
      viewH = height
      return true
    }
    display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
    if (display == EGL14.EGL_NO_DISPLAY) return false
    val version = IntArray(2)
    if (!EGL14.eglInitialize(display, version, 0, version, 1)) return false
    val attribs = intArrayOf(
      EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
      EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT,
      EGL14.EGL_RED_SIZE, 8,
      EGL14.EGL_GREEN_SIZE, 8,
      EGL14.EGL_BLUE_SIZE, 8,
      EGL14.EGL_ALPHA_SIZE, 8,
      EGL14.EGL_NONE,
    )
    val configs = arrayOfNulls<EGLConfig>(1)
    val count = IntArray(1)
    if (!EGL14.eglChooseConfig(display, attribs, 0, configs, 0, 1, count, 0) || count[0] == 0) {
      return false
    }
    val config = configs[0] ?: return false
    val contextAttribs = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE)
    context = EGL14.eglCreateContext(display, config, EGL14.EGL_NO_CONTEXT, contextAttribs, 0)
    eglSurface = EGL14.eglCreateWindowSurface(display, config, target, intArrayOf(EGL14.EGL_NONE), 0)
    if (context == EGL14.EGL_NO_CONTEXT || eglSurface == EGL14.EGL_NO_SURFACE) return false
    if (!EGL14.eglMakeCurrent(display, eglSurface, eglSurface, context)) return false
    val vertex = compile(GLES20.GL_VERTEX_SHADER, TransitionBlendProgram.VERTEX)
    val fragment = compile(GLES20.GL_FRAGMENT_SHADER, TransitionBlendProgram.FRAGMENT)
    val linked = GLES20.glCreateProgram()
    GLES20.glAttachShader(linked, vertex)
    GLES20.glAttachShader(linked, fragment)
    GLES20.glLinkProgram(linked)
    val status = IntArray(1)
    GLES20.glGetProgramiv(linked, GLES20.GL_LINK_STATUS, status, 0)
    GLES20.glDeleteShader(vertex)
    GLES20.glDeleteShader(fragment)
    if (status[0] != GLES20.GL_TRUE) {
      Log.e("NativeVideoEngine", "ffmpeg blend link ${GLES20.glGetProgramInfoLog(linked)}")
      return false
    }
    program = linked
    position = GLES20.glGetAttribLocation(program, "aFramePosition")
    val ids = IntArray(1)
    GLES20.glGenTextures(1, ids, 0)
    outgoingTex = ids[0]
    GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, outgoingTex)
    GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
    GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
    GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
    GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
    viewW = width
    viewH = height
    Log.i("NativeVideoEngine", "ffmpeg blend presenter ${width}x$height")
    return true
  }

  private fun uploadOutgoing(rgba: java.nio.ByteBuffer, width: Int, height: Int) {
    val row = width * 4
    val bytes = row * height
    var dst = flip
    if (dst == null || dst.capacity() < bytes) {
      dst = java.nio.ByteBuffer.allocateDirect(bytes)
      flip = dst
    }
    dst.clear()
    val src = rgba.duplicate()
    for (y in 0 until height) {
      val start = (height - 1 - y) * row
      src.position(start)
      src.limit(start + row)
      dst.put(src)
    }
    dst.position(0)
    GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, outgoingTex)
    GLES20.glPixelStorei(GLES20.GL_UNPACK_ALIGNMENT, 1)
    GLES20.glTexImage2D(
      GLES20.GL_TEXTURE_2D,
      0,
      GLES20.GL_RGBA,
      width,
      height,
      0,
      GLES20.GL_RGBA,
      GLES20.GL_UNSIGNED_BYTE,
      dst,
    )
  }

  private fun compile(type: Int, source: String): Int {
    val shader = GLES20.glCreateShader(type)
    GLES20.glShaderSource(shader, source)
    GLES20.glCompileShader(shader)
    return shader
  }

  private fun loc(name: String): Int = GLES20.glGetUniformLocation(program, name)

  private fun uniform1f(name: String, value: Float) {
    GLES20.glUniform1f(loc(name), value)
  }

  private fun uniform1i(name: String, value: Int) {
    GLES20.glUniform1i(loc(name), value)
  }

  private fun uniform2f(name: String, x: Float, y: Float) {
    GLES20.glUniform2f(loc(name), x, y)
  }
}

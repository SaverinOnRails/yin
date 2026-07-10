// https://gist.github.com/kajott/d1b29c613be30893c855621edd1f212e
#define DECLARE_YUV2RGB_MATRIX_GLSL                                            \
  "const mat4 yuv2rgb = mat4(\n"                                               \
  "    vec4(  1.1644,  1.1644,  1.1644,  0.0000 ),\n"                          \
  "    vec4(  0.0000, -0.2132,  2.1124,  0.0000 ),\n"                          \
  "    vec4(  1.7927, -0.5329,  0.0000,  0.0000 ),\n"                          \
  "    vec4( -0.9729,  0.3015, -1.1334,  1.0000 ));"

const char *vertexShaderSourceMain = R"(
      #version 330 core
      layout(location = 0) in vec3 aPos;
      layout(location = 1) in vec2 aTexCoord;

      uniform vec2 uTexCoordScale;

      out vec2 vTexCoord;

      void main()
      {
          gl_Position = vec4(aPos, 1.0);
          vTexCoord = aTexCoord * uTexCoordScale;
      }
      )";

const char *fragmentShaderSourceMain =
    R"(#version 130

      in vec2 vTexCoord;

      uniform sampler2D uTexY;
      uniform sampler2D uTexC;

      )" DECLARE_YUV2RGB_MATRIX_GLSL
    R"(

      out vec4 oColor;

      void main()
      {
          oColor = yuv2rgb * vec4(
              texture(uTexY, vTexCoord).x,
              texture(uTexC, vTexCoord).xy,
              1.0
          );
      }
      )";

const char *boxTransitionFragmentShaderSource = R"(
    #version 130
    in vec2 vTexCoord;

    uniform sampler2D uTexY_from;
    uniform sampler2D uTexC_from;
    uniform sampler2D uTexY_to;
    uniform sampler2D uTexC_to;

    uniform float progress;
    uniform int rectIn = 1;
    uniform int location = 0;
)" DECLARE_YUV2RGB_MATRIX_GLSL R"(
    out vec4 oColor;

    vec4 getFromColor(vec2 uv) {
        return yuv2rgb * vec4(
            texture(uTexY_from, uv).x,
            texture(uTexC_from, uv).xy,
            1.0
        );
    }

    vec4 getToColor(vec2 uv) {
        return yuv2rgb * vec4(
            texture(uTexY_to, uv).x,
            texture(uTexC_to, uv).xy,
            1.0
        );
    }

    vec4 transition(vec2 uv) {
        float p = rectIn == 1 ? 1.0 - progress : progress;
        float x1, y1, x2, y2;
        if (location == 0) {
            x1 = y1 = 0.5 * (1.0 - p);
            x2 = y2 = 1.0 - x1;
        } else {
            x1 = (location == 1 || location == 2) ? 0.0 : 1.0 - p;
            y1 = (location == 1 || location == 3) ? 1.0 - p : 0.0;
            x2 = (location == 1 || location == 2) ? p : 1.0;
            y2 = (location == 1 || location == 3) ? 1.0 : p;
        }
        float in_rect = step(x1, uv.x) * step(uv.x, x2) * step(y1, uv.y) * step(uv.y, y2);
        in_rect = rectIn == 1 ? 1.0 - in_rect : in_rect;
        return mix(getFromColor(uv), getToColor(uv), in_rect);
    }

    void main() {
        oColor = transition(vTexCoord);
    }
)";

const char *lostSignalTransitionFragmentShaderSource = R"( 
// Author: mernking gitlab: Godswork
// License: MIT
    #version 130
    in vec2 vTexCoord;
    uniform sampler2D uTexY_from;
    uniform sampler2D uTexC_from;
    uniform sampler2D uTexY_to;
    uniform sampler2D uTexC_to;
    uniform float progress;
    out vec4 oColor;
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}
)" DECLARE_YUV2RGB_MATRIX_GLSL R"( 
    vec4 getFromColor(vec2 uv) {
        return yuv2rgb * vec4(
            texture(uTexY_from, uv).x,
            texture(uTexC_from, uv).xy,
            1.0
        );
    }

    vec4 getToColor(vec2 uv) {
        return yuv2rgb * vec4(
            texture(uTexY_to, uv).x,
            texture(uTexC_to, uv).xy,
            1.0
        );
    }
vec4 transition(vec2 uv) {

    float p = progress;
    float strength = sin(p * 3.14159265);

    vec2 tv = uv;

    vec4 fromColor = getFromColor(tv);
    vec4 toColor   = getToColor(tv);

    vec4 color = mix(fromColor, toColor, p);

    // horizontal tracking lines (key effect)
    float lineY = floor(tv.y * 120.0);

    float noise = hash(vec2(lineY, p * 20.0));

    float line = step(0.92, noise);

    // make lines drift during transition
    float drift =
        sin(tv.y * 30.0 + p * 10.0)
        * 0.02
        * strength;

    vec4 shiftedFrom = getFromColor(tv + vec2(drift, 0.0));
    vec4 shiftedTo   = getToColor(tv + vec2(drift, 0.0));

    vec4 lineColor = mix(shiftedFrom, shiftedTo, p);

    // apply tearing only on selected scanlines
    color = mix(color, lineColor, line * strength);

    // mild scanline darkening (CRT feel)
    float scan =
        sin(tv.y * 900.0) * 0.03;

    color.rgb -= scan * strength;

    return color;
}
    void main() {
        oColor = transition(vTexCoord);
    }
    )";

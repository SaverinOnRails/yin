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
    // Author: lql
    // License: MIT
    uniform int rectIn; // =1
    // center:0, left_top:1, left_bottom:2, right_top:3, right_bottom:4
    uniform int location; // =0

    vec4 transition(vec2 uv) {
        float p = rectIn == 1 ? 1.0 - progress : progress;
        float x1, y1, x2, y2;

        // Determine rectangle coordinates based on location
        if (location == 0) {
            x1 = y1 = 0.5 * (1.0 - p);
            x2 = y2 = 1.0 - x1;
        } else {
            // Calculate the x and y coordinates based on the location
            x1 = (location == 1 || location == 2) ? 0.0 : 1.0 - p;
            y1 = (location == 1 || location == 3) ? 1.0 - p : 0.0;
            x2 = (location == 1 || location == 2) ? p : 1.0;
            y2 = (location == 1 || location == 3) ? 1.0 : p;
        }

        // Determine if the point is inside the rectangle
        float in_rect = step(x1, uv.x) * step(uv.x, x2) * step(y1, uv.y) * step(uv.y, y2);
        in_rect = rectIn == 1 ? 1.0 - in_rect : in_rect;

        // Mix colors based on the in_rect value
        return mix(getFromColor(uv), getToColor(uv), in_rect);
    }
  )";

// Author: bread
// License: MIT
#version 130
@UNIFORMS
uniform float progress;

@YUV2RGB
@FUNCTIONS
  vec2 zoom(vec2 uv, float amount) {
    return 0.5 + ((uv - 0.5) * (1.0 - amount));
  }

  vec4 transition(vec2 uv) {
    float zoomFrom = smoothstep(0.0, 1.0, progress * 2.0);
    float zoomTo = smoothstep(0.0, 1.0, (1.0 - progress) * 2.0);
    float crossfade = smoothstep(0.4, 0.6, progress);
    return mix(
      getFromColor(zoom(uv, zoomFrom)),
      getToColor(zoom(uv, zoomTo)),
      crossfade
    );
  }

  @MAIN

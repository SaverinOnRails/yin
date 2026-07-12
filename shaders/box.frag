// Author: lql
// License: MIT

uniform int rectIn = 1;
uniform int location = 0;


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

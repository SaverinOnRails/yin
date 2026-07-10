#version 130
in vec2 vTexCoord;

uniform sampler2D uTexY;
uniform sampler2D uTexC;
@YUV2RGB
out vec4 oColor;

void main()
{
  oColor = yuv2rgb * vec4(
    texture(uTexY, vTexCoord).x,
    texture(uTexC, vTexCoord).xy,
    1.0
  );
}

// Glass for a rounded pane, applied as a backdrop filter. The engine binds the
// backdrop (already blurred by the inner filter) as uTexture and its size as
// uSize; coordinates are physical pixels of the render target, so the pane's
// own rect comes in as a uniform.
//
// Inside a bevel band along the edge the surface curves away: the backdrop is
// refracted inward (more at the rim, with a hint of dispersion), the grazing
// part mirrors what lies beside the pane, and light catches the rim, bright
// toward the top left and softer on the far side. The flat face shows the
// backdrop with more saturation and a thin tint.
#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
uniform vec4 uRect;       // left, top, width, height
uniform float uRadius;    // corner radius
uniform float uEdge;      // bevel width
uniform float uRefract;   // how far the rim pulls the backdrop in
uniform float uTint;      // white mixed into the face
uniform float uShade;     // night tint for the dark theme
uniform float uSaturation;
uniform float uLight;     // rim light strength
uniform float uAppear;    // 0: the plain backdrop, 1: glass

// The pane must never sit in a layer that fades: there the engine renders it
// offscreen and both the coordinates and the backdrop change. It fades itself
// instead: the output's alpha is uAppear, and the backdrop filter lays it over
// the unfiltered backdrop (srcOver). The blur stays at full strength the whole
// time; a growing blur would spend its middle range on full-resolution passes.

uniform sampler2D uTexture;

out vec4 fragColor;

const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);

float sdRoundRect(vec2 p, vec2 b, float r) {
  vec2 q = abs(p) - b + vec2(r);
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// Only the pane's own rect holds the blurred backdrop, so every sample stays
// inside it (an edge sample beyond it would read unfiltered pixels).
vec3 backdrop(vec2 px) {
  px = clamp(px, uRect.xy + vec2(1.5), uRect.xy + uRect.zw - vec2(1.5));
  vec2 uv = clamp(px, vec2(0.5), uSize - vec2(0.5)) / uSize;
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  return texture(uTexture, uv).rgb;
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 halfSize = uRect.zw * 0.5;
  vec2 p = frag - (uRect.xy + halfSize);
  float r = min(uRadius, min(halfSize.x, halfSize.y));
  float sd = sdRoundRect(p, halfSize, r);
  if (sd > 0.0 || uAppear <= 0.001) {
    fragColor = vec4(0.0);
    return;
  }

  // The outward direction of the nearest edge.
  vec2 e = vec2(0.75, 0.0);
  vec2 grad = vec2(
    sdRoundRect(p + e.xy, halfSize, r) - sdRoundRect(p - e.xy, halfSize, r),
    sdRoundRect(p + e.yx, halfSize, r) - sdRoundRect(p - e.yx, halfSize, r));
  grad /= max(length(grad), 1e-4);

  // 1 at the rim, 0 where the bevel meets the flat face; squared, so the
  // surface steepens toward the rim like a convex edge.
  float bevel = 1.0 - clamp(-sd / max(uEdge, 1.0), 0.0, 1.0);
  float curve = bevel * bevel;

  vec2 bend = -grad * uRefract * curve;
  vec3 refracted = vec3(
    backdrop(frag + bend * 1.08).r,
    backdrop(frag + bend).g,
    backdrop(frag + bend * 0.92).b);
  vec3 mirrored = backdrop(frag + grad * uEdge * 0.7 * bevel);
  vec3 col = mix(refracted, mirrored, 0.3 * curve);

  float l = dot(col, LUMA);
  col = mix(vec3(l), col, uSaturation);
  col = mix(col, vec3(1.0), uTint);
  col = mix(col, vec3(0.025, 0.035, 0.075), uShade);

  vec2 toLight = normalize(vec2(-0.55, -0.83));
  float facing = dot(grad, toLight);
  float key = max(facing, 0.0);
  float back = max(-facing, 0.0) * 0.5;
  float band = bevel * bevel * bevel;
  float line = smoothstep(2.2, 0.0, -sd);
  float light = (key + back) * (band * 0.5 + line * 0.85) * uLight;
  // Lift dark colors more than light ones, so the rim reads on both themes.
  float lift = 0.35 + 0.65 * clamp(1.6 - 1.8 * dot(col, LUMA), 0.0, 1.0);
  col += vec3(light * lift);

  // Light falling across the face from the top.
  float down = clamp((frag.y - uRect.y) / max(uRect.w, 1.0), 0.0, 1.0);
  col += vec3((1.0 - down) * (1.0 - down) * 0.045 * uLight);

  // Premultiplied: srcOver onto the unfiltered backdrop fades the glass in.
  fragColor = vec4(clamp(col, 0.0, 1.0) * uAppear, uAppear);
}

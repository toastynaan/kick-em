shader_type spatial;
// Additive camera-facing quad, depth tested (dazed stars, dust-free FX).
// OWNER: agent F.
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;
#include "res://shaders/fx_billboard.gdshaderinc"

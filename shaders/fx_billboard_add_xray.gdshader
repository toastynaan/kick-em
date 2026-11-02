shader_type spatial;
// Additive camera-facing quad drawn over geometry (limb-glow tells and impact
// flashes must read even behind the fighter's own body). OWNER: agent F.
render_mode unshaded, blend_add, depth_draw_never, depth_test_disabled, cull_disabled, shadows_disabled, fog_disabled;
#include "res://shaders/fx_billboard.gdshaderinc"

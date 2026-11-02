shader_type spatial;
// Stencil mask (ScreenFX): a next_pass on the materials that keep full colour
// during the Focus tint (the player, glowing enemy limbs). Draws nothing
// visible; writes stencil 1 where the surface is visible (depth tested), so
// focus_tint.gdshader leaves those pixels alone. render_priority -100 (before
// the tint). OWNER: agent F.
render_mode unshaded, blend_mix, depth_draw_never, cull_back, shadows_disabled, fog_disabled;
stencil_mode write, compare_always, 1;

void fragment() {
	ALBEDO = vec3(0.0);
	ALPHA = 0.0;
}

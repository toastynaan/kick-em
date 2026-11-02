shader_type spatial;
// Fighter body-part material. Each mesh part rides one bone, so MODEL space is
// bone-local and blood points painted here follow animation and ragdoll.
// OWNER: agent F (blood). CONTRACT: keep the uniform names below.
//
// Blood: wet, darker at the centre of each stain, with noisy edges; as
// blood_level (lost HP) rises, stains spread and grimy blotches cover more of
// the body, so an enemy's blood shows how hurt it is. A soft view-dependent rim
// keeps fighters readable against the floor. BloodFX writes blood_points,
// blood_count, blood_color, blood_level and flash; GameMode/Fighter tween dissolve.
// Round 5 (BloodFX): jitter, a world-space offset that shakes the victim's mesh
// 2-4 cm during the hitstop freeze (Feel Reference: Contact frame, item 2).
// Purely visual: physics never sees it.
// Upgrade 2 (BloodFX): glow (limb-glow tells, charge), highlight (aimed body
// zone) and view_fade (screen-door fade of a fighter that blocks the camera).

render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec3 albedo : source_color = vec3(0.8);
uniform float roughness : hint_range(0.0, 1.0) = 0.75;
// xyz = point in this mesh's local space, w = radius (m). Up to 16 per part.
uniform vec4 blood_points[16];
uniform int blood_count = 0;
uniform vec3 blood_color : source_color = vec3(0.32, 0.0, 0.01);
// 0..1 overall blood level (lost HP); darkens and spreads the stains.
uniform float blood_level : hint_range(0.0, 1.0) = 0.0;
// 0..1 white hit flash.
uniform float flash : hint_range(0.0, 1.0) = 0.0;
// 0..1 dithered dissolve for corpse fade-out.
uniform float dissolve : hint_range(0.0, 1.0) = 0.0;
// Added by F: rim light (light-driven RIM plus a faint fresnel glow).
uniform float rim_strength : hint_range(0.0, 1.0) = 0.3;
uniform vec3 rim_color : source_color = vec3(0.75, 0.82, 1.0);
uniform float rim_glow : hint_range(0.0, 1.0) = 0.1;
// Upgrade 2. Emissive glow on this part (BloodFX.limb_glow).
uniform vec3 glow_color : source_color = vec3(1.0);
uniform float glow : hint_range(0.0, 8.0) = 0.0;
// Aimed-zone highlight: tint plus a bright fresnel edge (BloodFX zone highlight).
uniform vec3 highlight_color : source_color = vec3(1.0, 0.82, 0.35);
uniform float highlight : hint_range(0.0, 1.0) = 0.0;
// 0..1 screen-door fade when the fighter blocks the camera (BloodFX.set_fighter_fade).
uniform float view_fade : hint_range(0.0, 1.0) = 0.0;
// How far lost-HP grime spreads over the body (BloodFX sets more on the player,
// whose back faces the camera, so damage taken shows from behind).
uniform float blood_spread : hint_range(0.0, 3.0) = 1.0;
// Round 5: world-space mesh offset during the hitstop freeze (BloodFX).
uniform vec3 jitter = vec3(0.0);

varying vec3 model_pos;

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

// Smooth 3D value noise, 0..1.
float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = mix(hash13(i), hash13(i + vec3(1.0, 0.0, 0.0)), f.x);
	float b = mix(hash13(i + vec3(0.0, 1.0, 0.0)), hash13(i + vec3(1.0, 1.0, 0.0)), f.x);
	float c = mix(hash13(i + vec3(0.0, 0.0, 1.0)), hash13(i + vec3(1.0, 0.0, 1.0)), f.x);
	float d = mix(hash13(i + vec3(0.0, 1.0, 1.0)), hash13(i + vec3(1.0, 1.0, 1.0)), f.x);
	return mix(mix(a, b, f.y), mix(c, d, f.y), f.z);
}

void vertex() {
	model_pos = VERTEX;  // before the jitter, so stains stay put on the part
	if (jitter != vec3(0.0)) {
		VERTEX += (inverse(MODEL_MATRIX) * vec4(jitter, 0.0)).xyz;
	}
}

// 4x4 ordered dither threshold (0..1) for a screen pixel.
float bayer4(vec2 frag) {
	int x = int(mod(frag.x, 4.0));
	int y = int(mod(frag.y, 4.0));
	int i = y * 4 + x;
	float m[16] = float[16](0.0, 8.0, 2.0, 10.0, 12.0, 4.0, 14.0, 6.0,
			3.0, 11.0, 1.0, 9.0, 15.0, 7.0, 13.0, 5.0);
	return (m[i] + 0.5) / 16.0;
}

void fragment() {
	if (dissolve > 0.0 && hash13(floor(model_pos * 60.0)) < dissolve) {
		discard;
	}
	// Camera fade: the same screen-door dither as the world blocker fade
	// (WorldMaterials), opaque pipeline, no sorting. The camera caps the amount
	// so a silhouette stays. Directional shadow maps render with an
	// orthographic projection: skip the dither there so the fighter keeps a
	// solid shadow on the floor while faded.
	bool shadow_pass = PROJECTION_MATRIX[3][3] > 0.5;
	if (view_fade > 0.001 && !shadow_pass && bayer4(FRAGCOORD.xy) < view_fade) {
		discard;
	}
	// Edge breakup (fine) and damage blotches (coarse).
	float n_edge = vnoise(model_pos * 30.0) * 0.65 + vnoise(model_pos * 71.0) * 0.35;
	float n_blot = vnoise(model_pos * 11.0 + vec3(17.0, 3.0, 11.0)) * 0.8 + n_edge * 0.2;

	float b = 0.0;     // stain coverage
	float core = 0.0;  // thick centre of a stain
	float spread = 1.0 + blood_level * 0.6;
	for (int i = 0; i < 16; i++) {
		if (i >= blood_count) {
			break;
		}
		vec4 p = blood_points[i];
		float r = p.w * spread;
		float d = distance(model_pos, p.xyz);
		float dn = d + (n_edge - 0.5) * r * 0.7;
		b = max(b, 1.0 - smoothstep(r * 0.5, r, dn));
		core = max(core, 1.0 - smoothstep(0.0, r * 0.55, d));
	}
	// Lost HP: grimy blotches spread over the whole body.
	float lvl = clamp(blood_level, 0.0, 1.0);
	float glvl = clamp(blood_level * blood_spread, 0.0, 1.0);
	// Value noise sits near 0.5, so the threshold walks down from 0.78: about
	// 6% coverage at 10% lost, 25% at 50%, most of the body at 100%.
	float gt = 0.78 - glvl * 0.35;
	float grime = glvl > 0.01 ? smoothstep(gt, gt + 0.06, n_blot) : 0.0;
	b = clamp(max(b, grime * 0.7), 0.0, 1.0);

	// Wet blood: dark, darker where thick, slightly lighter at the soaked edge.
	vec3 wet = blood_color * mix(1.2, 0.5, core);
	vec3 c = mix(albedo, wet, b * 0.96);
	c *= 1.0 - lvl * 0.1;

	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	c = mix(c, highlight_color, highlight * 0.5);
	c = mix(c, glow_color, clamp(glow * 0.15, 0.0, 0.6));

	ALBEDO = mix(c, vec3(1.0), flash);
	ROUGHNESS = mix(roughness, 0.1, b);
	SPECULAR = mix(0.5, 0.8, b);
	RIM = rim_strength;
	RIM_TINT = 0.4;

	EMISSION = rim_color * fres * rim_glow + vec3(flash * 0.8)
			+ glow_color * glow * (0.6 + 0.4 * fres)
			+ highlight_color * highlight * (0.5 + fres * 2.2);
}

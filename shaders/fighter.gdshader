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
	model_pos = VERTEX;
}

void fragment() {
	if (dissolve > 0.0 && hash13(floor(model_pos * 60.0)) < dissolve) {
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
	float grime = lvl > 0.01 ? smoothstep(1.0 - lvl * 0.55, 1.08 - lvl * 0.5, n_blot) : 0.0;
	b = clamp(max(b, grime * 0.7), 0.0, 1.0);

	// Wet blood: dark, darker where thick, slightly lighter at the soaked edge.
	vec3 wet = blood_color * mix(1.2, 0.5, core);
	vec3 c = mix(albedo, wet, b * 0.96);
	c *= 1.0 - lvl * 0.1;

	ALBEDO = mix(c, vec3(1.0), flash);
	ROUGHNESS = mix(roughness, 0.1, b);
	SPECULAR = mix(0.5, 0.8, b);
	RIM = rim_strength;
	RIM_TINT = 0.4;

	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	EMISSION = rim_color * fres * rim_glow + vec3(flash * 0.8);
}

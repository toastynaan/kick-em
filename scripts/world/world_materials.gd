class_name WorldMaterials
extends RefCounted
## Procedural world materials (no textures on disk): one spatial shader with a
## pattern switch for drywall, brick, concrete, roll-door metal, asphalt with
## painted courtyard lines, and office floor tiles. Panels and their chunks
## read the pattern position from UV/UV2 (panel-local, see PanelFracture);
## static geometry reads it from the world position. Also the crack-line
## material and the procedural concrete crack decal texture.
## OWNER: agent D (world).

enum Pattern { DRYWALL, BRICK, CONCRETE, METAL, ASPHALT, TILES, GROUND, WOOD }

const SHADER_CODE := """
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform int pattern = 0;
uniform bool world_space = false;
uniform vec3 color_a : source_color = vec3(0.8);
uniform vec3 color_b : source_color = vec3(0.6);
uniform vec3 color_core : source_color = vec3(0.9);
uniform float rough = 0.85;
uniform float metal = 0.0;
// Drywall facade: panel seams every 3 m and a window per panel.
uniform bool facade = false;

varying vec3 v_p;
varying vec3 v_n;
varying float v_ext;

void vertex() {
	if (world_space) {
		v_p = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
		v_n = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
		v_ext = 1.0;
	} else {
		v_p = vec3(UV.x, UV.y, UV2.x);
		v_n = NORMAL;
		v_ext = COLOR.r;
	}
}

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1.0, 0.0)), u.x),
		mix(hash12(i + vec2(0.0, 1.0)), hash12(i + vec2(1.0, 1.0)), u.x), u.y);
}

float fbm(vec2 p) {
	float s = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		s += a * vnoise(p);
		p = p * 2.03 + vec2(17.1, 9.3);
		a *= 0.5;
	}
	return s;
}

vec2 face_uv(vec3 p, vec3 n) {
	vec3 an = abs(n);
	if (an.z >= an.x && an.z >= an.y) return p.xy;
	if (an.x >= an.y) return vec2(p.z, p.y);
	return p.xz;
}

float line_mask(float d, float w) {
	return 1.0 - smoothstep(w * 0.5, w * 0.5 + 0.01, d);
}

void fragment() {
	vec2 uv = face_uv(v_p, v_n);
	vec3 col = color_a;
	float r = rough;
	float ao = 1.0;
	float m = metal;
	float grain = fbm(uv * 6.0);
	vec2 fw = fwidth(uv);
	float blur = smoothstep(0.006, 0.03, max(fw.x, fw.y));
	float fine = mix(vnoise(uv * 60.0), 0.5, blur);
	if (v_ext < 0.5) {
		// Fracture face: raw core material.
		col = color_core * (0.75 + 0.35 * fbm(uv * 14.0 + v_p.z * 3.0));
		r = 0.95;
		m = 0.0;
		if (pattern == 0) {
			// Stud wall cross-section: gypsum skins, insulation core.
			float skin = step(0.108, abs(v_p.z));
			vec3 wool = vec3(0.86, 0.68, 0.42) * (0.7 + 0.5 * fbm(vec2(v_p.z * 40.0, (v_p.x + v_p.y) * 9.0)));
			col = mix(wool, color_core * (0.9 + 0.1 * fine), skin);
		}
	} else if (pattern == 0) {
		// Drywall: paint (+Z courtyard side uses color_a, -Z room side color_b), baseboard.
		col = v_n.z < -0.5 ? color_b : color_a;
		col *= 0.93 + 0.1 * grain + 0.04 * fine;
		if (v_p.y < -1.38 && abs(v_n.z) > 0.5) {
			col = vec3(0.16, 0.15, 0.14) * (0.9 + 0.2 * fine);
			r = 0.5;
		}
		float scuff = smoothstep(0.62, 0.8, fbm(uv * 2.3 + 4.0));
		col *= 1.0 - 0.18 * scuff * step(v_p.y, -0.2);
		if (facade && abs(v_n.z) > 0.5) {
			// Vertical seam at each 3 m panel edge.
			float seam = 1.0 - smoothstep(0.012, 0.022, 1.5 - abs(v_p.x));
			col *= 1.0 - 0.45 * seam;
			ao = 1.0 - 0.4 * seam;
			// Window: x in [-0.75, 0.75], y in [-0.15, 0.95] (1.35-2.45 m up).
			vec2 wc = vec2(v_p.x, v_p.y - 0.4);
			vec2 wh = vec2(0.75, 0.55);
			vec2 dw = abs(wc) - wh;
			float inside = step(max(dw.x, dw.y), 0.0);
			float frame_w = 0.06;
			float in_glass = step(max(dw.x + frame_w, dw.y + frame_w), 0.0) * step(0.025, abs(wc.x));
			vec3 frame_col = vec3(0.9, 0.9, 0.88);
			float g = clamp((wc.y + wh.y) / (2.0 * wh.y), 0.0, 1.0);
			vec3 glass = mix(vec3(0.06, 0.09, 0.12), vec3(0.32, 0.42, 0.52), g);
			glass += 0.12 * smoothstep(0.02, 0.0, abs(wc.x * 0.6 + wc.y - 0.15));
			col = mix(col, frame_col, inside * (1.0 - in_glass));
			col = mix(col, glass, in_glass);
			r = mix(r, 0.08, in_glass);
			m = mix(m, 0.3, in_glass);
		}
	} else if (pattern == 1) {
		// Brick: 0.3 x 0.1 m running bond with mortar joints.
		float bw = 0.3;
		float bh = 0.1;
		float row = floor((uv.y + 10.0) / bh);
		float off = mod(row, 2.0) * 0.5 * bw;
		float colid = floor((uv.x + off + 10.0) / bw);
		vec2 lp = vec2(fract((uv.x + off + 10.0) / bw) * bw, fract((uv.y + 10.0) / bh) * bh);
		float edge = min(min(lp.x, bw - lp.x), min(lp.y, bh - lp.y));
		float ew = max(fwidth(edge), 0.0015);
		float mortar = 1.0 - smoothstep(0.009 - ew, 0.009 + ew, edge);
		float h = hash12(vec2(colid, row));
		vec3 bc = mix(color_a, color_a * vec3(0.72, 0.66, 0.62), h);
		bc = mix(bc, color_a * vec3(1.15, 1.05, 0.95), step(0.9, h) * 0.6);
		bc *= 0.82 + 0.3 * fbm(uv * 22.0 + h * 10.0);
		// Filter the joints and per-brick tint as they shrink below a pixel.
		mortar = mix(mortar, 0.2, blur);
		bc = mix(bc, color_a * 0.88, blur * 0.8);
		col = mix(bc, color_b * (0.85 + 0.25 * fine), mortar);
		ao = 1.0 - 0.45 * mortar;
		r = mix(0.82, 0.95, mortar);
		float grime = smoothstep(0.55, 0.85, fbm(vec2(uv.x * 1.3, uv.y * 0.35) + 2.0));
		col *= 1.0 - 0.25 * grime;
	} else if (pattern == 2) {
		// Board-formed concrete with form lines and tie holes.
		col = color_a * (0.8 + 0.3 * grain + 0.08 * fine);
		float stain = smoothstep(0.5, 0.9, fbm(vec2(uv.x * 0.8, uv.y * 0.25) + 7.0));
		col *= 1.0 - 0.22 * stain;
		vec2 g = vec2(uv.x / 1.5, uv.y / 0.75);
		vec2 gf = abs(fract(g) - 0.5);
		float seam = max(line_mask(0.5 - gf.x, 0.012 / 1.5 * 2.0), line_mask(0.5 - gf.y, 0.012 / 0.75 * 2.0));
		seam *= 1.0 - 0.7 * blur;
		col *= 1.0 - 0.25 * seam;
		vec2 tie = fract(vec2(uv.x / 0.75, uv.y / 0.75)) - 0.5;
		float hole = (1.0 - smoothstep(0.028, 0.04, length(tie * 0.75))) * (1.0 - blur);
		col *= 1.0 - 0.6 * hole;
		ao = 1.0 - 0.5 * hole;
		r = 0.9;
	} else if (pattern == 3) {
		// Corrugated roll door.
		float rib = mix(0.5 + 0.5 * sin(uv.y * 6.2831 / 0.09), 0.5, blur);
		col = color_a * (0.75 + 0.3 * rib);
		float rust = smoothstep(0.62, 0.9, fbm(vec2(uv.x * 4.0, uv.y * 0.7) + 1.0)) * 0.55;
		col = mix(col, vec3(0.35, 0.18, 0.08), rust * 0.6);
		r = mix(0.45, 0.85, rust);
		m = mix(metal, 0.1, rust);
		ao = 0.85 + 0.15 * rib;
	} else if (pattern == 4) {
		// Asphalt with painted courtyard lines (world XZ).
		vec2 w = v_p.xz;
		vec2 fww = fwidth(w);
		float ab = smoothstep(0.004, 0.02, max(fww.x, fww.y));
		col = color_a * (0.75 + 0.35 * fbm(w * 1.7) + 0.25 * (hash12(floor(w * 90.0)) - 0.5) * (1.0 - ab));
		float oil = smoothstep(0.6, 0.85, fbm(w * 0.35 + 3.0));
		col *= 1.0 - 0.35 * oil;
		float paint = 0.0;
		vec3 pc = vec3(0.92, 0.9, 0.85);
		// Yellow boundary rectangle.
		float bx = abs(abs(w.x) - 10.0);
		float bz = abs(abs(w.y) - 10.0);
		float rect = max(line_mask(bx, 0.14) * step(abs(w.y), 10.07), line_mask(bz, 0.14) * step(abs(w.x), 10.07));
		// Centre circle and halfway line.
		float circ = line_mask(abs(length(w) - 3.0), 0.12);
		float mid = line_mask(abs(w.y), 0.1) * step(abs(w.x), 10.0) * step(0.5, fract(w.x / 2.0));
		float white = max(circ, mid);
		// Hazard stripes in front of the roll door.
		float hz = step(abs(w.x), 1.6) * step(-10.95, w.y) * step(w.y, -9.85);
		float stripe = step(0.5, fract((w.x + w.y) / 0.6));
		vec3 yel = vec3(0.95, 0.72, 0.1);
		float wear = smoothstep(0.25, 0.6, fbm(w * 4.0));
		col = mix(col, yel, rect * wear);
		col = mix(col, pc, white * wear);
		col = mix(col, mix(vec3(0.05), yel, stripe), hz * wear);
		paint = max(max(rect, white), hz) * wear;
		r = mix(0.92, 0.6, paint);
	} else if (pattern == 5) {
		// Office floor: 0.5 m linoleum tiles.
		vec2 w = v_p.xz;
		vec2 cell = floor(w / 0.5);
		float chk = mod(cell.x + cell.y, 2.0);
		col = mix(color_a, color_b, chk) * (0.9 + 0.12 * grain + 0.05 * hash12(cell));
		vec2 gl = abs(fract(w / 0.5) - 0.5);
		float grout = line_mask(0.5 - max(gl.x, gl.y), 0.012) * (1.0 - blur);
		col *= 1.0 - 0.3 * grout;
		r = 0.55;
	} else if (pattern == 7) {
		// Wood planks (crates, desks): boards along X, grain, dark gaps.
		float bh = 0.12;
		float row = floor((uv.y + 10.0) / bh);
		float h = hash12(vec2(row, 3.0));
		float grain = fbm(vec2(uv.x * 1.5 + h * 7.0, uv.y * 40.0));
		col = mix(color_a, color_b, 0.35 * h + 0.45 * grain);
		float gap = 1.0 - smoothstep(0.004, 0.009, min(fract((uv.y + 10.0) / bh) * bh, bh - fract((uv.y + 10.0) / bh) * bh));
		gap *= 1.0 - blur;
		col *= 1.0 - 0.55 * gap;
		ao = 1.0 - 0.4 * gap;
		r = 0.8;
	} else {
		// Ground outside the walls: gravel and dirt.
		vec2 w = v_p.xz;
		col = mix(color_a, color_b, fbm(w * 0.6)) * (0.75 + 0.4 * mix(hash12(floor(w * 40.0)), 0.5, blur));
		r = 0.98;
	}
	ALBEDO = col;
	ROUGHNESS = r;
	METALLIC = m;
	AO = ao;
	AO_LIGHT_AFFECT = 0.25;
}
"""

static var _shader: Shader
static var _cache: Dictionary = {}

static func shader() -> Shader:
	if _shader == null:
		_shader = Shader.new()
		_shader.code = SHADER_CODE
	return _shader

static func _make(key: String, pattern: int, world_space: bool, a: Color, b: Color, core: Color,
		rough := 0.85, metal := 0.0) -> ShaderMaterial:
	if _cache.has(key):
		return _cache[key]
	var m := ShaderMaterial.new()
	m.shader = shader()
	m.set_shader_parameter(&"pattern", pattern)
	m.set_shader_parameter(&"world_space", world_space)
	m.set_shader_parameter(&"color_a", a)
	m.set_shader_parameter(&"color_b", b)
	m.set_shader_parameter(&"color_core", core)
	m.set_shader_parameter(&"rough", rough)
	m.set_shader_parameter(&"metal", metal)
	_cache[key] = m
	return m

## Material for a Destructible panel (and its chunks) of `surface`.
## style &"rolldoor" gives the corrugated metal look.
static func panel(surface: StringName, style: StringName = &"") -> ShaderMaterial:
	if style == &"rolldoor":
		return _make("p_rolldoor", Pattern.METAL, false, Color(0.32, 0.42, 0.5), Color(0.2, 0.2, 0.2),
			Color(0.5, 0.52, 0.55), 0.45, 0.6)
	match surface:
		&"brick":
			return _make("p_brick", Pattern.BRICK, false, Color(0.56, 0.24, 0.16), Color(0.62, 0.6, 0.55),
				Color(0.72, 0.38, 0.24))
		&"concrete":
			return _make("p_concrete", Pattern.CONCRETE, false, Color(0.58, 0.57, 0.54), Color(0.5, 0.5, 0.5),
				Color(0.62, 0.61, 0.58))
		&"wood":
			if style == &"planks":
				return _make("p_planks", Pattern.WOOD, false, Color(0.64, 0.47, 0.28), Color(0.42, 0.28, 0.15),
					Color(0.78, 0.62, 0.42), 0.8)
			return _make("p_wood", Pattern.METAL, false, Color(0.55, 0.38, 0.2), Color(0.3, 0.2, 0.1),
				Color(0.75, 0.6, 0.4), 0.7, 0.0)
		_:
			if style == &"interior":
				# Inner office walls: room paint on both faces.
				return _make("p_drywall_in", Pattern.DRYWALL, false, Color(0.6, 0.71, 0.69), Color(0.6, 0.71, 0.69),
					Color(0.95, 0.94, 0.9))
			# Facade: ochre office paint on +Z, room paint on -Z, seams and windows.
			var m := _make("p_drywall", Pattern.DRYWALL, false, Color(0.9, 0.7, 0.36), Color(0.6, 0.71, 0.69),
				Color(0.95, 0.94, 0.9))
			m.set_shader_parameter(&"facade", true)
			return m

## Static concrete (outer walls, pillars, columns, stairs), world-space pattern.
static func concrete(shade := 1.0) -> ShaderMaterial:
	return _make("w_concrete_%.2f" % shade, Pattern.CONCRETE, true,
		Color(0.58, 0.57, 0.54) * shade, Color(0.5, 0.5, 0.5), Color(0.6, 0.6, 0.6))

## Door frames: dark painted steel.
static func frame() -> ShaderMaterial:
	return _make("w_frame", Pattern.CONCRETE, true, Color(0.16, 0.17, 0.18), Color(0.1, 0.1, 0.1),
		Color(0.2, 0.2, 0.2), 0.5, 0.4)

static func asphalt() -> ShaderMaterial:
	return _make("w_asphalt", Pattern.ASPHALT, true, Color(0.2, 0.2, 0.21), Color(0.1, 0.1, 0.1),
		Color(0.2, 0.2, 0.2), 0.92)

static func office_floor() -> ShaderMaterial:
	return _make("w_tiles", Pattern.TILES, true, Color(0.55, 0.52, 0.46), Color(0.42, 0.45, 0.44),
		Color(0.5, 0.5, 0.5), 0.55)

static func ground() -> ShaderMaterial:
	return _make("w_ground", Pattern.GROUND, true, Color(0.3, 0.28, 0.24), Color(0.22, 0.24, 0.18),
		Color(0.3, 0.3, 0.3), 0.98)

static func _std(key: String, color: Color, rough: float, metal := 0.0) -> StandardMaterial3D:
	if _cache.has(key):
		return _cache[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	m.metallic = metal
	_cache[key] = m
	return m

static func office_chair() -> StandardMaterial3D:
	return _std("chair", Color(0.16, 0.2, 0.32), 0.7)

static func cabinet() -> StandardMaterial3D:
	return _std("cabinet", Color(0.52, 0.55, 0.53), 0.45, 0.5)

static func drum() -> StandardMaterial3D:
	return _std("drum", Color(0.12, 0.33, 0.55), 0.5, 0.5)

## Warm emissive strip under a lamp-post head.
static func lamp_glow() -> StandardMaterial3D:
	if _cache.has("lamp_glow"):
		return _cache["lamp_glow"]
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(1.0, 0.92, 0.75)
	m.emission_enabled = true
	m.emission = Color(1.0, 0.85, 0.6)
	m.emission_energy_multiplier = 2.5
	_cache["lamp_glow"] = m
	return m

## Thin dark crack lines on a cracked panel.
static func crack() -> StandardMaterial3D:
	if _cache.has("crack"):
		return _cache["crack"]
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.06, 0.05, 0.045)
	m.roughness = 1.0
	_cache["crack"] = m
	return m

## Procedural radial crack texture for concrete impact decals (white cracks on
## transparent; the decal modulate tints them dark).
static func crack_decal_texture() -> Texture2D:
	if _cache.has("crack_tex"):
		return _cache["crack_tex"]
	var size := 256
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 7331
	var c := Vector2(size, size) * 0.5
	# Crushed centre.
	for y in range(-14, 15):
		for x in range(-14, 15):
			var d := sqrt(float(x * x + y * y))
			if d < 14.0 and rng.randf() < 1.0 - d / 16.0:
				img.set_pixel(int(c.x) + x, int(c.y) + y, Color(1, 1, 1, 0.85 * (1.0 - d / 16.0)))
	var arms := 9
	for i in arms:
		var ang := TAU * float(i) / float(arms) + rng.randf_range(-0.3, 0.3)
		_crack_walk(img, c, ang, rng.randf_range(70.0, 118.0), 2.6, rng, 2)
	var tex := ImageTexture.create_from_image(img)
	_cache["crack_tex"] = tex
	return tex

static func _crack_walk(img: Image, start: Vector2, ang: float, length: float, width: float,
		rng: RandomNumberGenerator, depth: int) -> void:
	var p := start
	var travelled := 0.0
	var size := img.get_width()
	while travelled < length:
		ang += rng.randf_range(-0.35, 0.35)
		var step := Vector2(cos(ang), sin(ang)) * 2.0
		p += step
		travelled += 2.0
		var w := maxf(0.6, width * (1.0 - travelled / length))
		var r := int(ceil(w))
		for oy in range(-r, r + 1):
			for ox in range(-r, r + 1):
				var q := Vector2i(int(p.x) + ox, int(p.y) + oy)
				if q.x < 0 or q.y < 0 or q.x >= size or q.y >= size:
					continue
				if Vector2(ox, oy).length() <= w:
					img.set_pixelv(q, Color(1, 1, 1, 1))
		if depth > 0 and rng.randf() < 0.05:
			_crack_walk(img, p, ang + rng.randf_range(-1.0, 1.0), (length - travelled) * 0.6,
				w * 0.7, rng, depth - 1)

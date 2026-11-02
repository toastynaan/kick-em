shader_type canvas_item;
// Full-screen speed effects (ScreenFX): a radial blur centred slightly above
// the screen middle, and thin white speed lines at the screen edges. Both
// ramp from ScreenFX (Feel Reference: Screen effects): strength =
// sprint_charge^2 x Tuning.BLUR_MAX, lines from Tuning.SPEED_LINES_FROM.
// OWNER: agent F.

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap, repeat_disable;
// 0..Tuning.BLUR_MAX
uniform float strength : hint_range(0.0, 1.0) = 0.0;
// Blur centre in screen UV (y down): slightly above the middle.
uniform vec2 center = vec2(0.5, 0.45);
// 0..1 speed-line amount
uniform float lines : hint_range(0.0, 1.0) = 0.0;
// Speed-line density: 1 at the base sprint cap, up to 1.5 at the upgraded caps.
uniform float density = 1.0;
// Seconds, for the line motion (real time).
uniform float time_s = 0.0;
// Sampling span of the blur at strength 1 (fraction of the distance to the centre).
uniform float span = 0.16;

const int TAPS = 12;

float hash11(float p) {
	p = fract(p * 0.1031);
	p *= p + 33.33;
	p *= p + p;
	return fract(p);
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 d = uv - center;
	float aspect = SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x;
	vec2 da = vec2(d.x * aspect, d.y);
	float r = length(da);
	vec3 col = texture(screen_tex, uv).rgb;
	if (strength > 0.001) {
		// The centre (the player) stays sharp; the blur grows toward the edges.
		float edge = smoothstep(0.06, 0.55, r);
		vec3 acc = col;
		float wsum = 1.0;
		for (int i = 1; i <= TAPS; i++) {
			float k = float(i) / float(TAPS);
			float w = 1.0 - k * 0.6;
			acc += texture(screen_tex, uv - d * k * strength * span * edge).rgb * w;
			wsum += w;
		}
		col = acc / wsum;
	}
	if (lines > 0.001) {
		float ang = atan(da.y, da.x) / 6.2831853 + 0.5;
		float n = 150.0;
		float cell = floor(ang * n);
		float h = hash11(cell + 7.0);
		// Only some angular cells carry a line, each thin.
		float present = step(1.0 - 0.13 * density, h);
		float across = abs(fract(ang * n) - 0.5) * 2.0;
		float thin = 1.0 - smoothstep(0.0, 0.28, across);
		// Streaks rush outward along the radius.
		float seg = fract(r * 2.2 - time_s * (2.5 + h * 2.0) + h * 13.0);
		float streak = smoothstep(0.0, 0.25, seg) * (1.0 - smoothstep(0.45, 0.6, seg));
		float mask = smoothstep(0.34, 0.62, r);
		// Subtle (Feel Reference): thin, sparse, at most 20% over the image.
		col += vec3(1.0) * present * thin * streak * mask * lines * 0.2;
	}
	COLOR = vec4(col, 1.0);
}

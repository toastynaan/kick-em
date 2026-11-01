class_name SnapSheet
extends RefCounted
## Collects viewport frames and writes them as one contact-sheet PNG.
## OWNER: core (integration tests). Needs a rendering (non-headless) run.

const CELL := Vector2i(640, 360)
const COLS := 3

var frames: Array[Image] = []
var labels: Array[String] = []

func capture(vp: Viewport, label := "") -> void:
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	img.resize(CELL.x, CELL.y, Image.INTERPOLATE_BILINEAR)
	frames.append(img)
	labels.append(label)

func save(path: String) -> void:
	if frames.is_empty():
		return
	var rows := ceili(frames.size() / float(COLS))
	var sheet := Image.create(CELL.x * COLS, CELL.y * rows, false, frames[0].get_format())
	for i in frames.size():
		@warning_ignore("integer_division")
		var at := Vector2i((i % COLS) * CELL.x, (i / COLS) * CELL.y)
		sheet.blit_rect(frames[i], Rect2i(Vector2i.ZERO, CELL), at)
	sheet.save_png(path)
	print("[snap] wrote %s (%d frames: %s)" % [path, frames.size(), ", ".join(labels)])
	frames.clear()
	labels.clear()

extends Control

const IDLE_COLOR := Color(1.0, 1.0, 1.0, 0.82)
const ACTIVE_COLOR := Color(0.78, 0.93, 1.0, 1.0)
const STROKE := 2.0

const ICONS := ["raise", "lower", "smooth", "flatten", "roughen", "pickaxe",
	"pause", "play", "faster"]

var icon_id := ""

func _init(id := "") -> void:
	icon_id = id
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _ready() -> void:
	var button := get_parent() as BaseButton
	if button != null:
		button.toggled.connect(func(_on: bool) -> void: queue_redraw())
		button.mouse_entered.connect(queue_redraw)
		button.mouse_exited.connect(queue_redraw)

static func has_icon(id: String) -> bool:
	return ICONS.has(id)

func _color() -> Color:
	var button := get_parent() as BaseButton
	if button != null and (button.button_pressed or button.is_hovered()):
		return ACTIVE_COLOR
	return IDLE_COLOR

func _draw() -> void:
	var s := minf(size.x, size.y) / 24.0
	draw_set_transform((size - Vector2(24.0, 24.0) * s) * 0.5, 0.0, Vector2(s, s))
	var c := _color()
	match icon_id:
		"raise":
			_line([Vector2(2, 21), Vector2(22, 21)], c)
			_line(_arc(Vector2(12, 21), 7.0, PI, TAU), c)
			_arrow(Vector2(12, 11), Vector2(12, 2), c)
		"lower":
			_line([Vector2(2, 12), Vector2(5, 12)], c)
			_line(_arc(Vector2(12, 12), 7.0, 0.0, PI), c)
			_line([Vector2(19, 12), Vector2(22, 12)], c)
			_arrow(Vector2(12, 2), Vector2(12, 14), c)
		"smooth":
			var wave := PackedVector2Array()
			for k in 21:
				var x := 2.0 + k
				wave.append(Vector2(x, 6.0 - 2.6 * sin((x - 2.0) / 20.0 * TAU * 2.0)))
			_line(wave, c)
			_arrow(Vector2(12, 10.5), Vector2(12, 17), c, 3.0)
			_line([Vector2(2, 20.5), Vector2(22, 20.5)], c)
		"flatten":
			_arrow(Vector2(12, 2), Vector2(12, 14), c)
			_line([Vector2(3, 17), Vector2(21, 17)], c, 2.6)
			_line([Vector2(6, 21.5), Vector2(18, 21.5)], c)
		"roughen":
			_line([Vector2(2, 18), Vector2(5, 11), Vector2(8, 15), Vector2(11, 5),
				Vector2(14, 13), Vector2(17, 8), Vector2(20, 14), Vector2(22, 11)], c)
			_line([Vector2(2, 21.5), Vector2(22, 21.5)], c)
		"pickaxe":
			_line([Vector2(4, 21.5), Vector2(14.5, 5.5)], c, 2.3)
			var head := PackedVector2Array()
			var a := Vector2(6.8, 3.5)
			var ctrl := Vector2(15.9, 3.4)
			var b := Vector2(19.4, 11.7)
			for k in 13:
				var t := k / 12.0
				head.append(a.lerp(ctrl, t).lerp(ctrl.lerp(b, t), t))
			_line(head, c, 2.6)
		"pause":
			_line([Vector2(8, 5), Vector2(8, 19)], c, 3.2)
			_line([Vector2(16, 5), Vector2(16, 19)], c, 3.2)
		"play":
			draw_colored_polygon(PackedVector2Array([Vector2(7, 4.5), Vector2(19.5, 12),
				Vector2(7, 19.5)]), c)
		"faster":
			draw_colored_polygon(PackedVector2Array([Vector2(2.5, 5.5), Vector2(12, 12),
				Vector2(2.5, 18.5)]), c)
			draw_colored_polygon(PackedVector2Array([Vector2(12, 5.5), Vector2(21.5, 12),
				Vector2(12, 18.5)]), c)

func _line(points, c: Color, width := STROKE) -> void:
	draw_polyline(PackedVector2Array(points), c, width, true)

func _arrow(from: Vector2, to: Vector2, c: Color, head := 4.0) -> void:
	var d := (to - from).normalized()
	var n := Vector2(-d.y, d.x)
	_line([from, to], c)
	_line([to - d * head * 1.1 + n * head, to, to - d * head * 1.1 - n * head], c)

func _arc(center: Vector2, radius: float, a0: float, a1: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for k in 17:
		var a := lerpf(a0, a1, k / 16.0)
		pts.append(center + Vector2(cos(a), sin(a)) * radius)
	return pts

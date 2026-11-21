extends "res://scripts/Main.gd"
## Kamerafahrt und Zeitraffer für die Abnahme der Einzelbäume (#236): ein
## fester Ablauf, der durch alle Stufen und Symbolgrößen des Walds fährt
## (`scripts/look/tree-flight.sh` nimmt ihn mit `--write-movie` auf). Kein
## Produktionsweg.
##
##   0 … 2 s    Diorama, Stand
##   2 … 14 s   Fahrt vom Diorama in die Nahsicht (`nah` aus shots.sh)
##  14 … 16 s   Stand
##  16 … 28 s   Zeitraffer 60 J./s in der Nahsicht
##  28 … 36 s   Zeitraffer weiter, Fahrt zurück auf die Talsicht
##  36 s        Ende

const NEAR_TARGET := Vector2(17.0, 10.0)
const NEAR_DIST := 16.0
const NEAR_PITCH := 0.55
const MID_DIST := 45.0
var flight_t := 0.0
var flight_from := {}
var flight_near := {}

func _ready() -> void:
	super._ready()
	for child in get_children():
		if child is CanvasLayer:
			child.visible = false
	_apply_camera_preset(0, false)
	flight_from = {"dist": cam_dist, "pitch": cam_pitch, "yaw": cam_yaw, "target": cam_target}
	var t := Vector3(NEAR_TARGET.x, 0.0, NEAR_TARGET.y)
	t.y = _surface_y_at(t)
	flight_near = {"dist": NEAR_DIST, "pitch": NEAR_PITCH, "yaw": 0.0, "target": t}

func _process(delta: float) -> void:
	last_activity_msec = Time.get_ticks_msec()  # Renderloop nie anhalten
	flight_t += delta
	if flight_t < 2.0:
		_flight_view(flight_from, flight_near, 0.0)
	elif flight_t < 14.0:
		_flight_view(flight_from, flight_near, smoothstep(2.0, 14.0, flight_t))
	elif flight_t < 16.0:
		_flight_view(flight_from, flight_near, 1.0)
	elif flight_t < 28.0:
		year_rate = 60.0
	elif flight_t < 36.0:
		var mid := flight_near.duplicate()
		mid["dist"] = MID_DIST
		_flight_view(flight_near, mid, smoothstep(28.0, 36.0, flight_t))
	else:
		get_tree().quit()
	super._process(delta)

## Abstand logarithmisch, alles andere linear: die Fahrt wirkt gleichmäßig.
func _flight_view(a: Dictionary, b: Dictionary, s: float) -> void:
	cam_dist = exp(lerpf(log(a["dist"]), log(b["dist"]), s))
	cam_pitch = lerpf(a["pitch"], b["pitch"], s)
	cam_yaw = lerp_angle(a["yaw"], b["yaw"], s)
	cam_target = (a["target"] as Vector3).lerp(b["target"], s)
	_update_camera()

func _update_brush() -> void:
	brush_mi.visible = false

extends SceneTree
## Vertrags-Wächter für die GPU-Kette des Wasserfeld-Schwanzes (Issue #95):
##   scripts/godot-test.sh res://tests/water_gpu_tail.gd WATER_GPU_TAIL_OK
##
## Der Pass-Plan der Kette (Kanal-Masken, Pass-Zahl, Priming) reist seit #95
## als Daten aus SimRender (WaterTailPlan) über die Brücke; die Struktur-
## Wächter dafür stehen headless in SimCoreTests/WaterTailPlanTests.swift.
## Dieser Test hier ist die AUSFÜHRBARE Deckung der Kette:
##  - Plausibilität der Brücken-Daten (Masken 0/1, kein toter Pass, Priming
##    in [0,1], Pass-Zahl passt zur Masken-Tabelle).
##  - CPU gegen GPU: dieselbe Frame-Folge (settled + Zeitraffer-Takte) durch
##    beide Pfade, Vergleich aller vier Kanäle Zelle für Zelle — Toleranz mit
##    Begründung an `_compare`.
##  - Priming: der ERSTE Tick übernimmt das Feld vollständig, auch wenn die
##    Blende klein wäre (Datum: WaterTailPlan.primeBlend über die Brücke).
##  - Framerate-Unabhängigkeit der EWMA: dieselbe Update-Folge, verschieden
##    viele Frames zwischen den Updates (4 gegen 10) → dasselbe Feld. Die EWMA
##    tickt mit dem TEXTUR-Update (UPDATE_ONCE je update()), nicht mit dem
##    Frame — auf UPDATE_ALWAYS wäre die Glättungsrate an die Bildrate
##    gekoppelt (AGENTS.md, Framerate-Unabhängigkeit).
##
## Headless (Dummy-Renderer, kein Rendering-Device) läuft der Test trotzdem
## grün: die Daten-Wächter laufen immer, der GPU-Teil überspringt mit klarer
## Meldung. In CI stellt der Wrapper xvfb + Software-GL bereit
## (scripts/godot-test.sh, GODOT_TEST_RENDER=1), damit der Vergleich läuft;
## lokal geht dasselbe über `GODOT_TEST_RENDER=1 scripts/godot-test.sh …` —
## oder direkt `"$GODOT" --path game --rendering-method gl_compatibility
## --script res://tests/water_gpu_tail.gd`.

const BuildStamp = preload("res://scripts/BuildStamp.gd")
const WaterGpuTailScript = preload("res://scripts/WaterGpuTail.gd")

# Auslöser == SimRender.FrameTrigger / Main.FRAME_*: 0 = settled (Blende 1.0,
# wie Start/Neu/Laden), 2 = timelapse (Blende aus RenderState, 0.15). Die
# Blende wird je Takt AUS dem Frame gelesen, nicht hier gepinnt.
const FRAME_SETTLED := 0
const FRAME_TIMELAPSE := 2
# Zeitraffer-Takte: je 1000 Jahre — genug, dass die EWMA mehrere Zwischen-
# stände mischt, wenig genug für die CI-Laufzeit (vgl. water_rings.gd).
const TIMELAPSE_TICKS := 6
const STEP_YEARS := 1000.0
# Die simulierte Uhr je Takt: größer als RenderState.overlayIntervalSeconds
# (0.30 s), damit kein Zeitraffer-Takt gedrosselt wird.
const TICK_SECONDS := 1.0

# CPU/GPU-Toleranz in 255teln, Begründung an `_compare`.
const TOL_MAX := 4.0 / 255.0
const TOL_MEAN := 2.0 / 255.0
# Frame-Kadenz-Vergleich: dieselbe Kette, dieselben Updates — Abweichung darf
# nur Readback-Rundung sein.
const TOL_CADENCE := 1.0 / 255.0

var started := false
var failed := false
var n := 0

func _process(_delta: float) -> bool:
	if not started:
		started = true
		_run()
	return _finished

var _finished := false

func _fail(msg: String) -> void:
	push_error("FAIL: " + msg)
	failed = true

## Wartet `count` Engine-Frames (SceneTree-Signal, feuert auch headless).
func _frames(count: int) -> void:
	for _i in count:
		await process_frame

func _run() -> void:
	if not ClassDB.class_exists("SimNode"):
		push_error("FAIL: SimNode nicht registriert (godot --headless --path game --import)")
		_finish()
		return
	# Zwei frische Instanzen: Referenz (CPU-Schwanz) und Rohstoff (GPU-Pfad).
	# Beide laufen dieselbe Frame-Folge über dieselbe Welt (Determinismus je
	# Maschine), also ist das Feld VOR dem Schwanz bit-identisch — der
	# Vergleich misst NUR den Unterschied der beiden Schwanz-Fassungen.
	var sim_cpu: Object = ClassDB.instantiate("SimNode")
	if not BuildStamp.check(sim_cpu):
		failed = true
		_finish()
		return
	var sim_gpu: Object = ClassDB.instantiate("SimNode")
	n = sim_cpu.gridSize()

	# --- Pass-Plan über die Brücke (Daten-Wächter, immer headless) -----------
	var pass_count: int = sim_cpu.waterTailBlurPassCount()
	var masks: PackedFloat32Array = sim_cpu.waterTailBlurMasks()
	var prime_blend: float = sim_cpu.waterTailPrimeBlend()
	if pass_count < 1:
		_fail("Pass-Zahl der Blur-Kette ist %d" % pass_count)
	if masks.size() != pass_count * 2:
		_fail("Masken-Tabelle (%d Werte) passt nicht zur Pass-Zahl %d"
			% [masks.size(), pass_count])
	for i in masks.size():
		if masks[i] != 0.0 and masks[i] != 1.0:
			_fail("Kanal-Maske muss 0 oder 1 sein, bekam %f" % masks[i])
	for p in pass_count:
		if masks.size() == pass_count * 2 and masks[p * 2] == 0.0 and masks[p * 2 + 1] == 0.0:
			_fail("Blur-Pass %d glättet keinen Kanal — toter Pass" % p)
	if prime_blend < 0.0 or prime_blend > 1.0:
		_fail("Priming-Blende außerhalb [0,1]: %f" % prime_blend)
	print("plan: passes=", pass_count, " prime_blend=", prime_blend)

	if failed:
		_finish()
		return

	# --- Rendering-Device? (headless = Dummy-Renderer) ----------------------
	var has_renderer := await _probe_renderer()
	if not has_renderer:
		if failed:
			_finish()
			return
		print("SKIP: kein Rendering-Device (Dummy-Renderer, --headless) —")
		print("      CPU/GPU-Vergleich, Priming-Beleg und Framerate-Beleg brauchen")
		print("      einen Renderer. Struktur: SimCoreTests/WaterTailPlanTests.swift,")
		print("      Daten-Wächter oben sind gelaufen.")
		print("WATER_GPU_TAIL_OK")
		_finished = true
		quit(0)
		return

	# --- Beide Pfade über denselben Lauf -------------------------------------
	var cpu_frames: Array = []
	var gpu_frames: Array = []
	_collect_frames(sim_cpu, false, cpu_frames)
	_collect_frames(sim_gpu, true, gpu_frames)
	if cpu_frames.size() != TIMELAPSE_TICKS + 1 or gpu_frames.size() != cpu_frames.size():
		_fail("Frame-Folge unvollständig: cpu=%d gpu=%d"
			% [cpu_frames.size(), gpu_frames.size()])
		_finish()
		return
	# Die Blende je Takt reist auf beiden Seiten gleich (gleicher Auslöser).
	var timelapse_blend := 0.0
	for i in cpu_frames.size():
		var bl: float = cpu_frames[i]["blend"]
		if absf(bl - gpu_frames[i]["blend"]) > 1e-9:
			_fail("Blend weicht zwischen den Pfaden ab (Takt %d)" % i)
		if i > 0:
			timelapse_blend = bl
	if timelapse_blend <= 0.0 or timelapse_blend >= 1.0:
		_fail("Zeitraffer-Blende liegt nicht in (0,1): %f" % timelapse_blend)
	if failed:
		_finish()
		return

	# --- Hauptkette (Kadenz 4 Frames je Update) ------------------------------
	var tail := WaterGpuTailScript.new()
	root.add_child(tail)
	tail.setup(sim_gpu, n)
	var first_state := Image.new()
	for i in gpu_frames.size():
		tail.update(gpu_frames[i]["water"], gpu_frames[i]["blend"])
		await _frames(4)
		if i == 0:
			first_state = _state_image(tail)
	var gpu_final := _state_image(tail)
	if first_state.is_empty():
		_fail("Zustands-Readback der GPU-Kette ist leer")
		_finish()
		return

	# --- CPU gegen GPU (Endzustand) -----------------------------------------
	if not _compare(gpu_final, cpu_frames[cpu_frames.size() - 1]["water"],
			"cpu_gpu", TOL_MAX, TOL_MEAN):
		_finish()
		return

	# --- Priming: erster Tick übernimmt VOLL, auch mit kleiner Blende --------
	# Referenz ist der Zustand der Hauptkette nach ihrem ersten Takt (Blende
	# 1.0, gleiche Rohdaten). Ohne Priming stünde das Feld hier auf einem
	# Bruchteil (bl × Feld); die Abweichung wäre landschaftsgroß, nicht
	# rundungsbedingt.
	var tail_prime := WaterGpuTailScript.new()
	root.add_child(tail_prime)
	tail_prime.setup(sim_gpu, n)
	tail_prime.update(gpu_frames[0]["water"], timelapse_blend)
	await _frames(6)
	if not _compare(_state_image(tail_prime), _image_bytes(first_state),
			"priming", TOL_MAX, TOL_MEAN):
		_finish()
		return

	# --- Framerate-Unabhängigkeit: Kadenz 4 gegen Kadenz 10 -----------------
	var tail_slow := WaterGpuTailScript.new()
	root.add_child(tail_slow)
	tail_slow.setup(sim_gpu, n)
	for i in gpu_frames.size():
		tail_slow.update(gpu_frames[i]["water"], gpu_frames[i]["blend"])
		await _frames(10)
	if not _compare(gpu_final, _image_bytes(_state_image(tail_slow)),
			"frame_rate", TOL_CADENCE, TOL_CADENCE):
		_finish()
		return

	_finish()

## Sammelt die Frame-Folge (Rohbytes + Blende) für einen Pfad. `defer` = true
## liefert das UNGEBLURTE Feld (`setDeferWaterTail`), die Blende reist trotzdem
## je Frame — die GPU-Kette mischt damit selbst.
func _collect_frames(sim: Object, defer: bool, out: Array) -> void:
	sim.setDeferWaterTail(defer)
	var now := 1.0
	var frame: Dictionary = sim.renderFrame(FRAME_SETTLED, now)
	out.push_back({"water": frame["water"], "blend": frame["water_blend"]})
	for _k in TIMELAPSE_TICKS:
		sim.step(STEP_YEARS)
		now += TICK_SECONDS
		frame = sim.renderFrame(FRAME_TIMELAPSE, now)
		out.push_back({"water": frame["water"], "blend": frame["water_blend"]})

## Rendert ein magentafarbenes Rechteck in einen SubViewport und liest es
## zurück: trifft die Farbe, existiert ein Rendering-Device. Ein LEERER
## Readback ist der Dummy-Renderer von --headless → Überspringen ist rechtens.
## Ein NICHT leeres, aber falsches Bild wäre ein kaputter Renderer → rot.
func _probe_renderer() -> bool:
	var vp := SubViewport.new()
	vp.size = Vector2i(8, 8)
	vp.disable_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	var rect := ColorRect.new()
	rect.size = Vector2(8, 8)
	rect.color = Color(1.0, 0.0, 1.0, 1.0)
	vp.add_child(rect)
	root.add_child(vp)
	var img: Image = Image.new()
	# Bis zu 6 Frames lang: Fenster- und Renderer-Anlauf (xvfb/llvmpipe) kann
	# die ersten Frames brauchen; der Dummy-Renderer bleibt dauerhaft leer.
	for _i in 6:
		await process_frame
		img = vp.get_texture().get_image()
		if not img.is_empty():
			break
	vp.queue_free()
	if img.is_empty():
		return false
	if not img.get_pixel(4, 4).is_equal_approx(Color(1.0, 0.0, 1.0, 1.0)):
		_fail("Rendering-Device vorhanden, aber der Readback trifft nicht "
			+ "(Format %s, Pixel %s) — Überspringen wäre falsch"
			% [img.get_format(), img.get_pixel(4, 4)])
		return false
	print("renderer: ", RenderingServer.get_video_adapter_name())
	return true

func _state_image(tail) -> Image:
	return tail.current_texture().get_image()

## Bild als Byte-Vergleichsseite (für Bild-gegen-Bild-Vergleiche): gleiche
## Quantisierung wie die CPU-Seite (255tel), damit `_compare` eine Form hat.
func _image_bytes(img: Image) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(img.get_width() * img.get_height() * 4)
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			var o := (y * img.get_width() + x) * 4
			bytes[o] = int(round(clampf(c.r, 0.0, 1.0) * 255.0))
			bytes[o + 1] = int(round(clampf(c.g, 0.0, 1.0) * 255.0))
			bytes[o + 2] = int(round(clampf(c.b, 0.0, 1.0) * 255.0))
			bytes[o + 3] = int(round(clampf(c.a, 0.0, 1.0) * 255.0))
	return bytes

## Vergleicht das GPU-Ergebnis (Bild, Werte in [0,1]) gegen die CPU-Bytes
## (255tel) Zelle für Zelle und Kanal für Kanal. Toleranz, begründet:
##  - `byte01` schneidet ab (UInt8(x * 255), RenderSupport.swift): bis
##    1/255 EINSEITIG — auf beiden Seiten, denn das GPU-Rohfeld ist bereits
##    quantisiert, die CPU quantisiert erst am Ende.
##  - Der Rohfeld-Quantisierungsfehler bleibt unter 1/255 durch die ganze
##    Kette: Blur ist eine Konvexkombination, max() ist monoton, die EWMA ist
##    konvex — keiner der Schritte vergrößert den Fehler.
##  - Half-Float-Zustand: 2^-11 relativer Anteil ≈ 0,12/255 je Schritt, über
##    wenige Takte begrenzt.
##  - Readback RGBA16F → Float: exakt.
##  Summe mit Prüflast: max 4/255, im Mittel 2/255. Historisch in situ gemessen:
##  1,09/255 mittlere Abweichung (docs/perf-measurements.md §J); dieser Test
##  druckt seine eigenen Messwerte und hält sie unter den Schranken.
func _compare(img: Image, cpu: PackedByteArray, label: String,
		tol_max: float, tol_mean: float) -> bool:
	if img.is_empty() or img.get_width() != n or img.get_height() != n:
		_fail("%s: GPU-Bild hat falsche Größe (%s)"
			% [label, img.get_size()])
		return false
	if cpu.size() != n * n * 4:
		_fail("%s: CPU-Puffer hat falsche Größe (%d)" % [label, cpu.size()])
		return false
	var max_diff := 0.0
	var sum_diff := 0.0
	var cells := 0
	for y in n:
		for x in n:
			var c := img.get_pixel(x, y)
			var o := (y * n + x) * 4
			var channels := [c.r, c.g, c.b, c.a]
			for ch in 4:
				var d := absf(channels[ch] - cpu[o + ch] / 255.0)
				if d > max_diff:
					max_diff = d
				sum_diff += d
			cells += 1
	var mean_diff := sum_diff / float(cells * 4)
	print("%s: max=%.2f/255 mean=%.2f/255 (Grenzen %.1f/%.1f)"
		% [label, max_diff * 255.0, mean_diff * 255.0,
			tol_max * 255.0, tol_mean * 255.0])
	if max_diff > tol_max or mean_diff > tol_mean:
		_fail("%s: CPU/GPU-Abweichung zu groß: max=%.3f mean=%.3f (255tel)"
			% [label, max_diff * 255.0, mean_diff * 255.0])
		return false
	return true

func _finish() -> void:
	_finished = true
	if failed:
		quit(1)
		return
	print("WATER_GPU_TAIL_OK")
	quit(0)

# Mess-Instrumente: Marker-Profiler und Diagnose-Zähler sind kein Sim-Zustand

`SimProfile` (Issue #43) misst die Pass-Aufteilung eines Sim-Schritts mit Zeitstempeln an den Pass-Grenzen statt mit einem Sampling-Profiler: auf dem Linux-Host gibt es weder `perf` noch Instruments, und „welcher Pass kostet wie viel" ist mit Zeitstempeln exakt beantwortbar, Sampling schätzt es nur. Die Instrumentierung bleibt dauerhaft im Repo (Wächter gegen die nächste Perf-Regression), ist aber standardmäßig aus: `enabled == false` kostet je Pass einen Bool-Load, nichts Messbares (`docs/perf-measurements.md` §A).

Bedienung als Marker-Strom statt Closure-Wrapper: `Terrain.step()` setzt vor jedem Pass eine Marke, die den vorigen Span schließt. Die Pass-Reihenfolge in `step()` ist LEM-Konvention und muss am Stück lesbar bleiben; eine Marker-Zeile stört weniger als 20 verschachtelte `prof("…") { … }`-Blöcke. Der zweite Zeitstempel in `mark` ist Absicht: der neue Span zählt die eigene Buchhaltung nicht mit; was zwischen den Spans liegt, zeigt `simperf` als „nicht zugeordnet" (gemessen < 0,1 % des Schritts). `SimProfile` ist nicht thread-sicher und nicht dafür gedacht: gemessen wird der Hauptthread, auf dem `step()` läuft.

`SimProfile.onPassEnd` bekommt an jeder Pass-Grenze den Namen des endenden Passes, damit Messläufe die Höhenänderung eines Schritts den Pässen zuordnen (#174, Delta-Budget in `SimCoreTests/RiverDelta.swift`), ohne dass `step()` eigenen Code trägt; er läuft vor der Zeitmessung des nächsten Spans.

Diagnose-Zähler im Mäander-Zustand (`neckCutoffs`/`chuteCutoffs`, #174 Abnahmepunkt 15; `avulsions`, `retraced`, `coupledKept`/`coupledInserted`, `insertedByPlace`, #187) sind kein Sim-Zustand: kein Pass liest sie, sie stehen weder im Spielstand noch im Fingerabdruck. Der Haken `MeanderState.beltClampLog` existiert nur unter `RS_BELT_CLAMP_DIAGNOSTIC`; nur der Messlauf setzt ihn vor dem Parallelstart, die Aggregation synchronisiert der Aufrufer.

Betrifft: `SimProfile`, `SimProfile.mark`, `SimProfile.onPassEnd`, `Terrain.step`, `MeanderState.neckCutoffs`, `MeanderState.avulsions`, `MeanderState.beltClampLog`, `SimPerf`

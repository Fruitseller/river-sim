# CI: zwei parallele Jobs, Sim-Kern und Godot-Vertrag

CI hat zwei Verifikationsebenen als zwei Jobs (#52): `test` (SimCore, headless XCTest, GPU-frei, PLAN.md §5) und `godot-contract` (GDExtension bauen, Projekt importieren, Build-Stempel-Parität, Godot-Vertragstests). Sie sind bewusst nicht über `needs:` verkettet: sie teilen keinen Build (`SimCore/.build` gegen `Extension/.build`, verschiedene Paketgraphen und Scratch-Pfade) und laufen parallel, die Laufzeit ist die des langsameren Jobs. Messwerte und Budget: `docs/ci-measurements.md`.

Bis #52 lief nur der Sim-Kern; der Godot-Vertrag war eine Review-Zusage („lokal ausgeführt") und lief damit genau dann nicht, wenn es darauf ankam. Die Datei hieß `simcore-tests.yml`. Der Job heißt weiter `test`, damit Branch-Schutz und Badges auf denselben Check zeigen.

`RS_MEASURE` bleibt in CI ungesetzt: die Mess-/Sweep-Läufe (Namensendung `Diagnostic`) drucken nur Tabellen für `docs/`, können nicht rot werden und kosten den Großteil der Laufzeit (s. `SimCore/Tests/SimCoreTests/MeasurementGate.swift`).

Zeitdeckel: `test` 40 min bei lokal ~7 min und 15 min Budget; der Deckel fängt Hänger, nicht langsames Wachstum, sonst verbrennt ein Endlos-Test sechs Stunden Runner-Zeit. `godot-contract` 75 min: Kaltbau der Extension auf einem 4-Kern-Runner ~27 min (SwiftGodots Codegen dominiert), mit warmem Cache Minuten; der Deckel lässt Kaltbau plus Godot-Läufe zu.

Extension-Build-Cache: SwiftGodots Codegen speist die ganze Modulkette. Der Key hängt an `Extension/Package.resolved` (Pin aus #49) und an den Quellen; der restore-key holt sonst den letzten Stand desselben Toolchain-Stands, aus dem SwiftPM inkrementell weiterbaut.

Betrifft: `.github/workflows/ci.yml` (Jobs `test`, `godot-contract`, `timeout-minutes`, Extension-Build-Cache)

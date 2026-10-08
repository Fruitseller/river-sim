# Landschaftsqualität: Abnahmematrix-Bilder

Dieses Verzeichnis enthält die standardisierten Referenzbilder der Abnahmematrix
aus Issue #150 (Spec #156, Parent #117).

## Namenskonvention

Jede Datei folgt dem Schema:
`seed<SEED>_<STADIUM>_<KAMERA>.png`

- **Seed**: `1337` (Flusstal Soča), `42` (Seen- und Beckenplateau), `20` (Hochalpines Massiv)
- **Stadium**: `0k` (Jahr 0 nach Einlauf), `20k` (Jahr 20.000, mittlere Reife), `100k` (Jahr 100.000, Altersstadium)
- **Kamera**:
  - `overview`: Vollständige Übersicht (großräumige Silhouette, Massiv, Inselform)
  - `detail`: Charakteristischer Ausschnitt des Hauptmerkmals
  - `grazing`: Flacher Blickwinkel (~13° über Horizont, Prüfung von Parallaxe und Flachheit)
  - `backlight`: Gegenlichtaufnahme gegen die tiefstehende Sonne (Prüfung von Schatten und Kontrast)
  - `coast`: Küste, Mündungsdelta oder Seeufer (Prüfung der Uferlinie und Schutzmaske)
  - `snow`: Hochalpine Schneefelder und scharfe Felsgrate (Prüfung von Schneegrenze und Gratschärfung)

## Erzeugung

Ein Aufruf erzeugt alle Bilder einer Variante:
```sh
# Baseline-Bilder (Produktionsstand)
scripts/graphics-matrix.sh baseline docs/screenshots/graphics-matrix/baseline shot

# Prototyp-Bilder (#116 Flusstal-Studie mit allen Hebeln)
scripts/graphics-matrix.sh prototype docs/screenshots/graphics-matrix/prototype shot
```

## Vorhandene Baseline-Aufnahmen (Zielmaschine M4 Max, 3456×2104)

- `baseline/seed1337_20k_overview.png`: M4-Max-Aufnahme aus der Referenzstudie (#116)
- `baseline/seed1337_20k_detail.png`: M4-Max-Aufnahme aus der Referenzstudie (#116)

*Hinweis:* Gemäß Issue #150 und AGENTS.md werden auf dem Linux-Entwicklerhost keine
Kaltbauten oder GPU-Renderings simuliert und keine erfundenen Pixel erzeugt.
Die verbleibenden Matrixaufnahmen der Zielmaschine (M4 Max, 3456×2104 Viewport, maximiert)
werden bei Zugriff auf die Referenzhardware über `scripts/graphics-matrix.sh` ausgeführt.

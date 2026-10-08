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

## Referenz-Aufnahmen und Namensbeispiele (Zielmaschine M4 Max, 3456×2104)

Die beiden Aufnahmen der Referenzwelt (Seed 1337, 20k) liegen als Originale bereits
in der Flusstal-Studie vor und entsprechen der Matrix-Kameradefinition:
- `docs/screenshots/graphics-quality/baseline-overview.png` (entspricht `seed1337_20k_overview.png`)
- `docs/screenshots/graphics-quality/baseline-detail.png` (entspricht `seed1337_20k_detail.png`)

Um redundante Kopien derselben Binärdateien im Repository zu vermeiden, verweist die
Matrix auf diese Originale. Bei einem frischen Matrix-Export via `scripts/graphics-matrix.sh`
werden alle 54 Bilddateien direkt in den angegebenen Zielordner (z. B.
`docs/screenshots/graphics-matrix/baseline/`) geschrieben.

*Hinweis:* Gemäß Issue #150 und AGENTS.md werden auf dem Linux-Entwicklerhost keine
Kaltbauten oder GPU-Renderings simuliert und keine erfundenen Pixel erzeugt.
Die vollständige Generierung aller Matrixaufnahmen der Zielmaschine (M4 Max, 3456×2104 Viewport, maximiert)
erfolgt bei Zugriff auf die Referenzhardware über `scripts/graphics-matrix.sh`.

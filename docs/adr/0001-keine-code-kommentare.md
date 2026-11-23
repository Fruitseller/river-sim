# Keine Kommentare im Code

Der Code trug rund 22.000 Kommentarzeilen, fast ein Drittel aller Zeilen. Ein Audit (November 2026) ordnete jeden der 5804 Blöcke ein: 3452 wiederholten nur den Code, 45 waren veraltet, 117 entschuldigten eine unsaubere Stelle, 2169 hielten eine Entscheidung fest. Wir haben alle gelöscht und schreiben keine neuen. Ein Kommentar altert unbemerkt neben dem Code, den er beschreibt (das Audit fand Dutzende Begründungen mit überholten Zahlen, Dateien und Issue-Bezügen), und eine Entschuldigung im Code macht den Notbehelf zum Muster, das der nächste kopiert.

Was früher ein Kommentar war, geht jetzt an eine von drei Stellen:

- Erklärt er nur den Code, wird der Code deutlicher: ein besserer Name, eine kleinere Funktion, ein benannter Wert.
- Begründet er eine Entscheidung (Messwerte, verworfene Werte, Verträge zwischen Schichten, Reihenfolge, Determinismus), kommt sie als ADR nach `docs/adr/`. Das gilt auch für das frühere Kalibrier-Logbuch in `Config.swift`.
- Entschuldigt er einen Notbehelf, wird daraus ein Issue, das den Notbehelf beseitigt.

Erlaubt bleiben nur Kommentare, die ein Werkzeug liest oder das Recht verlangt: Shebang, `swift-tools-version`, `shellcheck`-Direktiven, `SPDX-License-Identifier` und `Copyright (c)`-Zeilen in Dateien unter fremder Lizenz (s. `NOTICE`), die Versionsangaben hinter SHA-gepinnten Actions (`# v6.1.0`, pflegt Dependabot).

Durchgesetzt wird die Regel mit einer Ratsche: `python3 scripts/comments.py check` läuft im CI-Job `test` und vergleicht die Kommentarzeilen je Datei mit `scripts/comment-baseline.json`. Mehr als die Baseline erlaubt ist rot. Weniger auch, bis die Baseline mit `python3 scripts/comments.py baseline` nachgezogen ist, damit jeder Abbau eingerastet bleibt. Nach dem Audit ist die Baseline leer. Kommt ein Altstand mit Kommentaren zurück (ein langlebiger Branch, ein Revert), trägt man ihn in die Baseline ein und baut ihn mit dem Skill `/delete-comment` ab.

Ein eigenes Werkzeug statt SwiftLint oder gdlint, weil es keine fertige Regel „keine Kommentare" für Swift, GDScript, Godot-Shader, GLSL, Shell, Python und YAML zugleich gibt und das Repo keine dieser Toolchains im Lint-Schritt voraussetzen soll. Das Skript braucht nur Python 3 aus der Standardbibliothek und kennt die Zeichenketten jeder Sprache, damit ein `//` oder `#` in einem String nicht als Kommentar zählt.

Betrifft: `scripts/comments.py`, `scripts/comment-baseline.json`, `.github/workflows/ci.yml` (Job `test`), `.claude/skills/delete-comment/SKILL.md`

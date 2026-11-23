# Keine Kommentare im Code

Der Code trug rund 22.000 Kommentarzeilen, fast ein Drittel aller Zeilen. Ein Audit (November 2026) hat alle 5804 Blöcke eingeordnet und bis auf Lizenz- und Werkzeugzeilen gelöscht; seitdem kommen keine neuen dazu. Ein Kommentar altert unbemerkt neben dem Code, den er beschreibt (das Audit fand Dutzende Begründungen mit überholten Zahlen, Dateien und Issue-Bezügen), und eine Entschuldigung im Code macht den Notbehelf zum Muster, das der nächste kopiert.

Was ein Kommentar sagen wollte, geht an eine von vier Stellen oder nirgendwohin:

- Erklärt er nur den Code, wird der Code deutlicher: ein besserer Name, eine kleinere Funktion, ein benannter Wert.
- Ist er eine Entscheidung, die schwer rückgängig zu machen ist, ohne Kontext überrascht und aus einer echten Abwägung kam (alle drei), wird er ein ADR in `docs/adr/`. Das ist die Ausnahme: aus den 5804 Blöcken des Audits wurden 13 ADRs.
- Hält er eine Messung oder einen verworfenen Wert fest, gehört das in die Messreihe `docs/*-measurements.md`, nicht in ein ADR je Konstante.
- Entschuldigt er einen Notbehelf, wird daraus ein Issue, das den Notbehelf beseitigt (#250–#284).

Erlaubt bleiben nur Kommentare, die ein Werkzeug liest oder das Recht verlangt: Shebang, `swift-tools-version`, `shellcheck`-Direktiven, `SPDX-License-Identifier` und `Copyright (c)`-Zeilen in Dateien unter fremder Lizenz (s. `NOTICE`), die Versionsangaben hinter SHA-gepinnten Actions (`# v6.1.0`, pflegt Dependabot).

Durchgesetzt wird die Regel mit einer Ratsche: `python3 scripts/comments.py check` läuft im CI-Job `test` und vergleicht die Kommentarzeilen je Datei mit `scripts/comment-baseline.json`. Mehr als die Baseline erlaubt ist rot. Weniger auch, bis die Baseline mit `python3 scripts/comments.py baseline` nachgezogen ist, damit jeder Abbau eingerastet bleibt. Ziel ist eine leere Baseline. Kommt ein Altstand mit Kommentaren zurück (ein langlebiger Branch, ein Revert), trägt man ihn in die Baseline ein und baut ihn mit dem Skill `/delete-comment` ab.

Ein eigenes Werkzeug statt SwiftLint oder gdlint, weil es keine fertige Regel „keine Kommentare" für Swift, GDScript, Godot-Shader, GLSL, Shell, Python und YAML zugleich gibt und das Repo keine dieser Toolchains im Lint-Schritt voraussetzen soll. Das Skript braucht nur Python 3 aus der Standardbibliothek und kennt die Zeichenketten jeder Sprache, damit ein `//` oder `#` in einem String nicht als Kommentar zählt.

Betrifft: `scripts/comments.py`, `scripts/comment-baseline.json`, `.github/workflows/ci.yml` (Job `test`), `.claude/skills/delete-comment/SKILL.md`

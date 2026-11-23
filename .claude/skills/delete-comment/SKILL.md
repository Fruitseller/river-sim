---
name: delete-comment
description: Kommentare aus dem Code entfernen; Entscheidungen werden ADRs, Notbehelfe werden Issues, die Ratsche rastet ein.
disable-model-invocation: true
argument-hint: "[Pfad …]  (leer: alle Dateien aus scripts/comment-baseline.json)"
---

Baut Kommentare nach [ADR 0001](../../../docs/adr/0001-keine-code-kommentare.md) ab. Jeder Kommentarblock wird eingeordnet, sein Inhalt landet am richtigen Ort, dann löscht ein Skript den Block. Du editierst Quellcode nie von Hand, nur über `scripts/comments.py`.

`$S` ist dein Scratchpad. Alle Befehle laufen aus der Repo-Wurzel.

## 1. Blöcke holen

```sh
python3 scripts/comments.py stats $ARGUMENTS          # was steht an
python3 scripts/comments.py extract $ARGUMENTS > $S/blocks.json
```

Ohne Argument kommen alle Dateien, die noch Kommentare haben. Jeder Block hat eine `id` (`pfad:zeile`), die bis zum Löschen gilt; zwischen `extract` und `delete` ändert niemand die Dateien.

Fertig, wenn `$S/blocks.json` steht und du die Zahl der Blöcke kennst.

## 2. Einordnen

Jeder Block bekommt genau eine Kategorie nach [CLASSIFY.md](CLASSIFY.md): `tautology`, `stale`, `excuse`, `decision` oder `keep`. Lies die Regeln dort vollständig, bevor du anfängst.

Ab etwa 400 Blöcken teilst du nach Teilsystem in Pakete von rund 1500 Kommentarzeilen und gibst jedes Paket einem Subagenten mit CLASSIFY.md als Auftrag. Subagenten schreiben nur ins Scratchpad, nie ins Repo.

Fertig, wenn jede `id` aus `blocks.json` genau einmal in einer `decisions.json` steht (mit einem kurzen Python-Skript prüfen).

## 3. Entscheidungen in ADRs

Für jede `decision`-Gruppe:

1. `grep -rl '<Symbol>' docs/adr/` — gibt es schon ein ADR zu dieser Entscheidung, ergänzt du dort.
2. Sonst neues ADR `docs/adr/NNNN-slug.md`, nächste freie Nummer, Format wie in `docs/adr/README.md` beschrieben, und eine Zeile im passenden Abschnitt der README.

Den Inhalt verschieben, nicht zusammenfassen: Messwerte, verworfene Werte mit Grund, Issue- und Doku-Verweise bleiben erhalten. Keine Zeilennummern.

## 4. Notbehelfe als Issues

Je Notbehelf (nicht je Block) ein Issue in `Fruitseller/river-sim`, auf Deutsch: was der Notbehelf ist, wo (Datei und Symbol), was der Kommentar behauptete (kurz zitiert), wie die richtige Lösung aussähe. Vorher `gh issue list --search '<Stichwort>'`, um Dubletten zu vermeiden. Letzte Zeile des Bodys ist die Signatur aus der globalen Agent-Regel. Verweise in ADRs auf den Notbehelf zeigen auf die Issue-Nummer.

## 5. Löschen und einrasten

```sh
python3 -c "import json,glob; json.dump([x['id'] for f in glob.glob('$S/out/*/decisions.json') for x in json.load(open(f)) if x['category']!='keep'], open('$S/ids.json','w'))"
python3 scripts/comments.py delete $S/ids.json
python3 scripts/comments.py baseline
python3 scripts/comments.py check
```

`keep`-Blöcke, die ein Werkzeug oder das Recht braucht, gehören in das `EXEMPT`-Muster von `scripts/comments.py`, damit sie nicht mitzählen.

## 6. Prüfen

- `swift test -c release --package-path SimCore` (Vorbereitung s. `AGENTS.md` § Befehle). Ein Test, der Kommentartext im Quelltext sucht (`.raw.contains`), fällt mit dem Kommentar weg; sein Inhalt steht dann im ADR.
- Geänderte Shell-Skripte: `bash -n`. Geänderte YAML: mit `yaml.safe_load` vor und nach dem Löschen vergleichen; ein ` #` in einem ungequoteten Wert ist ein Kommentar, der den Wert abschneidet, also quoten statt löschen.
- Geänderte GDScript-Dateien: `"$GODOT" --headless --path game --check-only --script res://<datei>` meldet Parse-Fehler (z. B. ein Block, der nur aus einem Kommentar bestand).
- `AGENTS.md`, `docs/` und `ROADMAP.md` nach Verweisen wie „Begründung am Code" oder „s. Kopf von X" auf gelöschte Kommentare durchsuchen und auf das ADR umbiegen.

Fertig, wenn `check` grün ist, die Baseline gesunken ist und die Suite so grün ist wie vorher.

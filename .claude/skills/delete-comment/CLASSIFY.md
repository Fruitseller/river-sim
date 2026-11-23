# Kommentarblöcke einordnen

Regeln für Schritt 2 von `/delete-comment`, für den ganzen Lauf oder für ein Paket `<PART>`, das ein Subagent bekommt. Beim Einordnen wird keine Repo-Datei angefasst; geschrieben wird nur nach `$S/out/<PART>/`.

## Eingabe

`$S/parts/<PART>.json` (bzw. `$S/blocks.json` bei einem Lauf ohne Pakete): Liste von Kommentarblöcken mit `id` (`pfad:zeile`, fester Schlüssel), `file`, `lines` [erste, letzte] (1-basiert), `trailing` (Kommentar hinter Code; `code` ist diese Zeile), `text` (der Kommentar) und `next_code` (die 6 Zeilen nach einem Ganzzeilen-Block). Reicht der Kontext nicht, die Quelldatei öffnen, vor allem um Tautologie von Entscheidung zu trennen und „veraltet" zu prüfen.

## Kategorien (genau eine je Block)

- `tautology`: wiederholt, was der Code schon sagt: Namen, Typen, offensichtlicher Ablauf, Abschnittsmarken wie `// MARK: - Utility`, Doc-Kommentare, die die Signatur nacherzählen.
- `stale`: nennt Code, Werte, Dateien, Issues oder Verhalten, die es nicht mehr gibt oder die nicht mehr zum Code passen. Prüfen: das genannte Symbol, die Datei, den Wert im Repo suchen.
- `excuse`: deckt einen Notbehelf: gibt eine Umgehung, Abkürzung, Doppelung, ein „vorerst" belassenes Literal, eine bekannte Ungenauigkeit, ein „TODO" oder einen Wächter zu, der einen Fehler überklebt; eine gepinnte Kopie, die aus einer Quelle kommen müsste. Die Behebung ist echte Arbeit, die jemand tun sollte.
- `decision`: hält eine wichtige, nicht offensichtliche Entscheidung fest, die ein späterer Leser braucht: warum dieser Wert oder Weg (mit Messwerten, verworfenen Alternativen, Issue-Nummern, Verweisen auf `docs/*-measurements.md`), Verträge zwischen Schichten, Reihenfolge-Zwänge, Argumente zu Determinismus und Nebenläufigkeit, physikalische Bedeutung oder Einheit, die der Name nicht trägt.
- `keep`: NUR für einen funktionalen Kommentar (eine Direktive, die ein Werkzeug liest, oder eine rechtlich nötige Lizenz- oder Herkunftsangabe). Mit Grund. Fast nie.

`decision` streng vergeben: die meisten Zeilen-Notizen sind Tautologie. Ein langer Absatz ist nicht automatisch eine Entscheidung; die Frage ist, ob ein fähiger Maintainer es ohne den Text falsch machen oder zurückbauen würde. Ist ein Block Entscheidung UND Notbehelf, gilt `excuse`, und der Entscheidungsteil geht trotzdem ins ADR (`adr` setzen).

## Ausgabe (alles in `$S/out/<PART>/`)

1. `decisions.json`: Liste mit einem Eintrag je Eingabeblock, gleiche Reihenfolge:
   `{"id": "...", "category": "...", "adr": "<slug oder null>", "issue": "<schlüssel oder null>", "why": "<≤12 Wörter>"}`.
   Jede `id` genau einmal; `adr` ist bei jeder `decision` gesetzt.

2. `adr/<slug>.md`: ADR-Entwürfe auf Deutsch, Slug in ASCII-Kleinbuchstaben mit Bindestrichen, mit Paketnamen davor (`config-gletscher-erosion.md`). Nach Entscheidung gruppieren, nicht eine Datei je Kommentar: zusammengehörige Blöcke (oft über Code, Config und Tests verteilt) werden ein ADR. Format:

   ```md
   # <Kurzer Titel der Entscheidung>

   <1–3 Sätze: Kontext, Entscheidung, Grund.>

   <Optional: Messwerte, verworfene Werte und Alternativen, Folgen.>

   Betrifft: `Symbol.name`, `andere/Datei.swift` (Funktion oder Konstante, keine Zeilennummern)
   ```

   Die Substanz verschieben, nicht wegfassen: Zahlen, Messwerte, verworfene Werte mit Grund, Issue-Verweise (#123) und Doku-Verweise (`docs/…`) bleiben. Prosa straffen, Tautologisches weglassen, keine Zeilennummern. Was im Kommentar veraltet war, steht im ADR in der richtigen Fassung.

3. `excuses.json`: Issue-Entwürfe auf Deutsch:
   `{"key": "<kurzer-schlüssel>", "ids": [...], "title": "...", "body": "..."}`.
   Ein Issue je Notbehelf (Blöcke zum selben Notbehelf zusammenlegen). Der Body sagt, was der Notbehelf ist, wo (Datei und Symbol), was der Kommentar behauptete (kurz zitiert) und wie die richtige Lösung aussähe. Ein bloß dokumentierter Zielkonflikt ist eine `decision`, kein Issue.

4. `summary.json`: `{"part": "<PART>", "counts": {"tautology": n, ...}, "adrs": n, "issues": n, "notes": "<was der Aufrufer wissen muss, z. B. ein Block, der nicht gelöscht werden darf>"}`.

Vor dem Abschluss prüfen: `decisions.json` lässt sich parsen, deckt jede Eingabe-`id` genau einmal ab, und zu jedem `adr`-Slug gibt es die Datei.

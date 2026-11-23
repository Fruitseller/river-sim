# Kommentarblöcke einordnen

Regeln für Schritt 2 von `/delete-comment`, für den ganzen Lauf oder für ein Paket `<PART>`, das ein Subagent bekommt. Beim Einordnen wird keine Repo-Datei angefasst; geschrieben wird nur nach `$S/out/<PART>/`.

## Eingabe

`$S/parts/<PART>.json` (bzw. `$S/blocks.json` bei einem Lauf ohne Pakete): Liste von Kommentarblöcken mit `id` (`pfad:zeile`, fester Schlüssel), `file`, `lines` [erste, letzte] (1-basiert), `trailing` (Kommentar hinter Code; `code` ist diese Zeile), `text` (der Kommentar) und `next_code` (die 6 Zeilen nach einem Ganzzeilen-Block). Reicht der Kontext nicht, die Quelldatei öffnen, vor allem um Tautologie von Entscheidung zu trennen und „veraltet" zu prüfen.

## Kategorien (genau eine je Block)

- `tautology`: wiederholt, was der Code schon sagt: Namen, Typen, offensichtlicher Ablauf, Abschnittsmarken wie `// MARK: - Utility`, Doc-Kommentare, die die Signatur nacherzählen.
- `stale`: nennt Code, Werte, Dateien, Issues oder Verhalten, die es nicht mehr gibt oder die nicht mehr zum Code passen. Prüfen: das genannte Symbol, die Datei, den Wert im Repo suchen.
- `excuse`: deckt einen Notbehelf: gibt eine Umgehung, Abkürzung, Doppelung, ein „vorerst" belassenes Literal, eine bekannte Ungenauigkeit, ein „TODO" oder einen Wächter zu, der einen Fehler überklebt; eine gepinnte Kopie, die aus einer Quelle kommen müsste. Die Behebung ist echte Arbeit, die jemand tun sollte.
- `decision`: hält eine Entscheidung fest, die alle drei Fragen mit Ja beantwortet: (1) schwer rückgängig zu machen (Kalibrier-Kaskade, Spielstand-Format, Schichtgrenze, Determinismus, Abhängigkeit mit Lock-in), (2) ohne Kontext überraschend, ein fähiger Maintainer würde es „reparieren“, (3) Ergebnis einer echten Abwägung mit verworfener Alternative. Typisch: Architektur und Schichtgrenzen, bewusste Abweichung vom naheliegenden Weg, Invarianten wie Bett-Funnel oder D8/MFD-Trennung, Modellwahl, Versions-Pins.
- `keep`: NUR für einen funktionalen Kommentar (eine Direktive, die ein Werkzeug liest, oder eine rechtlich nötige Lizenz- oder Herkunftsangabe). Mit Grund. Fast nie.

`decision` ist die Ausnahme. Das erste Audit fand in 5804 Blöcken 13 Entscheidungen; ein Paket mit mehr als einer Handvoll ist falsch eingeordnet. KEINE Entscheidung und damit `tautology` sind: warum eine einzelne Konstante diesen Wert hat (die Messreihe gehört nach `docs/*-measurements.md`; steht sie dort nicht, im `why` vermerken), was ein Test prüft oder wie er aufgebaut ist, Bedienung eines Skripts, alles, was `AGENTS.md`, `PLAN.md` oder `docs/` schon sagen, und eine Abwägung, die man ohne Folgekosten umdrehen könnte. Ein langer Absatz mit Zahlen ist nicht automatisch eine Entscheidung. Im Zweifel `tautology`. Ist ein Block Entscheidung UND Notbehelf, gilt `excuse`, und der Entscheidungsteil geht trotzdem ins ADR (`adr` setzen).

## Ausgabe (alles in `$S/out/<PART>/`)

1. `decisions.json`: Liste mit einem Eintrag je Eingabeblock, gleiche Reihenfolge:
   `{"id": "...", "category": "...", "adr": "<slug oder null>", "issue": "<schlüssel oder null>", "why": "<≤12 Wörter>"}`.
   Jede `id` genau einmal; `adr` ist bei jeder `decision` gesetzt.

2. `adr/<slug>.md`: ADR-Entwürfe auf Deutsch, Slug in ASCII-Kleinbuchstaben mit Bindestrichen. Erst `docs/adr/README.md` lesen: gehört die Entscheidung zu einem bestehenden ADR, ist der Entwurf ein Nachtrag dazu (Slug = Dateiname des ADR ohne Nummer). Eine Datei je Entscheidung, nie je Kommentar; zusammengehörige Blöcke (oft über Code, Config und Tests verteilt) werden ein ADR. 10–40 Zeilen. Format:

   ```md
   # <Kurzer Titel der Entscheidung>

   <1–3 Sätze: Kontext, Entscheidung, Grund.>

   <Optional: Messwerte, verworfene Werte und Alternativen, Folgen.>

   Betrifft: `Symbol.name`, `andere/Datei.swift` (Funktion oder Konstante, keine Zeilennummern)
   ```

   Ins ADR gehören Kontext, Entscheidung, Grund und die verworfenen Alternativen, die sonst jemand wieder vorschlägt, mit den Zahlen, die sie tragen, dazu Issue- und Doku-Verweise. Nicht hinein: wie der Code funktioniert, Aufruferlisten, Testbeschreibungen, Kalibrier-Notizen je Konstante. Keine Zeilennummern. Was im Kommentar veraltet war, steht im ADR in der richtigen Fassung.

3. `excuses.json`: Issue-Entwürfe auf Deutsch:
   `{"key": "<kurzer-schlüssel>", "ids": [...], "title": "...", "body": "..."}`.
   Ein Issue je Notbehelf (Blöcke zum selben Notbehelf zusammenlegen). Der Body sagt, was der Notbehelf ist, wo (Datei und Symbol), was der Kommentar behauptete (kurz zitiert) und wie die richtige Lösung aussähe. Ein bloß dokumentierter Zielkonflikt ist eine `decision`, kein Issue.

4. `summary.json`: `{"part": "<PART>", "counts": {"tautology": n, ...}, "adrs": n, "issues": n, "notes": "<was der Aufrufer wissen muss, z. B. ein Block, der nicht gelöscht werden darf>"}`.

Vor dem Abschluss prüfen: `decisions.json` lässt sich parsen, deckt jede Eingabe-`id` genau einmal ab, und zu jedem `adr`-Slug gibt es die Datei.

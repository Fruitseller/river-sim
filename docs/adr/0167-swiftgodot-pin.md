# SwiftGodot auf eine exakte Upstream-Version gepinnt

`Extension/Package.swift` hängt SwiftGodot mit `exact: "0.76.1"` an (Issue #49). Vorher stand dort `branch: "main"`: jeder frische Klon und jedes `swift package update` konnte eine andere Auflösung ziehen. Beim codegen-lastigen SwiftGodot heißt das im besten Fall rund 20 min Voll-Neubau, im schlechtesten eine still geänderte Godot-API.

0.76.1 ist genau die Revision, die zuvor schon in `Extension/Package.resolved` stand (`be57caa3e81b9ac510bc7cc2e277003c706ab0a5` == Tag `v0.76.1`). Der Pin war also kein Versionswechsel, sondern fror den Ist-Stand ein.

Angehoben wird nur bewusst und in einem eigenen Commit; das Verfahren steht in `AGENTS.md`, Abschnitt „SwiftGodot-Pin".

Betrifft: `Extension/Package.swift` (Abhängigkeit SwiftGodot), `Extension/Package.resolved`

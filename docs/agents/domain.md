# Domain-Docs

Wie die Engineering-Skills die Domänen-Dokumentation dieses Repos beim
Erkunden der Codebasis konsumieren sollen.

## Vor dem Erkunden lesen

- **`CONTEXT.md`** an der Repo-Wurzel, oder
- **`CONTEXT-MAP.md`** an der Repo-Wurzel, falls vorhanden — sie zeigt auf eine `CONTEXT.md` je Kontext. Jede für das Thema relevante lesen.
- **`docs/adr/`** — die ADRs lesen, die den Bereich berühren, in dem gearbeitet wird. In Multi-Context-Repos zusätzlich `src/<kontext>/docs/adr/` für kontext-eigene Entscheidungen prüfen.

Fehlt eine dieser Dateien, **stillschweigend weitermachen**. Ihr Fehlen nicht
anmerken und nicht vorab vorschlagen, sie anzulegen. Der Skill
`/domain-modeling` (erreicht über `/grill-with-docs` und
`/improve-codebase-architecture`) legt sie lazy an, sobald Begriffe oder
Entscheidungen tatsächlich geklärt werden.

## Dateistruktur

Single-Context-Repo (die meisten Repos, **auch dieses**):

```
/
├── CONTEXT.md
├── docs/adr/
│   ├── 0001-event-sourced-orders.md
│   └── 0002-postgres-for-write-model.md
└── src/
```

Multi-Context-Repo (erkennbar an `CONTEXT-MAP.md` an der Wurzel):

```
/
├── CONTEXT-MAP.md
├── docs/adr/                          ← systemweite Entscheidungen
└── src/
    ├── ordering/
    │   ├── CONTEXT.md
    │   └── docs/adr/                  ← kontext-eigene Entscheidungen
    └── billing/
        ├── CONTEXT.md
        └── docs/adr/
```

## Das Vokabular des Glossars verwenden

Wenn eine Ausgabe einen Domänenbegriff nennt (in einem Issue-Titel, einem
Refactoring-Vorschlag, einer Hypothese, einem Testnamen), den Begriff so
verwenden, wie er in `CONTEXT.md` definiert ist. Nicht auf Synonyme
ausweichen, die das Glossar ausdrücklich vermeidet.

Fehlt der benötigte Begriff im Glossar, ist das ein Signal — entweder wird
gerade Sprache erfunden, die das Projekt nicht verwendet (überdenken), oder es
gibt eine echte Lücke (für `/domain-modeling` notieren).

## ADR-Konflikte benennen

Widerspricht eine Ausgabe einem bestehenden ADR, das explizit benennen statt
stillschweigend zu übergehen:

> _Widerspricht ADR-0007 (event-sourced orders) — aber ein Wiederaufrollen lohnt, weil …_

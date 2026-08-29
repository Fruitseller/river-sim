# Issue-Tracker: GitHub

Issues und PRDs für dieses Repo leben als GitHub Issues. Für alle Operationen
die `gh`-CLI verwenden.

## Konventionen

- **Issue anlegen**: `gh issue create --title "..." --body "..."`. Für mehrzeilige Bodies ein Heredoc verwenden.
- **Issue lesen**: `gh issue view <nummer> --comments`, Kommentare per `jq` filtern und die Labels mit abrufen.
- **Issues auflisten**: `gh issue list --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'` mit passenden `--label`- und `--state`-Filtern.
- **Issue kommentieren**: `gh issue comment <nummer> --body "..."`
- **Labels setzen / entfernen**: `gh issue edit <nummer> --add-label "..."` / `--remove-label "..."`
- **Schließen**: `gh issue close <nummer> --comment "..."`

Das Repo ergibt sich aus `git remote -v` — `gh` leitet es innerhalb eines Klons
automatisch ab.

## Pull Requests als Triage-Oberfläche

**PRs als Request-Oberfläche: nein.** _(Auf `yes` stellen, wenn dieses Repo
externe PRs als Feature-Requests behandelt; `/triage` liest dieses Flag.)_

Steht das Flag auf `yes`, durchlaufen PRs dieselben Labels und Zustände wie
Issues, mit den `gh pr`-Entsprechungen:

- **PR lesen**: `gh pr view <nummer> --comments` und `gh pr diff <nummer>` für den Diff.
- **Externe PRs für die Triage auflisten**: `gh pr list --state open --json number,title,body,labels,author,authorAssociation,comments`, dann nur `authorAssociation` von `CONTRIBUTOR`, `FIRST_TIME_CONTRIBUTOR` oder `NONE` behalten (`OWNER`/`MEMBER`/`COLLABORATOR` verwerfen).
- **Kommentieren / labeln / schließen**: `gh pr comment`, `gh pr edit --add-label`/`--remove-label`, `gh pr close`.

GitHub teilt einen Nummernraum zwischen Issues und PRs; ein nacktes `#42` kann
also beides sein — mit `gh pr view 42` auflösen und auf `gh issue view 42`
zurückfallen.

## Wenn ein Skill sagt „publish to the issue tracker"

Ein GitHub Issue anlegen.

## Wenn ein Skill sagt „fetch the relevant ticket"

`gh issue view <nummer> --comments` ausführen.

## Wayfinding-Operationen

Genutzt von `/wayfinder`. Die **Map** ist ein einzelnes Issue mit
**Kind**-Issues als Tickets.

- **Map**: ein einzelnes Issue mit Label `wayfinder:map`, das den Body mit Notes / Decisions-so-far / Fog hält. `gh issue create --label wayfinder:map`.
- **Kind-Ticket**: ein Issue, das als GitHub-Sub-Issue mit der Map verknüpft ist (`gh api` auf dem Sub-Issues-Endpoint). Wo Sub-Issues nicht verfügbar sind, das Kind in eine Task-Liste im Map-Body eintragen und `Part of #<map>` an den Anfang des Kind-Bodys stellen. Labels: `wayfinder:<typ>` (`research`/`prototype`/`grilling`/`task`). Sobald beansprucht, wird das Ticket dem treibenden Dev zugewiesen.
- **Blockierung**: GitHubs **native Issue-Dependencies** — die kanonische, in der UI sichtbare Darstellung. Eine Kante anlegen mit `gh api --method POST repos/<owner>/<repo>/issues/<kind>/dependencies/blocked_by -F issue_id=<blocker-db-id>`, wobei `<blocker-db-id>` die numerische **Datenbank-Id** des Blockers ist (`gh api repos/<owner>/<repo>/issues/<n> --jq .id`, _nicht_ die `#nummer` oder `node_id`). GitHub meldet `issue_dependencies_summary.blocked_by` (nur offene Blocker — das lebende Gate). Wo Dependencies nicht verfügbar sind, als Fallback eine Zeile `Blocked by: #<n>, #<n>` an den Anfang des Kind-Bodys. Ein Ticket ist entblockt, wenn jeder Blocker geschlossen ist.
- **Frontier-Abfrage**: die offenen Kinder der Map auflisten (`gh issue list --state open`, eingeschränkt auf die Sub-Issues / Task-Liste der Map), alle mit offenem Blocker (`issue_dependencies_summary.blocked_by > 0`, oder ein offenes Issue in der `Blocked by`-Zeile) oder mit Assignee verwerfen; das erste in Map-Reihenfolge gewinnt.
- **Beanspruchen**: `gh issue edit <n> --add-assignee @me` — der erste Schreibzugriff der Session.
- **Auflösen**: `gh issue comment <n> --body "<antwort>"`, dann `gh issue close <n>`, dann einen Kontext-Verweis (Gist + Link) an die Decisions-so-far der Map anhängen.

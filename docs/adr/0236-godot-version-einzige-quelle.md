# Godot-Version und Prüfsummen stehen nur in scripts/fetch-godot.sh

CI und Arbeitsplatz benutzen dieselbe Godot-Binärdatei. Die Godot-Version ist Teil des Vertrags, den `game/tests/` prüft; läuft CI gegen eine andere Version als der Entwickler, beweist ein grüner Lauf nichts über den lokalen Stand. `scripts/fetch-godot.sh` ist deshalb die einzige Quelle der Version; `scripts/start.sh`, `scripts/godot-test.sh`, `scripts/timelapse-timing.sh` und CI lesen sie über `fetch-godot.sh --path` bzw. `$GODOT` und doppeln sie nicht. In `ci.yml` steht die Version bewusst nicht im Klartext.

Beim Anheben werden Version und beide Prüfsummen zusammen getauscht, danach läuft `game/tests/` einmal komplett, weil die Tests Godot-Verhalten pinnen.

Zwei Prüfsummen: `GODOT_SHA256` prüft das offizielle Release-Archiv (github.com/godotengine/godot), vor dem Entpacken, damit eine manipulierte oder abgeschnittene Datei gar nicht erst in `.tools/` landet. `GODOT_BIN_SHA256` prüft die entpackte Binärdatei. Der zweite Hash ist nötig, weil in CI der Cache-Hit der Normalfall ist: `actions/cache` füllt `.tools/`, der Cache-Key hängt nur am Versions-Tag, und es wird nichts heruntergeladen. Ohne Binär-Hash liefen die Vertragstests dann still gegen eine veraltete oder untergeschobene Binärdatei. Kostet ~0,1 s. Nach dem Entpacken wird der Binär-Hash auf demselben Weg geprüft wie später beim Cache-Restore, damit er ehrlich bleibt.

Bei Abweichung einer vorhandenen Binärdatei gibt es absichtlich keinen stillen Neu-Download: ein untergeschobener Cache-Eintrag soll den Lauf rot machen, nicht heimlich repariert werden.

Aufrufe: `fetch-godot.sh` lädt bei Bedarf, prüft (auch eine vorhandene Datei) und gibt den Pfad auf stdout aus; `--path` gibt nur den Pfad aus, ohne Laden und Prüfen. Fortschritt und Fehler gehen nach stderr, damit `GODOT="$(scripts/fetch-godot.sh)"` funktioniert.

Betrifft: `scripts/fetch-godot.sh` (`GODOT_VERSION`, `GODOT_SHA256`, `GODOT_BIN_SHA256`, `verify_binary`), `scripts/start.sh`, `scripts/godot-test.sh`, `.github/workflows/ci.yml` (Godot-Schritte)

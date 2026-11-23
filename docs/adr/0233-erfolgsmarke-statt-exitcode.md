# Godot-Läufe werden an der Erfolgsmarke gewertet, nicht am Exit-Code

Godot 4.7.1 reißt auf dem ubuntu-22.04-Runner sporadisch beim Herunterfahren ab (Signal 6/11, Exit 139), nachdem das Skript alle Prüfungen bestanden, seine Marke gedruckt und `quit(0)` gerufen hat (#61). Gewertet wird deshalb die Erfolgsmarke des Skripts.

Befund aus dem Diagnose-Lauf 31898601044 (Commit db4f93a, Diagnose-Schritte wieder entfernt): der erste Import in ein frisches `game/.godot` stürzt beim Herunterfahren ab, nachdem alle Import-Phasen „DONE" gemeldet haben und `extension_list.cfg` geschrieben ist. gdb-Backtrace: Abort in Thread 1 im Godot-Binary, kein Extension-Frame, Worker-Threads in futex. Dieselbe Binärdatei importiert ohne die `.so` sauber (Exit 0), der zweite Import mit warmem `.godot` läuft sauber, ebenso alle folgenden Skript-Läufe. Lokal (Debian 13) tritt der Absturz nicht auf. Am 2026-08-27 traf derselbe Absturz erstmals einen Vertragstest: Lauf 33123585937 druckte `WATER_GEOMETRY_OK` und starb 1,4 s später mit Exit 139, derselbe Commit lief auf seinem Branch (Lauf 33118130758) sauber.

Regeln:
- Import: bis zu drei Versuche statt `continue-on-error`; schlagen alle fehl, ist der Job rot. Jeder folgende Schritt lädt die Extension wirklich, der Vertrag bleibt also wirksam.
- `scripts/godot-test.sh <res://…gd> <MARKE>`: Marke gedruckt heißt bestanden (bei Exit ≠ 0 mit lauter Warnung), Marke fehlt heißt rot mit dem Exit-Code der Engine. Ein Absturz mitten im Test und jedes `quit(1)` bleiben rot; nur das Aufräumen nach dem bestandenen Test darf scheitern. Wiederholen statt werten wäre schwächer: es versteckt wackelige Tests und verlängert den Lauf um deren volle Laufzeit.
- Die Marke wird irgendwo in der Ausgabe gesucht, nicht als letzte Zeile, weil die Engine nach `quit(0)` noch selbst schreibt. Als zweiter Wächter macht jedes `FAIL…:` (`FAIL: …`, `FAIL_PHYSICS: …`) im Log den Lauf rot, auch wenn die Marke dasteht. Der Vergleich ist ungeankert, weil Skripte teils mit `print`, teils über `push_error` (mit Godot-Präfix) melden.
- Jedes Skript unter `game/tests/` druckt seine Marke wortwörtlich und ohne Leerzeichen als letzte Zeile vor `quit(0)` und meldet Fehlschläge vorher mit `FAIL: …` und `quit(1)`.
- `godot-test.sh` läuft ohne `set -e`: der Exit-Code der Engine wird ausgewertet, nicht befolgt.
- Alle Skript-Läufe des CI-Jobs gehen über `godot-test.sh`, als getrennte Schritte statt Schleife, damit die GitHub-Oberfläche zeigt, welcher Vertrag gebrochen ist.
- Dieselbe Regel gilt in `scripts/graphics-matrix.sh`: gewertet werden das Bild bzw. die Timing-Zeile, nicht der Exit-Code, sonst bräche ein Abschluss-Absturz die restliche Matrix ab.

Betrifft: `scripts/godot-test.sh`, `.github/workflows/ci.yml` (Import-Schritt, Vertragstest-Schritte), `game/tests/*.gd` (Erfolgsmarken), `scripts/graphics-matrix.sh`

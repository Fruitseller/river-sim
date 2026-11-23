# Godot-Import ist Pflicht, bevor die GDExtension geladen wird

Godot lädt GDExtensions ausschließlich aus `game/.godot/extension_list.cfg`, und die entsteht erst beim Projekt-Import. `game/.godot/` ist gitignoriert und fehlt in jedem frischen Klon, Worktree und CI-Checkout. Ohne Import bleibt `SimNode` unregistriert, obwohl `game/bin/` korrekt gefüllt ist.

CI führt deshalb einen eigenen Import-Schritt vor allen Vertragstests aus. `smoke.gd` prüft die Datei zuerst und nennt den Import-Befehl, weil die Fehlermeldung sonst auf die Library statt auf den fehlenden Import zeigt; das ist die häufigste Ursache in einem frischen Arbeitsverzeichnis.

Betrifft: `.github/workflows/ci.yml` (Schritt „Godot-Projekt importieren"), `game/tests/smoke.gd`

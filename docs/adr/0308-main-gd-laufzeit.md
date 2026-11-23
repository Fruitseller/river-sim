# Main.gd: Renderloop im Leerlauf aus, Pinselstrich sperrt Sim-Schritte

Ein FPS-Deckel reicht im Pausezustand nicht: auch 30 Retina-Frames pro Sekunde lasten die GPU aus, obwohl sich die Welt nicht ändert. Nach der Leerlauffrist schaltet `Main.gd` den Renderloop ganz ab und bei der nächsten Eingabe wieder ein. Fensterleisten-Aktionen (Maximieren, Resize) erzeugen kein InputEvent und brauchen einen eigenen Weckruf, sonst steht das eingefrorene Pausebild skaliert im neuen Fenster, ausgerechnet beim Maximieren fürs Messprozedere.

Der Leerlauf-Ausstieg (`if idle: return`) muss nach dem Renderloop-Umschalter stehen (sonst würde nie suspendiert) und vor dem Sim-Schritt (sonst steppte die Pause unsichtbar weiter). Der Wächter prüft whitespace-tolerant, weil eine kosmetische Umformatierung kein Vertragsbruch ist.

Der Pinsel lädt seine Höhe sofort hoch und zieht das globale Flussnetz selbst nach. Ein paralleler `sim.step` würde dieselben Zellen davor weiterentwickeln und bei 60 J/s Wirkung und Hauptthreadzeit streitig machen. Deshalb sperren aktive Striche die Sim-Schritte; die Tempowahl bleibt stehen.

Betrifft: `game/scripts/Main.gd` (Leerlauf-Logik, Pinselstrich), `RenderContractTests.testPausedIdleDisablesRenderLoop`, `RenderContractTests.testSculptingOwnsTheSimulationClock`

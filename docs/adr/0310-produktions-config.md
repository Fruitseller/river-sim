# Eine Produktions-Config, auf beiden Brücken-Wegen mit Einlauf

`SimConfig.production` ist der eine benannte Wert für die Produktion (Issue #97): genau `SimConfig()` plus die zwei Laufzeit-Schalter. Vorher stand dieselbe Zwei-Zeilen-Abweichung in sechs handgepflegten Kopien; die Brücke war die einzige davon, die headless nicht ausführbar ist, also die einzige, die still driften konnte. Der Wächter prüft deshalb ihren Quelltext auch auf die Abwesenheit einer eigenen Fassung (etwa ein neues `config.hydraulicSkipWaterSpawns = …`). Die ausführbare Gegenseite verlangt, dass keine dritte Abweichung hineinrutscht: sonst führe die Produktion eine andere Physik als jede Kalibrierung und jeder Test, und die Kopfzeile des Mess-Harness behauptete weiter, sie zu spiegeln.

Der Produktions-Einlauf der Generierung (PR #106, `Terrain.generate(seed:settleYears:)`) muss auf beiden Brücken-Wegen hängen, Start-Terrain und „Neues Terrain"-Knopf. Fehlte er auf einem, bekämen Spieler aus demselben Seed zwei verschiedene Welt-Klassen.

SimCore-Quellen und Mess-Harness dürfen nicht mehr auf die entfernten Brücken-Properties `SimNode.generationSettleYears` und `SimNode.productionConfig` verweisen. Dieser Wächter prüft bewusst den Rohtext inklusive Doc-Kommentaren: ein veralteter Kommentar in `Terrain.generate` war der erste Drift-Fall.

Betrifft: `SimConfig.production`, `SimConfig.productionSettleYears`, `Terrain.generate(seed:settleYears:)`, `Extension/Sources/RiverSimGD`, `RenderContractTests.testBridgeReadsTheOneProductionConfig`, `RenderContractTests.testBothBridgeGeneratePathsSettle`

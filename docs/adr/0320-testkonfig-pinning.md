# Mäander-Testkonfigs pinnen die alte Kalibrierung

Die isolierten Mäander-Kopplungstests (`meanderCfg`) prüfen die Kopplungs-Mechanik (Carve, Altarm-See, Altern) mit Grid-Erosion ohne Droplet-Rauschen und pinnen die Werte, gegen die sie kalibriert wurden. Produktion nutzt inzwischen kleinere Migration und größeren Cutoff-Hals; das Pinnen hält Test- und Produktions-Kalibrierung entkoppelt (AGENTS.md, „Drei Konfigurations-Ebenen"). Nicht aufräumend an Produktionswerte angleichen.

Gepinnt bzw. neutralisiert in `meanderCfg`:
- Migration 5.0e-5, Hals 1.2.
- Ufer-Kohäsion (Stufe 2) aus: die Tests prüfen die reine Kopplungs-Mechanik.
- Mäandergürtel (#174) aus: gepinnt ist die Zentrumslinien-Mechanik davor (Migration ∝ Krümmung × Abfluss, Ein-Zellen-Ufer).
- Konstante aktive Tektonik statt der abklingenden Produktions-Hebung (#13): die Grid-Variante ohne Droplet braucht dauerhaften Relief-Nachschub für die Altarm-Alterung, und jede Änderung an U₀/τ verschöbe sonst die Kopplungs-Mechanik mit.
- Uniformes Gestein: mit dem Gesteinsfeld (#12) liefe `transportLimited` auf räumlich variablem kRock, und die Härte des Streifens unter dem Testlauf verschöbe Carve-Tiefen und Altarm-Alterung. Das Gesteinsfeld hat eigene Wächter.

Die Langlauf-Wächter (`prodMeanderCfg`) laufen dagegen auf reinen Produktions-Defaults, nur n gesenkt (192 fürs Tempo, ~2,5 s je 100k Jahre in release): die gepinnten Alt-Werte sind seit `meanderEnabled = true` nicht mehr der Pfad, der real läuft, und Langzeit-Stabilität muss auf dem echten Pfad (Droplet + Sinuositäts-Deckel + Hals 2.0) gemessen werden. Auch dort gepinnt, weil sie die Realisierung verschieben, ohne die Mäander-Mechanik zu ändern:
- Mäandergürtel vor #174.
- Delta-Schüttung (#174, Punkt 26): mit ihr endete `testMeanderOxbowSiltsUp` bei 40 von Peak 54 Altarmen (Kriterium < 70 %).
- Lawinen-Abgang des Firns (#174): 20 frische Altarm-Betten statt > 20 (`TestCalibration`).

Die Kernel-Geometrie-Tests (`kernelCfg`) nutzen eine moderate Migrationsrate 6.0e-6: der voll-mobile synthetische Lauf würde bei der Produktionsrate verknäueln; im Terrain hält ihn das Mobilitäts-Gate zahm.

Betrifft: `SimCoreTests.meanderCfg`, `SimCoreTests.prodMeanderCfg`, `SimCoreTests.kernelCfg`, `calibrationMeanderBelt`, `calibrationDeltaTrapFraction`, `SimConfig.pinIceBeforeAvalanche`, `TestCalibration.swift`

# Klassische Mäander-Migration: Rate, Halsbreite und Ufer-Kohäsion

Die Lagrange-Zentrumslinien (vor dem Gürtel aus #174, weiter Basis für die Kopplungstests) sind auf die Produktion abgestimmt; die Mäander-Kern-Tests pinnen ihre alten Werte in `meanderCfg()`.

- `meanderMigration` 8,0e-6 (kMig, laterale Rate ∝ Krümmung × Abfluss), von 5e-5 gesenkt: bei den großen Produktions-Einzugsgebieten tangelte 5e-5 die Läufe (Sinuosität-Max 7 … 26); 8e-6 gibt hübsche Mäander (Mittel ~2). Kalibriert auf n = 640 ohne Hebung.
- `meanderNeckDist` 2,0 Zellen, von 1,2 erhöht: Schlingen schnüren früher ab, die Sinuosität wird niedriger gedeckelt (weniger Knäuel). Kern-Tests pinnen 1,2.
- `meanderCohesion` 0,5: Verschiebung je Knoten × (1 − meanderCohesion · mittleres Auwald-veg im Ufer-Streifen ±`meanderBankWidth`). Voll bewachsene Ufer (Streifen-Mittel ~0,5) migrieren ~25 % langsamer, kahle Reaches wie bisher. 1,0 fror bewaldete Läufe im Kohäsions-Test fast ein (Faktor bis 0,5 auf dem ganzen Lauf), zu starr, Mäander-Dynamik ist der Kern des Projekts. Kern-Tests pinnen 0.

Betrifft: `SimConfig.meanderMigration`, `SimConfig.meanderNeckDist`, `SimConfig.meanderCohesion`, `SimCoreTests.meanderCfg`

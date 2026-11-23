# Architektur-Entscheidungen

Hier stehen nur Entscheidungen, die schwer rückgängig zu machen sind, ohne Kontext überraschen und
aus einer echten Abwägung kamen (alle drei). Kalibrier-Notizen gehören in `docs/*-measurements.md`,
Bedienung in `AGENTS.md`, was der Code selbst sagt, nirgendwohin.
Format: Titel, ein bis drei Sätze Kontext, Entscheidung und Grund, danach Messwerte und verworfene
Alternativen, am Ende `Betrifft:` mit den Symbolen im Code. Neue ADRs bekommen die nächste freie Nummer.

## Architektur und Invarianten

- [0001 Keine Kommentare im Code](0001-keine-code-kommentare.md)
- [0002 Zwei Entwässerungsnetze: D8 für die Erosion, MFD für Render und Braiding](0002-entwaesserung-d8-mfd.md)
- [0003 Ein Bett-Funnel für alle Bett-Schreiber, mit Gletscher-Gate](0003-bett-funnel.md)
- [0004 Performance nur bit-identisch: disjunkte Parallelität, Roh-Puffer, Vorab-Rechnung](0004-performance-bit-identisch.md)
- [0005 Framerate-Unabhängigkeit: Relaxation, Schritt-Deckel, Tropfen-Strom](0005-dt-invarianz.md)
- [0006 Drei Konfigurations-Ebenen; n und world nur gemeinsam](0006-konfigurationsebenen.md)

## Sim-Modell

- [0007 Großform: fertiges Gebirge am Orogenese-Höhepunkt, danach abklingende Hebung](0007-grossform-und-alterung.md)
- [0008 Klima-Vertikale und Höhenzonen: Schneebilanz aus der Temperatur, Zonen als Quantile](0008-klima-und-hoehenzonen.md)
- [0009 Abflussgewicht aus Regen und Schmelze als renormierte Umverteilung](0009-abflussgewicht.md)
- [0010 Gletscher: Flux-Erosion mit linearem, sub-getaktetem Eistransport (Issue #35)](0010-gletscher-modell.md)
- [0011 Abflusslose Becken: Seespiegel aus dem Wasserhaushalt](0011-endorheische-becken.md)
- [0012 Mäander: Lagrange-Zentrumslinien als Howard–Knutson-Gürtel, gekoppelt an D8](0012-maeander.md)

## Darstellung und Werkzeuge

- [0013 Compute-Pässe auf der GPU nur für die Darstellung, mit Rückfall ohne RenderingDevice](0013-gpu-darstellung.md)
- [0014 Toolchains und Abhängigkeiten exakt gepinnt, mit Prüfsumme, je eine Quelle](0014-pins.md)

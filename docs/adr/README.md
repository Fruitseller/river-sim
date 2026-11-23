# Architektur-Entscheidungen

Hier stehen nur Entscheidungen, die schwer rückgängig zu machen sind, ohne Kontext überraschen und
aus einer echten Abwägung kamen (alle drei). Kalibrier-Notizen gehören in `docs/*-measurements.md`,
Bedienung in `AGENTS.md`, was der Code selbst sagt, nirgendwohin.
Format: Titel, ein bis drei Sätze Kontext, Entscheidung und Grund, danach Messwerte und verworfene
Alternativen, am Ende `Betrifft:` mit den Symbolen im Code. Neue ADRs bekommen die nächste freie Nummer.

## Architektur und Invarianten

- [0001 Keine Kommentare im Code](0001-keine-code-kommentare.md)
- [0002 Zwei Entwässerungsnetze: D8 für Erosion, MFD für Render und Braiding](0002-zwei-entwaesserungsnetze.md)
- [0003 Ein Bett-Funnel für alle Bett-Schreiber, mit Gletscher-Gate](0003-bett-funnel.md)
- [0004 Datenparallelität nur über disjunkte Bereiche, ein zentraler unsafe-Engpass](0004-parallel-determinismus.md)
- [0005 Framerate-Unabhängigkeit: Relaxation, Schritt-Deckel, Tropfen-Strom](0005-dt-invarianz.md)
- [0006 Braiding nach Murray & Paola mit Superlinearität auf der Partition](0006-braiding.md)
- [0007 Spielstand: vollständiges Zustands-Inventar, eigenes Binärformat, keine Migration](0007-spielstand.md)
- [0008 Produktions-Konfiguration als ein benannter Wert über dem Core-Default](0008-produktions-konfiguration.md)
- [0009 Heiße Pässe auf Roh-Puffern, unveränderliche Anteile vorab und parallel](0009-roh-puffer.md)

## Sim-Modell

- [0010 Gitter 720 / Welt 112,4789: n und world nur gemeinsam ändern](0010-gitter-und-weltgroesse.md)
- [0011 Großform: ein Gebirgskamm als Skelett, vor-erodiert, mit Randabstand](0011-grossform.md)
- [0012 Abklingende Hebung ab dem Orogenese-Höhepunkt als Alterungs-Mechanismus (Issue #13)](0012-abklingende-hebung.md)
- [0013 Lithologie: Härte hängt an der Höhe, nicht an der Zelle](0013-lithologie.md)
- [0014 Höhenbänder als Quantile der Landhöhen, Schnee aus dem Schneefeld](0014-hoehenbaender.md)
- [0015 Klima-Vertikale: Temperaturfeld und Schneedecke als Massenbilanz (Issue #33)](0015-klima-schnee.md)
- [0016 Abflussgewicht aus Regen und Schmelze als renormierte Umverteilung](0016-abflussgewicht.md)
- [0017 Gletscher: Flux-Erosion mit linearem, sub-getaktetem Eistransport (Issue #35)](0017-gletscher-modell.md)
- [0018 Abflusslose Becken: Seespiegel aus dem Wasserhaushalt](0018-endorheische-becken.md)
- [0019 Mäander als Lagrange-Zentrumslinien, migriert als Gürtel nach Howard–Knutson](0019-maeandermodell.md)
- [0020 Gürtel-Linien gekoppelt an die D8-Entwässerung, eine Trasse nach Hack](0020-guertel-kopplung.md)

## Darstellung

- [0021 Fluss-Korridor: Deckel-Tiefe statt abgesenktem Gelände, Mindestbreite in der Totalen](0021-korridor-deckel.md)
- [0022 Einzelbäume über einen Compute-Pass statt fester Instanzen](0022-einzelbaeume-compute.md)
- [0023 Gelände-Verfeinerung auf der GPU: nur Darstellung, Takt und Geschmackswerte](0023-gelaende-verfeinerung.md)

## Werkzeuge, Tests und Pins

- [0024 Mechanik-Wächter pinnen Zellgröße und Großform ihrer Kalibrierung](0024-pin-doktrin.md)
- [0025 Mess-Harness `simperf`: Produktions-Config, eigener Einlauf](0025-simperf-harness.md)
- [0026 SwiftGodot auf eine exakte Upstream-Version gepinnt](0026-swiftgodot-pin.md)
- [0027 Toolchains gepinnt: Swift per Direktdownload mit Prüfsumme, Godot aus einer Quelle](0027-toolchain-pins.md)

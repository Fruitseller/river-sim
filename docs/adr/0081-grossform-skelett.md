# Großform der Generierung als Skelett aus Kamm, Seitenästen und Tälern

Issue #174, Paket A: ein Gebirgskamm statt einer gleichmäßigen Gratfläche, Tieflandkorridore vom Kamm zur Küste. Vorher legte `generate()` `ridged01`-Grate über die ganze Landfläche; ein Massiv-Rauschen modulierte nur die HÖHE, nicht die FORM. Auch das „Tiefland" war gratig, nur niedriger, und zerfiel in 12–24 Flecken (`docs/zielbild-measurements.md`).

Die Form liegt als Skelett aus Polylinien in Gitterkoordinaten (`RangeSkeleton`):

- Kammachse je Seed (gekrümmt) plus zwei bis drei Seitenäste. Mit dem Abstand zum Skelett blendet das Relief von Graten (`mountain`) über sanfte Hügel (`hill`) auf die flache Küstenebene über, als Distanzfeld zur Achse, nicht als Radius um den Inselmittelpunkt. Gebirge bis etwa R (`halfWidth`), Hügelland bis etwa 3,6 R. Eine freie Ebene zwischen Kamm und Küste wäre ein Kegel, von dem viele kleine Läufe parallel zur Küste rinnen, statt sich in den Tälern zu sammeln (gemessen am ersten Entwurf mit 2,4 R).
- Zwei bis vier Haupttäler laufen vom Kammfuß zur Küste und weiten sich zum Meer hin auf. Im Tal (`corridor`) treten Grate und Hügel zurück; die Talsohle steigt zum Talschluss sanft an (`rise`), mit einem Gefälle weit unter der Mäander-Schwelle. Die Polylinien reichen über den Gitterrand hinaus; das Meer beendet die Täler.

Reine Generierungs-Geometrie: kein Sim-Zustand, nichts davon reist im Spielstand (die daraus entstehenden Felder `h` und `upliftBase` tun es).

Betrifft: `RangeSkeleton`, `RangeSkeleton.evaluate`, `Terrain.generate`, `SimConfig.rangeLandform`

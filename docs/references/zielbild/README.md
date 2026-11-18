# Zielbild (Look-Vorlagen)

Konzeptbilder des Projekteigners vom 11. Oktober 2026, Vorlage für das
Zielbild-Issue „Aussehen und Flussdynamik auf Vorlagen-Niveau". Es sind
KI-generierte Konzeptbilder, keine Renderings dieser Anwendung. Sie zeigen
Bildwirkung und Bedienung, keine messbare Physik. Was davon bewusst NICHT
übernommen wird (Fantasie-Beschriftungen, Einzelbäume im Kilometermaßstab,
FPS-Anzeige), steht im Issue.

| Datei | Zeigt |
| --- | --- |
| `a-tal-kueste-pinsel.jpg` | Schräge Nahsicht: Felswände mit Schutthalden, Nadelwald an den Hängen, Fluss mit Kiesbänken bis zur Küste, Sedimentfahne im Meer, 3D-Pinsel als Gitterkuppel |
| `b-flusstal-delta-ui.jpg` | Mäandrierender Hauptfluss in breiter Aue, Gleithang-Sandbänke, Altarme, Delta mit Sandinseln, vergletscherte Gipfel, Wolken; Glas-UI (Titel/Jahr/Tempo oben links, Werkzeuge links, Speichern/Laden unten rechts) |
| `c-insel-diorama-ui.jpg` | Ganze Insel als Diorama: Gebirgskamm mit Schnee, Tieflandflüsse mit Mäandern und Deltas, Seen, Strände; UI mit Werkzeug-Icons links, Zeitsteuerung oben rechts, Seed unten rechts |

Zwei weitere Vorlagen aus derselben Nachricht liegen wegen unklarer Rechte
nicht im Repo und sind im Issue in Worten beschrieben: ein Luftbild eines
arktischen Mäanderflusses (Scroll-Bars, Altarme, helle Gleithang-Bänke) und
eine Lehrbuch-Skizze zu Prallhang/Gleithang mit asymmetrischen Querprofilen.

## Aufgehübschte Spielbilder (Hill-Climber-Referenz, 18. November 2026)

Echte Aufnahmen dieser Anwendung (Seed 1337, Jahr 20.000, maximiert, ohne UI),
vom Projekteigner mit ChatGPT aufgehübscht. Anders als a–c zeigen sie UNSERE
Welt, nur schöner dargestellt. Sie sind der Maßstab für den visuellen
Hill-Climber (blinder Paarvergleich durch ein Bewertungsmodell).

| Datei | Rolle | Zeigt |
| --- | --- | --- |
| `d-insel-diorama-schoen.jpg` | **Formziel** (Kamera F1, Diorama) | Aufbau wie im Spiel: Kamm mit Schnee in Rinnen, mäandrierender Hauptfluss, Delta rechts. Wasser liegt eingeschnitten im Gelände, Wald als Flächen mit Lichtungen, Fels mit Graten, Brandungssaum, türkiser Flachwasserverlauf, tiefe warme Sonne, Dunst |
| `e-tal-kueste-schoen.jpg` | **nur Material und Licht**, KEIN Formziel | Wasserfarbe, Strände, Wald, Fels, Licht. Die Formen sind frei erfunden (fast senkrechte Fjordwände, physikalisch unmögliche Parallel-Flüsse) und weder vom Höhenfeld noch von der Erosion erreichbar; ein Bewerter vergleicht hier keine Formen |
| `f-nah-flussschleife-schoen.jpg` | **Darstellungsziel** Nahsicht (`RS_STEP=20000 RS_TARGET=17,10 RS_PITCH=0.55 RS_YAW=0 RS_DIST=16`) | Eingeschnittenes Flussbett mit Ufer, Kiesbänke, Stromschnellen, Wald als Gruppen, Felsrippen statt Knete, Brandung. Die Flussläufe hat das Bildmodell fast unverändert übernommen; ihre unnatürliche Führung (Schlingen, die fast Ringe bilden, Parallel-Arme, ein Lauf entlang der Küste) stammt aus der Simulation. Der Bewerter belohnt sie deshalb NICHT als Ziel |

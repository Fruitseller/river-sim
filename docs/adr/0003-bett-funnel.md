# Ein Bett-Funnel für alle Bett-Schreiber, mit Gletscher-Gate

Die Bett-Regel (erst Sediment, dann Fels abtragen; `h = rock + sed` halten) und das Gletscher-Gate stehen genau einmal, in `Terrain.Bed.erode`/`deposit` (Issues #81, #96). Jede Bett-Schreibung läuft darüber, auch die Tropfenschleife, damit ein künftiger Bett-Pass Regel und Gate nicht vergessen kann. Bis #81 gab es eine zweite, von Hand synchron gehaltene Ausschreibung, bis #96 stand das Gate in der Tropfenschleife und in der Gate-Kette der Auslass-Inzision ausgeschrieben.

Gletscher-Gate (#35): unter dem Eis gehört das Tal dem Gletscher, kein fluvialer Abtrag und keine fluviale Ablage, sonst carvt dasselbe Tal ein zweites Mal mit fluvialem statt glazialem Querschnitt. Bei leerer Maske fällt der Zweig weg, eine eisfreie Welt rechnet bit-identisch zum Stand vor #35. Der Pinsel ist bewusst keine Ausnahme: ein Hieb auf vergletschertem Grund bleibt wirkungslos.

Die Tropfen sperren stärker: Eis ∪ Gürtelbett (`beltDropletGate`, #174/#187), weil ihr Radial-Pinsel das Bett wandernder Mäanderläufe nicht aufreißen darf, und Schutt auf einer Eisoberfläche ist kein Sediment im Bett. Der nicht abgelegte Rest bleibt in Suspension und erreicht das Bett erst hinter der Sperre, physisch der Sander am Gletschertor. Was mit nicht abgelegter Fracht geschieht, entscheidet der Aufrufer (Terrain-Funnel: exportiert, Masse-Erhaltung ist keine Invariante).

Ausnahmen, die bewusst auch auf vergletscherten Zellen schreiben: Hangdiffusion und Brandung. Beides ist kein fluvialer Abtrag; ein Abschalten am Gate ließe den Trog mit unbehandelten Kanten zurück (`docs/glacier-measurements.md` §I.1), dieselbe Begründung trägt die Brandung an der Fjordküste. Das Eis schreibt sein Bett mit eigenem Erosionsgesetz (`updateIce`). `fillShallowPonds` schreibt `h`/`sed` direkt und prüft das Eis selbst.

Ziel-Fassung `erodeCellTo`: Relaxations-Pässe wie die Auslass-Inzision rechnen eine eigene Zielhöhe. Der naive Weg `h −= (h − hNew)` weicht im aggressiven Regime (Schritt trägt mehr als die halbe Höhe ab) in der Mehrheit der Fälle um 1 ulp ab; die Ziel-Fassung setzt die Zielhöhe deshalb exakt.

`Bed` ist eine Roh-Puffer-Sicht auf `h`/`sed`/`rock` plus Sperrmaske: über die Klassen-Property kostete der Zugriff gemessen ~4,5 % des Schritts allein in der Swift-Laufzeit (`swift_beginAccess`, `docs/perf-measurements.md`). Solange `withBed` offen ist, darf derselbe Pass diese Felder nicht über die Property anfassen, auch nicht lesend; der Compiler meldet das nicht, die Laufzeit bricht gemessen auch im `-O`-Build mit „Fatal access conflict detected" ab.

Zweiter Dämpfer der Tropfen-Ablage `depositDamp` (#108, aus dem D8-Abfluss): wirksam ist der stärkere der beiden Dämpfer (Minimum), nicht ihr Produkt. Das Produkt liefe auf Mäanderbetten (hoher Abfluss und Kanalmaske) gegen 0, und 0 ist als instabil belegt (`channelDepositDamp`).

Betrifft: `Terrain.Bed`, `Terrain.withBed`, `Terrain.erodeCell`, `Terrain.depositCell`, `Terrain.erodeCellTo`, `Terrain.raiseRockCell`, `Terrain.beltDropletGate`, `Terrain.buildDepositDamp`, `Terrain.outletIncision`, `Terrain.fillShallowPonds`, `Hydraulic.erode`, `HydraulicParams.channelDepositDamp`, `SimCoreTests/BedFunnel.swift`

# Ein Bett-Funnel für alle Bett-Schreiber, mit Gletscher-Gate

Die Bett-Regel (erst Sediment, dann Fels abtragen; `h = rock + sed` halten) und das Gletscher-Gate stehen genau einmal, in `Terrain.Bed.erode`/`deposit` (Issues #81, #96). Jede Bett-Schreibung läuft darüber, auch die Tropfenschleife, damit ein künftiger Bett-Pass Regel und Gate nicht vergessen kann. Bis #81 gab es eine zweite, von Hand synchron gehaltene Ausschreibung der Regel, bis #96 stand das Gate in der Tropfenschleife und in der Auslass-Inzision je eigens ausgeschrieben.

Gletscher-Gate (#35): unter dem Eis gehört das Tal dem Gletscher, kein fluvialer Abtrag und keine fluviale Ablage, sonst carvt dasselbe Tal ein zweites Mal mit fluvialem statt glazialem Querschnitt. Bei leerer Maske fällt der Zweig weg, eine eisfreie Welt rechnet bit-identisch zum Stand vor #35. Der Pinsel ist bewusst keine Ausnahme: ein Hieb auf vergletschertem Grund bleibt wirkungslos.

Die Tropfen sperren stärker, Eis ∪ Gürtelbett (`beltDropletGate`, #174/#187): ihr Radial-Pinsel darf das Bett wandernder Mäanderläufe nicht aufreißen. Nicht abgelegte Fracht bleibt in Suspension und erreicht das Bett erst hinter der Sperre, physisch der Sander am Gletschertor.

Ausnahmen, die bewusst auch auf vergletscherten Zellen schreiben: Hangdiffusion und Brandung. Beides ist kein fluvialer Abtrag; ein Abschalten am Gate ließe den Trog mit unbehandelten Kanten zurück (`docs/glacier-measurements.md` §I.1), dieselbe Begründung trägt die Brandung an der Fjordküste. Das Eis schreibt sein Bett mit eigenem Erosionsgesetz (`updateIce`).

Ziel-Fassung `erodeCellTo`: Relaxations-Pässe wie die Auslass-Inzision rechnen eine eigene Zielhöhe. Der naive Weg `h −= (h − hNew)` weicht im aggressiven Regime (Schritt trägt mehr als die halbe Höhe ab) in der Mehrheit der Fälle um 1 ulp ab; die Ziel-Fassung setzt die Zielhöhe exakt.

`Bed` ist eine Roh-Puffer-Sicht auf `h`/`sed`/`rock` plus Sperrmaske, weil der Zugriff über die Klassen-Property gemessen ~4,5 % des Schritts allein in der Swift-Laufzeit kostete (`docs/perf-measurements.md` §I). Solange `withBed` offen ist, darf derselbe Pass diese Felder nicht über die Property anfassen, auch nicht lesend; der Compiler meldet das nicht, die Laufzeit bricht auch im `-O`-Build mit „Fatal access conflict detected" ab.

Zwei Dämpfer der Tropfen-Ablage (`depositDamp` aus dem D8-Abfluss, #108, und `channelDepositDamp`): wirksam ist der stärkere (Minimum), nicht ihr Produkt. Das Produkt liefe auf Mäanderbetten gegen 0, und 0 ist als instabil belegt.

Betrifft: `Terrain.Bed`, `Terrain.withBed`, `Terrain.erodeCell`, `Terrain.depositCell`, `Terrain.erodeCellTo`, `Terrain.beltDropletGate`, `Terrain.buildDepositDamp`, `Hydraulic.erode`, `HydraulicParams.channelDepositDamp`

# dt-Invarianz: vier behobene Ursachen, benannte Reste, Schranken aus der Messreihe (#2)

Gleiche Simulationszeit muss unabhängig von der Schrittweite dasselbe Ergebnis liefern; der Echtzeit-Zeitraffer und der `+10.000 Jahre`-Sprung sind derselbe Vorgang. Vier Ursachen liefen dem zuwider, alle behoben und je eng bewacht (Messreihen `docs/dt-invariance-measurements.md`):

1. `wavePass` war eine Zählschleife (`max(1, min(24, dt/100))`) statt einer Rate. Vor dem Fix erodierte dt = 10 die Küste um ein Vielfaches (volle 100-Jahr-Relaxation je 10-Jahr-Schritt). Der Wächter lässt nur `wavePass` arbeiten (keine Tropfen, keine Hangdiffusion) und hat deshalb eine enge Schranke.
2. Lineare statt exponentieller Relaxation in `fillShallowPonds`, `fillLakes`, `fillOxbows`, `updateVegetation`. `1 − e^(−dt/τ)` über N Teilschritte ist exakt `1 − e^(−N·dt/τ)`, die lineare Form `min(cap, dt/τ)` sättigt am Deckel. Der Test rechnet die Formen direkt gegeneinander, damit die Zusicherung nicht an einer Terrain-Kalibrierung hängt.
3. Die Tropfenzahl `max(1, dt·Rate)` rundete jeden Frame-Schritt auf: bei dt = 0,2 J. verlangte die Rate 0,09 Tropfen, es fielen 1 (11× zu viel). Zusätzlich hing der Tropfen-Strom an einem Schritt-Zähler. Der ganze Zufall eines Tropfens steckt im Startpunkt, und der kommt jetzt aus einem Strom an der laufenden Nummer des Tropfens (`Hydraulic.dropRNG`, `Terrain.dropsEmitted`); dieselbe Tropfenfolge in beliebigen Chargen liefert bit-identisches Terrain. Vorher schoben leere Frame-Schritte den Seed weiter, und ein großer Schritt zog alle Tropfen aus einem Strom: die Zahl stimmte, die Tropfen waren andere.
4. Depositions-Deckel in `meanderStamp` galten je Schritt statt je Zeit. `stepCapFraction` ist bis 500 J. exakt der alte feste Deckel 0,5 (alle Wächter takten mit dt ≤ 500, die Kalibrierung bleibt unangetastet), darüber wächst er monoton (1000 J. → 0,75, 2000 J. → 0,9375) statt zu sättigen und bleibt unter der vollen Differenz.

Kennzahlen: bewusst mehrere unabhängige Achsen, weil die vier Fehler an verschiedenen Pässen hingen: Wasserhaushalt (Seen), Küstenerosion (Zellen in der Wellenzone, genau das Gate von `wavePass`) und Makro-Form (Relief, Landmasse). Gemessen wird auf frischem Abflussfeld: `hf` wird in `step()` einmal am Anfang bestimmt, danach verschieben die Erosionspässe `h`, und `hf − h` am Schrittende ist umso verzerrter, je mehr ein Schritt bewegt (dt = 2000: Seeanteil 0,2111 gegen 0,1584 auf frischem Feld). Zeitgemittelt statt Laufende: Der momentane Seeanteil schwankt innerhalb eines Laufs bei festem dt zwischen 0,071 und 0,150, die größte See-Komponente zwischen 926 und 3572 Zellen (n = 192, Seed 1337, Abtastung je 1000 J.); ein Einzelwert vergleicht Phasen, nicht Regime. Die Abtastmarken sind Zeitpunkte, keine Schrittzahlen.

Wasserhaushalt ohne Tropfen: Priority-Flood, Auslass-Inzision und Pfützen-Verlandung sind schrittweiten-unabhängig, sobald Tropfen-Pass und See-Kern-Gate (`puddleLakeCoreCells`) draußen sind. Gemessen ohne Tropfen, zeitgemittelt: mit Gate 0,0211/0,0212/0,0503, ohne Gate 0,0044/0,0045/0,0046.

Abnahme-Wächter auf den Produktions-Defaults (n = 192, Seed 1337, 20k Jahre, dt 10/240/2000):

| Kennzahl | vorher | nachher | Spanne | Schranke |
|---|---|---|---|---|
| Küstenzone | 5529/4003/4042 | 4250/4084/4110 | 38 % → 3,9 % | 10 % |
| Relief | 0,1690/0,1479/0,1650 | 0,1664/0,1508/0,1672 | 12,5 % → 9,8 % | 20 % |
| meanLand | 0,3547/0,3575/0,3524 | 0,3506/0,3567/0,3512 | 1,4 % → 1,7 % | 5 % |
| Seeanteil | 0,0347/0,0996/0,1401 | 0,0367/0,0925/0,1312 | 75 % → 72 % | 90 % |

Relief und Seeanteil hängen am Tropfen-Splitting, nicht an den vier Ursachen; ihre Schranken fangen nur eine Größenordnung (über die Zwischenstände von #2: Relief 9,8 … 15,0 %, See 72 … 76 %; vor dem Fix erreichte der momentane Seeanteil das 2,6–5,0-fache zwischen dt 10 und 2000). Der Seeanteil hängt auf diesem Seed an einem Grenzbecken. Seit #108 entwässert es bei dt = 10 noch gründlicher: Linux 0,0245/0,0825/0,1066 (77 %), macOS 0,0194/0,1342/0,0984 (86 %), keiner der beiden Hebel allein ist die Ursache (macOS, beide aus: 78 %). Die See-Schranke steht deshalb bei Faktor 10 (90 %) statt Faktor 5 (80 %) (`docs/dt-invariance-measurements.md` §9).

Benannte Reste (`docs/dt-invariance-measurements.md` §5): Operator-Splitting-Drift (Seeanteil über dt ∈ {10, 240, 2000} ohne Tropfen 1,6 %, bei 0,2 Tropfen/Jahr 2,3 %, bei den 2,0 der Produktion 29 %), das See-Kern-Gate als binäre Klassifikation je Schritt, und die beiden Deckel in `braidPass` (Scour fest 0,5 je Schritt, als Rate fällt die Playa-Fläche von >100 auf 35 Zellen; Überfüll-Zugabe 0,005 je Schritt, fünf dt-invariante Ersatzformen kippten je einen #11/#12-Wächter, Tabelle docs §2.4; die Becken reagieren empfindlich, weil ihre Hypsometrie flach ist). Diese Reste sind als #275 erfasst.

Betrifft: `Terrain.wavePass`, `Terrain.relaxFraction`, `Terrain.stepCapFraction`, `Hydraulic.dropRNG`, `Terrain.dropsEmitted`, `Terrain.braidPass`, `SimConfig.puddleLakeCoreCells`, `DtInvariance`

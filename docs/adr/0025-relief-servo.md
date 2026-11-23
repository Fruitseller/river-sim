# Relief-Servo nur noch als Untergrenze, geregelt auf ein robustes Perzentil-Signal (Issue #13)

Der Servo hebt nach, wenn das Relief-Signal unter `reliefTarget` fällt, proportional zum Defizit (∝ deficit/`reliefServoBand`, gedeckelt bei `reliefServoPer100y`), entlang des fixen ridged-Tektonik-Felds (dieselben Gebirge wachsen nach), nur über dessen positiven Teil und nur auf Land.

Rollenwechsel (#13): Er war der Haupt-Hebungsmechanismus und verhinderte damit die Alterung. Auf 0,20 geregelt lief er dauerhaft (Signal real 0,09–0,18) und immer stärker, je flacher das Terrain wurde. Gemessen (n = 160, Seed 1337, 100k): Relief fiel nur bis 30k (0,5335 → 0,4569) und wurde danach wieder hochgeregelt (→ 0,5097), die Gratkrümmung blieb ab 10k flach bei ≈ −0,030 — das „ewig junge Gleichgewicht“. Die Alterung trägt jetzt die abklingende Hebung; der Servo ist nur noch Notboden gegen echtes Einebnen.

`reliefTarget` 0,20 → 0,05. Anteil der Schritte, in denen der Servo anspringt (Produktionspfad, n = 160, Seed 1337, 200k): 0,20 → 1,000 (jeder Schritt, Relief endet bei 0,4961 statt 0,3359, die Alterung ist gelöscht), 0,09 → 0,000, 0,07 → 0,000. Untergrenze aus dem Multi-Seed-Minimum des Signals über 100k: 0,0962 (1337) / 0,1079 (7) / 0,0684 (99) / 0,0859 (2024) / 0,1255 (555). 0,07 läge über dem Minimum von Seed 99 (Servo spränge in normaler Alterung an); 0,05 hält ~27 % Abstand und fängt trotzdem eine echte Peneplanation (Signal → 0) ab.

Regelsignal ist `Terrain.landReliefRobust()` = 95. Perzentil − Median der Landhöhen (vorher `landRelief()` = max − min über Land). max − min hing an zwei Extremzellen; das Minimum liegt per Definition knapp über `sea`, das Signal war also die Höhe der höchsten Zelle und steuerte die Hebung von ~480k Landzellen. Messung (n = 160, Seed 1337, 100k gealtert): eine auf 1,4 gezogene Zelle verschiebt max − min von 0,5097 auf 1,2500 (+145 %), das Perzentil-Signal nicht (0,16211 → 0,16211; exakt sortiert +0,019 %, 0,161965 → 0,161995, weniger als die Bin-Breite 0,000488). Genau diesen Hebel konnte ein Sculpt-Strich auslösen (sculpt koppelt zusätzlich in `upliftBase`). Verworfen: „mittleres lokales Relief im Fenster“, auflösungsabhängig (frisches Terrain Seed 1337, ±1 Zelle: 0,113 (n = 80) → 0,079 (160) → 0,051 (320) → 0,035 (640); mit weltfestem Fenster ±0,8 noch 0,113/0,079/0,092/0,106). Das Perzentil-Signal liegt bei 0,165/0,178/0,183/0,185/0,185 (n = 80/160/320/640/832), praktisch auflösungsfrei (Spanne 11 %, ab n = 160 nur 3,7 %); Testkonfigs mit kleinerem n regeln auf dasselbe Ziel. Wächter `ReliefSignal.testSignalIsResolutionStable`.

`reliefServoBand` 0,07: Defizit-Spanne, über die der Servo von 0 auf `reliefServoPer100y` hochfährt (früher hart codierte 0,1 auf max − min). Historisch (bis #13) wurde das alte Ziel 0,55 (max − min) über die gemessene SENSITIVITÄT auf 0,20 umgerechnet, nicht über das Niveau-Verhältnis: das robuste Signal liegt bei ~0,30 × (max − min), ändert sich aber fast parallel (Median nahezu konstant). Steigung aus der alten Trajektorie (n = 160, Seed 1337): 10k → 30k fällt max − min um 0,0414, das robuste Signal um 0,0290 ⇒ 0,70. Daraus Band 0,1 → 0,07 und Ziel 0,16 + 0,54·0,07 ≈ 0,20. Verworfen damals: Ziel 0,17 / Band 0,03 aus dem Niveau-Verhältnis (Servo-Anteil 0,23 statt 0,54 bei 10k, Plateau 0,491 statt 0,495). 100k-Trajektorien alt/neu (alle 10k Jahre):

    max − min   alt 0.533 0.496 0.472 0.455 0.468 0.480 0.482 0.488 0.491 0.495 0.495
                neu 0.533 0.495 0.467 0.457 0.476 0.491 0.497 0.504 0.509 0.511 0.510
    robust      alt 0.178 0.160 0.142 0.131 0.130 0.134 0.140 0.146 0.151 0.154 0.157
                neu 0.178 0.155 0.140 0.131 0.130 0.139 0.146 0.153 0.157 0.159 0.162

(robuste Werte auf Vielfache von 0,000488 quantisiert, `Terrain.landReliefRobust`.)

Betrifft: `SimConfig.reliefTarget`, `SimConfig.reliefServoPer100y`, `SimConfig.reliefServoBand`, `Terrain.landReliefRobust`, `Terrain.applyUplift`

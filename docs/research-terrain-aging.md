# Geomorphologisch realistisches Altern von Terrain (LEM-Recherche)

Recherche für River-Sim: Wie altert ein Terrain *realistisch* — junge spitze Berge
(Alpen), die über geologische Zeit erodieren **und runder werden** (Appalachen) —
statt unter der reinen Droplet-Hydraulik immer spitzer zu werden.

Quellen sind Primärliteratur (Braun & Willett 2013, Whipple & Tucker 1999,
Baldwin/Whipple/Tucker 2003, Theodoratos et al. 2018), die FastScape/Landlab-Doku
und der nickmcd-Blog inkl. seines Folge-Projekts SoilMachine. Code-Bezüge auf
`SimCore/Sources/SimCore/*` mit Datei:Zeile.

---

## TL;DR — die geomorphologische Diagnose

> **Stand-Hinweis (Aug 2026):** Dieser Abschnitt beschreibt den Zustand ZUM
> ZEITPUNKT DER RECHERCHE. Die Diagnose ist inzwischen umgesetzt: die lineare
> Hangdiffusion läuft als `hillslopeDiffusion` im Produktionspfad, `thermalPass`
> (und `streamPower`) sind entfernt. Aktuelle Pass-Reihenfolge: Klassenkopf von
> `Terrain` bzw. `AGENTS.md` § SimCore-Aufbau. Zeilennummern hier sind historisch.

Der aktive Erosions-Pfad (`cfg.hydraulicEnabled = true`) war zum Recherche-Zeitpunkt:
`applyUplift → computeFlow → Hydraulic.erode (Droplet) → outletIncision → wavePass`
(`Terrain.step()`).

**Es fehlt der einzige Prozess, der Berge rund macht: lineare Hangdiffusion.**
Droplets laufen in *Rinnen* — sie tragen an Wasserscheiden/Graten praktisch nichts
ab. Ohne einen Prozess, der Material von den Graten selbst entfernt, kann das
Terrain nur schärfer werden (Inzision vertieft die Täler, die Grate bleiben).
`diffusionPass` existiert, wurde aber **nur im nicht-Droplet-Zweig** aufgerufen, und
`thermalPass` (Talus) wurde **gar nicht** aufgerufen. Der Langzeit-Runaway (Relief 0.82 → 1.10, HANDOFF.md) und
der `isoHighClamp=0.90`-Deckel sind *Symptome* dieses fehlenden Grat-Prozesses —
nicht die Wurzel.

Die drei Änderungen mit >30 % Realismus-Gewinn (Details unten in §6):

1. **Lineare Hangdiffusion in den Droplet-Pfad** mit *physikalisch relevanter*
   Stärke (aktuell effektiv D≈0, s. §2). Erzeugt konvexe, gerundete Wasserscheiden
   (Appalachen-Look) **und** behebt den Runaway an der Wurzel → `isoHighClamp` kann weg.
2. **Abklingende Hebung** `U(t)=U_floor+(U₀−U_floor)·e^(−t/τ)` statt konstant.
   Das ist der Mechanismus für „jung spitz → alt rund": ohne Nachschub sinkt das
   Relief, und die (konstante) Diffusion rundet die Grate aus.
3. **Prozess-Reihenfolge & Rollen sauber trennen:** ein prinzipieller LEM-Kern
   (Uplift → Flow → Stream-Power → Diffusion) trägt die *Makro-Form* und das
   *Altern*; die Droplets liefern nur die feine dendritische *Textur* obendrauf.

---

## 1. Prozess-Kombination: was zerklüftet von rund trennt

Der Standard-LEM (FastScape, Landlab, CHILD) überlagert drei Prozesse:

```
∂z/∂t  =  U  −  K·A^m·|∇z|^n  +  D·∇²z
         Hebung   Fluviale Inzision      Hangdiffusion
                  (Stream-Power)         (soil creep)
```

- **Stream-Power** `K·A^m·S^n` **zerschneidet** die Landschaft: Erosion ∝
  Einzugsgebiet A → konzentriert sich in Tälern, tieft sie ein, macht Grate
  *relativ* schärfer. Das ist im Repo `outletIncision` (Produktionspfad; der frühere
  `streamPower` ist entfernt) bzw. `transportLimited` im Testpfad.
- **Lineare Diffusion** `D·∇²z` **rundet**: der Fluss ist ∝ Krümmung. Konvexe
  Kuppen (∇²z<0) verlieren Material, konkave Mulden gewinnen → Grate werden zu
  **glatten konvexen Kuppen** (genau das Appalachen-Signal). Das ist `diffusionPass`.
  Die *nichtlineare* Talus-Methode (damals `thermalPass`, seither entfernt) erzeugt
  dagegen nur **planare
  Facetten** am kritischen Winkel — sie rundet Kuppen NICHT. Für den „alt runden"
  Look ist **lineare** Diffusion nötig, nicht die Talus-Schwelle.

**Die Kennzahl: Péclet-Zahl und die charakteristische Länge `l_c = D/K`.**
Theodoratos, Seybold & Kirchner (2018, ESurf 6, 779) nicht-dimensionalisieren
genau diese Gleichung (m=0.5, n=1) und zeigen: es gibt drei charakteristische Skalen

| Skala | Formel | Bedeutung |
|---|---|---|
| Länge | `l_c = D/K` | Hanglänge / Tal-Abstand; Übergang Hang↔Tal |
| Höhe | `h_c = U/K` | Gleichgewichts-Relief |
| Zeit | `t_c = 1/K` | Antwortzeit der Landschaft |

Die (modifizierte) **Péclet-Zahl** `Pe = A·l / l_c²` misst lokal, ob Inzision oder
Diffusion dominiert:
- **Pe ≪ 1 → Hang**, Diffusion horizontal dominant → **glatt, konvex, gerundet**.
- **Pe ≫ 1 → Tal**, Inzision dominant → **eingeschnitten, zerklüftet**.
- Der Übergang (Talkopf, Drainagedichte) liegt bei **Pe ≈ 1**, also auf Längen der
  Ordnung `l_c = D/K`.

Das ist der Hebel: **kleines D/K → viele feine Täler, alles zerklüftet (jung).
Großes D/K → breite gerundete Wasserscheiden, wenige Täler (alt).** Der Übergang
zwischen zerklüftet und rund ist im Kern eine Verschiebung von `l_c` relativ zur
Domänen- bzw. Grat-Breite.
Quelle: [ESurf 6, 779 (2018)](https://esurf.copernicus.org/articles/6/779/2018/esurf-6-779-2018.html),
Gl. 1, 31, 36; Péclet≈1-Übergang: [ESurf 6, 779](https://esurf.copernicus.org/articles/6/779/2018/esurf-6-779-2018.html).

**Wie Diffusion konkret rundet (über die Zeit):** die Diffusionslänge wächst wie
`L_d = √(D·t)`. Ein Grat mit Halbbreite `w` ist „ausgerundet", wenn `L_d ≳ w`, also
nach `t_round ≈ w²/D`. Das gibt eine *direkt messbare* Alterungszeit (§2).

---

## 2. Größenordnungen (SI) und Skalierung aufs Sim-Grid

**Literaturwerte (SI):**

| Größe | Symbol | Typischer Bereich | Quelle |
|---|---|---|---|
| Fläche-Exponent | m | 0.4–0.6 (Baseline 0.5) | Whipple & Tucker 1999 |
| Steigungs-Exponent | n | 1 (Baseline; 1–2 real) | Braun & Willett 2013 |
| Konkavität | m/n | 0.4–0.6 | Whipple & Tucker 1999 |
| Erodierbarkeit | K | 10⁻⁸ … 10⁻⁵ (Einheiten ∝ m,n) | SPLD-Reviews; Fernandes & Dietrich 1997 |
| Hangdiffusivität | D | 4.4×10⁻⁴ … 3.6×10⁻² m²/yr | Fernandes & Dietrich 1997 |
| Hebung | U | 10⁻⁴ … 10⁻³ m/yr (0.1–1 mm/yr) | Whipple & Tucker 1999 |

**Steady-State-Relief (die zentrale Formel).** Setzt man ∂z/∂t=0 an einem Punkt
mit ∇²z=0 (Kanal), balanciert Inzision die Hebung:

```
K·A^m·S^n = U     →     S = (U/K)^(1/n) · A^(−m/n)
```

Das Relief skaliert mit **`(U/K)^(1/n)`** (für n=1 also **linear in U/K**). Über die
gesamte Landschaft gilt in Theodoratos' Nicht-Dimensionalisierung die lineare
Steady-State-Beziehung `A·|∇z| = l_c²·∇²z + h_c` mit `h_c = U/K` — an Punkten ohne
Krümmung reduziert sie sich auf `A·|∇z| = U/K`.
Quellen: [Whipple & Tucker 1999 (PDF)](https://sseh.uchicago.edu/doc/Whipple_and_Tucker_1999.pdf);
[ESurf 6, 779 (2018)](https://esurf.copernicus.org/articles/6/779/2018/esurf-6-779-2018.html), Gl. 31.

**Skalierung aufs normierte Grid.** Grid: `n=640`, `world=100` Einheiten →
`cellSize dx = 100/639 = 0.15649` Einheiten, `dx² = 0.02449`. Höhen normiert
(~0..1, Ziel-Relief ~0.8), Zeit in Jahren. K, U sind schon in Modell-Einheiten
kalibriert (`kRock=3.5e-5`, `upliftPer100y=0.0015` ⇒ U=1.5e-5/yr) und liegen im
plausiblen Bereich. **Der Ausreißer ist D.**

`diffusionPass` rechnet mit dem dimensionslosen Pass-Koeffizienten
`kappa = D·Δt_pass/dx²`. Ein Pass pro 100 Jahre (`passes = dt/100`, `Terrain.swift:744`):

| kappa (pro 100-yr-Pass) | ⇒ D [Einh²/yr] | l_c = D/K [Einh] | l_c [Zellen] |
|---|---|---|---|
| **0.0025** (Default heute) | 6.1×10⁻⁷ | 0.018 | **0.11** (unter Auflösung → wirkungslos) |
| **0.12** (Empfehlung) | 2.94×10⁻⁵ | 0.84 | **5.4** |
| 0.15 (Code-Kommentar „kappa fix bei 0.15") | 3.67×10⁻⁵ | 1.05 | 6.7 |

Der aktuelle Default `kappa=0.0025` entspricht `l_c ≈ 0.1 Zellen` — **unter der
Gitterauflösung**, also faktisch keine Diffusion — und wird im Droplet-Pfad ohnehin
nie aufgerufen. Das ist die *quantitative Wurzel* dafür, dass Grate nie runden.

**Ziel-Werte (Startpunkt zum Kalibrieren per Messung):**
- **D so, dass `l_c = D/K` ≈ 0.6–1.0 Welteinheiten (≈ 4–7 Zellen).** Das setzt den
  Hang→Tal-Übergang / die Drainagedichte auf eine natürliche Skala.
  Mit `K=3.5e-5` ⇒ **D ≈ 2.5–3.5×10⁻⁵ Einh²/yr ⇒ kappa ≈ 0.10–0.15** (stabil, <0.25).
- **Grat-Rundungs-Zeit** `t_round ≈ w²/D`: bei D=2.94e-5 rundet eine Grat-Halbbreite
  von 3/5/8 Zellen in **≈ 7.5k / 21k / 53k Jahren**. D.h. über einen 100k–200k-Jahr-Lauf
  runden die Grate *sichtbar* — genau die gewünschte Alterung.

**D/K/U-Verhältnisse für dynamisches Gleichgewicht statt Runaway:**
- `h_c = U/K` fixiert das Relief. Aktuell (U=1.5e-5, K=3.5e-5) ⇒ h_c≈0.43 als grobe
  Skala — passt zum beobachteten stabilen Relief ~0.77 (die Fläche A^m hebt es an).
- Diffusion **senkt** das Gleichgewichts-Relief (sie trägt von Graten ab), d.h. mit
  neuem D muss U für dasselbe *junge* Relief etwas höher (Faktor ~2–4). Genau dieses
  höhere U lässt man dann abklingen (§3) → das Relief sinkt kontrolliert, kein Deckel nötig.
- Runaway entsteht, wenn Hebung Material zuführt, das kein Prozess von den Graten
  abträgt. Mit Diffusion als Grat-Abtrag ist das System selbst-begrenzend:
  `isoHighClamp` (`Terrain.swift:505`, `Config.swift:44`) wird überflüssig.

---

## 3. Altern modellieren: abklingende Hebung ist der Schlüssel

**Davis-Zyklus vs. moderne LEM-Sicht.** Der klassische Davis'sche „geographische
Zyklus" (Jugend→Reife→Alter→Peneplain) ist qualitativ genau das gesuchte Bild, wird
aber in der modernen Geomorphologie als *Prozess*-Beschreibung ersetzt: dieselbe
Abfolge fällt aus einem LEM heraus, **wenn die Hebung abklingt**. Zwei Regimes:

- **Konstante Hebung + Steady State** (was das Repo heute näherungsweise macht):
  erzeugt ein *stationäres* zerklüftetes Gebirge auf Relief `h_c=U/K`. Es altert
  nie — es bleibt „ewig jung". Das ist der Grund, warum `isoHighClamp` nur ein
  Plateau pinnt statt Alterung zu erlauben (HANDOFF.md Aufgabe 1).
- **Puls dann Zerfall (post-orogener Zerfall):** Hebung baut ein hohes, spitzes
  Gebirge; dann schaltet die Tektonik ab (`U→0`), und die Landschaft zerfällt.
  **Das erzeugt „jung spitz → alt rund".** Baldwin, Whipple & Tucker (2003, JGR)
  zeigen für das detachment-limited Stream-Power-Modell: nach Hebungs-Ende fällt
  das Spitzenrelief um **90–99 % in wenigen 10er-Millionen Jahren** (Zeitskalen
  1–10 Myr). Alluviale Bettbedeckung/Sedimentdecke *verlangsamt* den Zerfall (Berge
  überleben länger — der „Appalachen-Überrest"). Während die Inzision das Relief
  senkt, arbeitet die (weiterlaufende) Diffusion die Grate rund.
  Quelle: [Baldwin, Whipple & Tucker 2003, JGR 108(B3)](https://agupubs.onlinelibrary.wiley.com/doi/full/10.1029/2001JB000550).

**Parametrisierung des Abklingens.** Exponentieller Zerfall mit Zeitkonstante τ:

```
U(t) = U_floor + (U₀ − U_floor) · exp(−(t − t_orogen)/τ)
```

- **U₀** (Orogenese): ~2–4× das heutige U, damit die jungen Berge trotz Diffusion
  scharf/hoch werden (junges h_c hoch).
- **U_floor** (Rest-Tektonik): ~0.05–0.1·U₀ (verhindert totales Einebnen; hält einen
  Appalachen-Sockel).
- **τ:** in Modell-Zeit so wählen, dass der Übergang im Sichtfenster passiert. Die
  Landschafts-Antwortzeit ist `t_c ~ 1/(K·A^m)` — für große Kanäle ~10³ yr, für die
  Wasserscheiden (kleines A) 10⁴–10⁵ yr. **τ ≈ 30k–60k Jahre** rundet über einen
  100k–200k-Jahr-Lauf sichtbar aus (deckt sich mit `t_round`, §2).

Ablauf: Phase 1 (0–~30k yr) konstantes hohes U₀ → scharfe Alpen. Phase 2
(ab ~30k yr) U(t) klingt ab → Relief sinkt, Diffusion rundet → Appalachen.

---

## 4. Hybrid: prinzipieller LEM + Droplet-Textur

Ziel: die *Makro-Form* und das *Altern* kommen aus dem prinzipiellen LEM
(Uplift + Stream-Power + Diffusion, dynamisches Gleichgewicht, realistischer
Zerfall); die *feine dendritische Textur* (nickmcd-Look) kommt weiter vom Droplet.
Das funktioniert, weil beide auf **verschiedenen Skalen** arbeiten: die Diffusion
rundet Grate der Breite `l_c ≈ 5 Zellen`, während Droplet/Stream-Power Kanäle von
1–3 Zellen Breite eingeschnitten halten. Die Péclet-Trennung (§1) sorgt dafür, dass
Diffusion die Kanäle **nicht** wegwischt.

**Operator-Splitting: Reihenfolge pro Zeitschritt** (FastScape/Landlab-Konvention):

```
1. Uplift        z += U(t)·dt              (mit Abkling-U, §3)
2. Drainage      computeFlow (Priority-Flood, receiver, area)   auf der GEHOBENEN Fläche
3. Fluviale      Stream-Power (implizit)   ← Makro-Täler / kohärentes Netz
   Inzision      (outletIncision als flächenbasierte SPL)
4. Droplet       Hydraulic.erode           ← feine dendritische Textur oben drauf
5. Hangdiffusion diffusionPass ×passes     ← rundet Grate (NEU im Droplet-Pfad)
6. (Küste)       wavePass
```

**Warum diese Reihenfolge:**
- **Uplift zuerst**, dann **Drainage** — das Abflussnetz muss die *neue* Topografie
  sehen (sonst inzidiert man in veraltete Täler).
- **Stream-Power vor Diffusion:** erst die Täler schneiden (schafft das Relief, an
  dem die Hänge hängen), dann die Hänge/Grate glätten. Diffusion zuletzt hält die
  Hänge an das frisch geschnittene Netz „angeklebt" und rundet die Talschultern.
- **Droplet zwischen SPL und Diffusion:** der SPL-Kern legt das kohärente Talnetz,
  der Droplet legt die feine Verästelung hinein, die milde Diffusion glättet nur die
  Grate (nicht die Kanäle, s. Skalentrennung).

**Stabilitätsgrenzen:**
- **Explizite Diffusion (5-Punkt-Laplace, 2D):** `kappa = D·Δt/dx² < 0.25`. Bei
  `kappa≈0.12–0.15` und mehreren Pässen pro Schritt (jeder Pass <0.25) stabil.
  `diffusionPass` sub-taktet bereits über `passes = dt/100` (`Terrain.swift:744,759`).
- **Impliziter Stream-Power (Braun & Willett 2013):** unbedingt stabil bei großem Δt,
  weil stromabwärts→aufwärts in `order` gelöst (`outletIncision`) — genau der
  O(n)-FastScape-Trick.
  Quelle: [Braun & Willett 2013, Geomorphology](https://www.semanticscholar.org/paper/A-very-efficient-O(n),-implicit-and-parallel-method-Braun-Willett/7620ee44d1e31a198790b2d86979c5be62d528ed).

---

## 5. nickmcd konkret — und was ER fürs Altern tut

- **Basis-Modell** ([„Simple Particle-Based Hydraulic Erosion", 2020-04-10](https://nickmcd.me/2020/04/10/simple-particle-based-hydraulic-erosion/)
  und [„Procedural Hydrology", 2020-04-15](https://nickmcd.me/2020/04/15/procedural-hydrology/)):
  partikel-/tropfenbasierte Hydraulik-Erosion + Sedimenttransport (genau der
  `Hydraulic.swift`-Ansatz). Parameter dort: `volumeFactor`, `depositionRate`,
  `friction`, `evapRate`, Stream-Map-Adaption. **Kein** Hangdiffusions-/Thermal-Prozess.
  Ergebnis: **junge, aktiv zerschnittene** Landschaften (Meander, Wasserfälle, Seen,
  Deltas) — nach eigener Aussage *keine* Canyons/gealterten Formen. Bestätigt: der
  reine Droplet-Ansatz altert nicht.
- **Folge-Projekt [SoilMachine, 2022](https://nickmcd.me/2022/04/15/soilmachine/)
  ([GitHub weigert/SoilMachine](https://github.com/weigert/SoilMachine)):** hier
  fügt er genau das fehlende Stück hinzu — eine **statische `cascade`-Methode**
  (Sediment „rollt" bergab bis zum **Talus-/Reposewinkel**) und beschreibt **thermale
  Erosion als „natürlichen lokalen Glättungsfilter"**, der Grate von oben abträgt.
  D.h. **auch nickmcd braucht einen Hang-/Glättungsprozess**, um über den „ewig
  jungen" Droplet-Look hinauszukommen. Sein `cascade` ist die *nichtlineare*
  (Talus-)Variante — für konvexe Rundung ist die *lineare* Diffusion besser (§1),
  aber die Kernaussage stützt Empfehlung 1: **ein Grat-abtragender Prozess ist Pflicht.**
- Der [Meander-Artikel (2023)](https://nickmcd.me/2023/12/12/meandering-rivers-in-particle-based-hydraulic-erosion-simulations/)
  ist relevant für Repo-Aufgabe 2 (Meander mit Droplet versöhnen), nicht fürs Altern.

---

## 6. Empfohlene nächste Schritte für dieses Repo (nach Wirkung/Aufwand)

Priorisiert; die ersten zwei sind die >30 %-Realismus-Hebel.

1. **[GROSS, geringer Aufwand] Lineare Hangdiffusion in den Droplet-Pfad.**
   In `Terrain.step()` (`Terrain.swift:745-756`, Droplet-Zweig) nach der Droplet-
   Erosion `diffusionPass()` mit **`kappa ≈ 0.12`** aufrufen (statt Default 0.0025),
   `passes`-mal. Das ist der Prozess, der Grate rundet (konvexe Kuppen) und den
   Runaway an der Wurzel behebt. Danach `isoHighClamp` schrittweise lockern/entfernen
   (`Config.swift:44`) und per Headless-Messung (LongRunCollapse-Test) prüfen, dass
   Relief jetzt *von selbst* stabil bleibt statt am Deckel zu kleben.
   Erwartung: sichtbar gerundete Wasserscheiden über 20k–50k Jahre (`t_round`, §2).

2. **[GROSS, mittlerer Aufwand] Abklingende Hebung für echtes Altern.**
   `applyUplift` (`Terrain.swift:498`) auf `U(t)=U_floor+(U₀−U_floor)·e^(−t/τ)`
   umstellen (τ≈40k yr, U₀≈2–4× heute, U_floor≈0.1·U₀). Ergibt die Sequenz
   jung-spitz → alt-rund statt eines statischen Gleichgewichts. Zusammen mit (1)
   ist das der Kern des „Appalachen vs. Alpen"-Effekts.

3. **[MITTEL, gering] Prozess-Rollen/Reihenfolge sauber ziehen.**
   Reihenfolge pro Schritt auf Uplift→Flow→SPL(outletIncision)→Droplet→Diffusion→Wave
   bringen (§4). SPL trägt die Makro-Täler, Droplet nur die Textur, Diffusion die
   Grat-Rundung. `l_c=D/K ≈ 5 Zellen` als Ziel-Kennzahl beim Kalibrieren nutzen
   (kleiner → zerklüfteter/jung, größer → glatter/alt) — das ist ein *einziger*
   physikalischer Regler für den „Alters"-Look.

4. **[KLEIN, ERLEDIGT Aug 2026] `thermalPass` bewusst einordnen.** Talus erzeugt
   planare Facetten, keine Rundung — NICHT als Ersatz für lineare Diffusion.
   Entscheidung: (1) läuft (`hillslopeDiffusion`), `thermalPass` war seither
   unreferenziert und wurde ENTFERNT (mitsamt `talus`/`thermalRelax`/`rockCrumble`).
   Falls je wieder für steile Fels-/Landslide-Kappen gewünscht: aus `cf83874^` holen.
   Die übrigen `Terrain.swift`-Zeilennummern in diesem Dokument sind historisch
   (Stand der Recherche) und stimmen nicht mehr.

5. **[Diagnose] Messgrößen erweitern.** Für die Kalibrierung headless zusätzlich zur
   `landRelief()` die **mittlere Grat-Krümmung** (∇²z auf Grat-Zellen) und die
   **hypsometrische Kurve** loggen — sie unterscheiden „spitz/jung" (konkav, viel
   hohe Fläche) von „rund/alt" (konvexe Kuppen, hypsometrisch ausgeglichen)
   objektiv, wie vom User gefordert (erst messen, dann schrauben).

---

## Quellen

- Braun, J. & Willett, S. (2013). *A very efficient O(n), implicit and parallel method
  to solve the stream power equation…* Geomorphology.
  [Semantic Scholar](https://www.semanticscholar.org/paper/A-very-efficient-O(n),-implicit-and-parallel-method-Braun-Willett/7620ee44d1e31a198790b2d86979c5be62d528ed) ·
  [FastScapeLib-Doku](https://fastscape.org/fastscapelib-fortran/)
- Whipple, K. & Tucker, G. (1999). *Dynamics of the stream-power river incision model…*
  JGR. [PDF](https://sseh.uchicago.edu/doc/Whipple_and_Tucker_1999.pdf)
- Baldwin, J., Whipple, K. & Tucker, G. (2003). *Implications of the shear-stress river
  incision model for the timescale of postorogenic decay of topography.* JGR 108(B3).
  [Wiley](https://agupubs.onlinelibrary.wiley.com/doi/full/10.1029/2001JB000550)
- Theodoratos, N., Seybold, H. & Kirchner, J. (2018). *Scaling and similarity of a
  stream-power incision and linear diffusion landscape evolution model.* ESurf 6, 779.
  [HTML](https://esurf.copernicus.org/articles/6/779/2018/esurf-6-779-2018.html)
- Fernandes, N. & Dietrich, W. (1997) — D-Bereiche (via SPLD-Reviews).
- Landlab: [ErosionDeposition / LinearDiffuser Doku](https://landlab.readthedocs.io/en/latest/tutorials/landscape_evolution/erosion_deposition/erosion_deposition_component.html)
- nickmcd: [Simple Particle-Based Hydraulic Erosion (2020)](https://nickmcd.me/2020/04/10/simple-particle-based-hydraulic-erosion/) ·
  [Procedural Hydrology (2020)](https://nickmcd.me/2020/04/15/procedural-hydrology/) ·
  [SoilMachine (2022)](https://nickmcd.me/2022/04/15/soilmachine/) ·
  [GitHub weigert/SoilMachine](https://github.com/weigert/SoilMachine)

Code-Bezüge (Stand der Recherche — `thermalPass`/`streamPower` sind inzwischen
entfernt, Zeilennummern historisch): `SimCore/Sources/SimCore/Terrain.swift`
(`step`, `diffusionPass`, `hillslopeDiffusion`, `outletIncision`, `applyUplift`),
`SimCore/Sources/SimCore/Config.swift` (K/D/U-Parameter),
`SimCore/Sources/SimCore/Hydraulic.swift` (Droplet).

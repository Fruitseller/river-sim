# Klima-Vertikale: Temperaturfeld, Schneedecke und der Weg zum Eis (Recherche)

Recherche für River-Sim, Issue #33. Frage: Wie wird aus dem heutigen **Farb-Schnee**
(oberste 1,5 % der Landhöhen werden weiß gemalt, `HeightBands.snowAmount` — kein
Sim-Pass liest das) ein **Prozess** — Temperatur aus der Höhe, Schneedecke aus einer
Massenbilanz — und welches Eisfluss-Modell trägt die Folgestufe (#35)?

Quellen sind Primärliteratur (Hock 2003, Braithwaite 1995, Jennings et al. 2018,
Liebl/Hergarten/Egholm 2023, Egholm et al. 2011, Herman et al. 2015, Humphrey &
Raymond 1994, ICAO/US Standard Atmosphere). Code-Bezüge auf
`SimCore/Sources/SimCore/*`.

---

## TL;DR — die vier Entscheidungen

1. **Temperatur = affine Funktion der Höhe.** `T = T₀ − Γ·(h − sea)`. Weil es
   keinen vertikalen Meter-Maßstab gibt, ist Γ eine **Kalibrier-Entscheidung**:
   wir setzen 1 Höheneinheit ≙ 4000 m und rechnen mit dem
   ICAO-Standard-Temperaturgradienten 6,5 K/km → Γ = 26 K je Höheneinheit (§1).
2. **Schnee = Temperatur-Index-Modell (degree-day)**, aber in der
   **Relaxationsform** `dS/dt = a − μ·S` statt der klassischen
   `dS/dt = a − m` mit `max(0, …)`. Nur die Relaxationsform ist exakt
   dt-invariant (§2/§3) — die klassische Form bricht genau am Ausapern.
3. **Eisfluss (#35): FLUX-Modell, nicht SIA-Diffusion.** Die SIA ist eine
   nichtlineare Diffusion mit explizitem Zeitschritt-Deckel `Δt ≲ Δx²/(2·D_max)`.
   Das ist mit der getesteten Invariante dieses Projekts (`+10.000 Jahre` in EINEM
   Schritt == Zeitraffer) unvereinbar. Das Flux-Modell (Hergarten 2021 /
   Liebl et al. 2023, „stream power law for glacial erosion") läuft auf demselben
   Akkumulations-Netz, das `computeFlow` ohnehin baut (§4).
4. **Feldinventar für EINEN Versionssprung** (`WorldSnapshot.version` 2 → 3):
   `temperature`, `snow`, `ice`. Mehr braucht auch #35 nicht — der Eisfluss des
   Flux-Modells ist eine Ableitung je Schritt, kein Zustand (§6).

---

## 1. Temperatur: der fehlende vertikale Maßstab

### 1.1 Was die Atmosphäre vorgibt

Die ICAO-Standardatmosphäre (ISA) definiert von Meereshöhe bis 11 km einen
Temperaturgradienten von **6,50 °C/km**; das ist auch der übliche Wert für die
mittlere *environmental lapse rate* der Troposphäre. Zum Vergleich: der
trockenadiabatische Gradient liegt bei 9,8 °C/km, der feuchtadiabatische
je nach Druck/Temperatur bei 3,6–9,2 °C/km (Richtwert ~5 °C/km).

Für eine feuchte, maritime Insel — und genau die stellt dieses Terrain dar, s.
die κ-Herleitung bei `SimConfig.endorheicEvapRatio` („E ≈ 1,08 · P … die feuchte,
kühle Insel") — ist der ISA-Wert der richtige Kompromiss zwischen trocken- und
feuchtadiabatisch. **Γ_real = 6,5 K/km.**

### 1.2 Das Maßstabsproblem

`h` ist normiert (`SimConfig`: „Höhen sind normiert (~ −0.3 … 1.4)"), `sea = 0.15`,
und die Landreliefspanne liegt gemessen bei ~0,60 Höheneinheiten
(n=832, Seed 1337, Generierung: `maxH` 0.7457 gegen `sea` 0.15;
`docs/height-band-measurements.md`). Es gibt **keine** Zahl im Repo, die eine
Höheneinheit in Meter übersetzt — `world = 130` ist eine *horizontale* abstrakte
Einheit, und `cellSize` koppelt nur horizontal.

Die Kopplung Höheneinheit → Temperatur ist damit eine **freie Kalibrier-Entscheidung**,
kein Naturgesetz. Sie hat genau einen Freiheitsgrad, der die Physik trägt:

> **H_ref** = wie viele Meter ist eine Höheneinheit? → **Γ = 6,5 K/km · H_ref**

und einen zweiten, der das Klima setzt:

> **T₀** = Temperatur auf Meereshöhe (bei `h = sea`).

### 1.3 Die Wahl: H_ref = 4000 m, T₀ = 11 °C

**H_ref = 4000 m → Γ = 26 K je Höheneinheit.** Damit ist der höchste Punkt der
frischen Insel `(0.7457 − 0.15)·4000 ≈ 2380 m` — ein alpines Mittelgebirge mit
echter Höhenstufung. Verworfene Alternativen:

| H_ref | Γ [K/Einheit] | Gipfelhöhe (Jahr 0) | Warum verworfen |
|---|---|---|---|
| 2000 m | 13 | 1190 m | Bei jedem T₀, das die Küste eisfrei hält (> 5 °C), liegt die 0-°C-Grenze **über** dem Gipfel — es gäbe nie Schnee, das Feature wäre stumm. |
| **4000 m** | **26** | **2380 m** | gewählt |
| 8000 m | 52 | 4770 m | Die 0-°C-Grenze säße bei realistischem T₀ auf halber Flanke; die alternde Insel (maxH 0.7457 → 0.6372 nach 30k J.) würde die Schneezone kaum bewegen, weil das obere Drittel dauerhaft unter Frost stünde. |

**T₀ = 11 °C.** Gewählt aus der Anschluss-Bedingung an den heutigen Look: die
0-°C-Isotherme soll bei der Generierung dort liegen, wo bisher der
Perzentil-Schnee begann (p98.5 = 0.5699 bei n=832/Seed 1337).

```
h(T = 0) = sea + T₀/Γ  =  0.15 + 11/26  =  0.573      (gegen p98.5 = 0.5699)
```

Das ist der einzige Punkt, an dem die alte Kalibrierung noch durchschlägt — und
bewusst nur als *Startwert*: ab da bewegt das **Klima** die Grenze (die Insel
altert, `maxH` fällt, die Schneefläche schrumpft), nicht mehr ein fixer
Flächenanteil. Genau das ist das Ticket-Ziel.

11 °C Meeresspiegel-Jahresmittel ist außerdem für sich plausibel: das ist grob
Südnorwegen/Nordschottland — dieselbe kühl-maritime Lage, die auch die
Verdunstungs-Kalibrierung annimmt.

### 1.4 Was das Feld NICHT tut

Kein Breitengrad-Gradient, keine Jahreszeit, keine Kontinentalität. Begründung:
das Modell hat keine Zeitachse unterhalb von Jahren (`step(dtYears:)`), also auch
keinen Jahresgang, und die Karte ist eine Insel von 130 Welteinheiten — ein
Breitengradient darüber wäre eine erfundene zweite Klimaachse. Die einzige
horizontale Klimavariation, die dieses Repo belegt hat, ist die **Orographie**
(`computeRain`, Luv/Lee) — und die geht über die Akkumulation in den Schnee ein
(§2.1). Temperatur bleibt reine Höhenfunktion.

---

## 2. Schneedecke: Massenbilanz nach dem Temperatur-Index-Modell

### 2.1 Akkumulation: Niederschlagsphase

Die Standard-Formulierung: Niederschlag ist Schnee, wenn die Lufttemperatur unter
einer Schwelle liegt. Jennings et al. (2018, *Nature Communications* 9:1148)
werten 17,8 Mio. Beobachtungen der Nordhemisphäre aus: die Temperatur, bei der
Regen und Schnee **gleich häufig** fallen, liegt im Mittel bei **1,0 °C** und für
95 % der Stationen zwischen −0,4 und 2,4 °C. Bei 0 °C fällt der Niederschlag
überwiegend als Schnee; der Regenanteil steigt erst zwischen 1 und 3 °C spürbar.

Eine harte Schwelle würde eine Kante ins Feld schneiden. Der übliche Ausweg ist
die **Doppelschwelle** (Kienzle 2008, USACE): ein Übergangsband, in dem beides
fällt. Übernommen als lineare Rampe:

```
f_schnee(T) = clamp( (T_regen − T) / (T_regen − T_frost), 0, 1 )
T_frost = −1 °C   T_regen = +3 °C     →  50 % bei +1 °C  (= Jennings-Mittel)
```

Akkumulationsrate:  `a(k) = c_akk · rain[k] · f_schnee(T[k])`.

`rain` ist das vorhandene orographische Feuchtefeld (`Terrain.computeRain`,
Wertebereich ~0,18 … 1,0) — damit trägt die Luvseite mehr Schnee als der
Regenschatten-Osten, ohne eine zweite Klimaquelle einzuführen. Dieselbe
Orographie, die schon Abfluss (`rainWeight`, #10) und Verdunstung
(`endorheicAridity`, #11) verteilt.

### 2.2 Ablation: das degree-day-Modell

Hock (2003, *Journal of Hydrology* 282, 104–115, „Temperature index melt modelling
in mountain areas") ist die Referenz-Übersicht. Die Grundform:

```
M = DDF · Σ T⁺        [mm w.e.]
```

— Schmelze proportional zur Summe der positiven Tagesmitteltemperaturen, Schwelle
0 °C. Typische Tagesgradfaktoren: **Schnee 3–5 mm w.e. d⁻¹ K⁻¹, Eis 5–8**. Hock
betont, dass diese sehr einfache Form auf Einzugsgebietsskala oft genauso gut
abschneidet wie eine volle Energiebilanz — der Grund, warum praktisch jedes
Eisschild-Modell mit PDD arbeitet (Braithwaite 1995; Braithwaite & Olesen fanden
r = 0,96 zwischen Jahresablation und positiver Temperatursumme).

**Was wir davon übernehmen und was nicht.** Wir haben keine Tagesmittel und keinen
Jahresgang, sondern ein *Jahresmittel*. Die positive Temperatursumme eines Jahres
lässt sich daraus nicht rekonstruieren (sie hängt an der Amplitude des Jahresgangs).
Wir setzen deshalb die Ablation proportional zur **Überschreitung des Jahresmittels
über 0 °C** und lassen den Gradfaktor die Tageszahl und den Jahresgang mit
absorbieren. Das ist eine dokumentierte Vereinfachung, kein Zahlenfehler: der
Faktor ist ohnehin nicht in mm w.e. kalibrierbar, weil auch die Akkumulation in
abstrakten Einheiten kommt.

### 2.3 Die Bilanz

```
dS/dt  =  a(T, rain)  −  Ablation
```

`S` ist das Schneewasser-Äquivalent (SWE) in abstrakten Einheiten. Die Wahl der
Ablations-Form ist der eigentliche Knackpunkt — §3.

---

## 3. dt-Invarianz: warum die klassische PDD-Form hier nicht geht

Die getestete Invariante dieses Projekts (AGENTS.md, `SimCoreTests/DtInvariance.swift`):
Gesamtwirkung eines Passes muss ∝ `dt` sein; Zeitraffer (dt ≈ 0,2 J./Frame) und
`+10.000 Jahre` in einem Schritt müssen dasselbe liefern.

**Die klassische Form bricht das.** `S ← max(0, S + (a − m)·dt)` mit konstanter
Schmelzrate `m` ist nur so lange linear, wie die Decke hält. Sobald sie in einem
Schritt ausapert, hängt das Ergebnis an der Schrittweite: eine Zelle mit
`S = 0.1`, `a = 0`, `m = 1/Jahr` ist nach `dt = 1` bei 0 — aber ein Jahr in zehn
Zehntelschritten kommt am selben Punkt an, während ein Jahr in EINEM Schritt
0.9 „Schmelzguthaben" verwirft, das bei wieder einsetzendem Schneefall im selben
Schritt fehlt. Das ist exakt die Fehlerklasse „Raten-Zähler mit Übertrag statt
`max(1, …)`" aus AGENTS.md, nur mit umgekehrtem Vorzeichen.

**Die Relaxationsform ist exakt.** Die Ablation wird als *Ratenkonstante* auf den
Vorrat gelesen:

```
dS/dt = a − μ·S      mit   μ(T) = 1/τ₀  +  c_schmelz · max(0, T − 0 °C)

Gleichgewicht:   S* = a / μ
Exakte Lösung:   S(t+dt) = S* + (S(t) − S*) · e^(−μ·dt)
```

Das ist die Bauform, die AGENTS.md als eine der drei zulässigen nennt
(„exponentielle Relaxation `1 − e^(−dt/τ)`") und die im Repo schon fünfmal steht
(`relaxWaterLevel`, `updateSaltCrust`, `updateVegetation`, `fillShallowPonds`,
`fillOxbows`). Sie teleskopiert exakt über beliebig viele Teilschritte, braucht
kein `max(0, …)` (aus `S ≥ 0, a ≥ 0` folgt `S ≥ 0`) und hat keinen Deckel, an dem
etwas sättigen könnte.

**Was sie physikalisch bedeutet.** `μ·S` ist eine *anteilige* Ablation: die Decke
verliert je Jahr einen festen Bruchteil, statt eine feste Menge. Gegen die
Realität ist das die schwächere Annahme (Schmelze ist flächenbezogen, nicht
vorratsbezogen), sie hat aber eine saubere Lesart: eine tiefe Decke apert
später aus als eine dünne, und der Übergang ist weich statt eine Kante. Für ein
Jahresmittel-Modell ohne Jahresgang ist genau das die richtige Glättung — real
verteilt der Jahresgang das Ausapern über die Schmelzsaison, und die
Exponentialform bildet diese Verschmierung ab.

**τ₀ = Grundumsatz.** Der additive Sockel `1/τ₀` in `μ` hat drei Aufgaben:

1. Er hält `S* = a/μ` **beschränkt**. Ohne ihn ginge `S*` an der 0-°C-Grenze
   (μ → 0) gegen unendlich, und eine 200k-Jahre-Welt bekäme numerisch entgleiste
   Schneetürme im Gipfelbereich.
2. Er ist physikalisch besetzt: Sublimation und Windverfrachtung tragen auch bei
   Dauerfrost ab (auf antarktischen Blaueisfeldern ist Sublimation der einzige
   Ablationsterm).
3. Er ist der **Anschlusspunkt für #35**: was oberhalb der Gleichgewichtslinie aus
   dem Schneevorrat abfließt, ist real die Firn→Eis-Umwandlung. In #35 wird genau
   dieser Term (statt ins Nichts) in das Eisfeld gebucht.

---

## 4. Eisfluss (#35): SIA-Diffusion gegen Flux-Modell

### 4.1 Die SIA

Die *shallow ice approximation* reduziert die Stokes-Gleichungen auf eine
nichtlineare Diffusion der Eisdicke. Mit Glens Fließgesetz (Exponent n = 3) und
Kontinuität `∂H/∂t = ṁ − ∇·q`:

```
q  =  u·H       u = f_d (ρ g α)ⁿ H^(n+1)  +  f_s (ρ g α H)ⁿ H^(n−1)
                    ^ Deformation             ^ Gleiten
⇒  ∂H/∂t  =  ṁ + ∇·( D ∇z_s )   mit   D ∝ H^(n+2) |∇z_s|^(n−1)
```

(Form wie in OGGM dokumentiert; die Diffusions-Lesart ist Standard seit Hutter/
Mahaffy.) Sie ist **die** Grundlage der meisten Eisschild-Modelle.

**Zwei harte Gründe, warum sie hier nicht passt:**

1. **Zeitschritt.** `D` hängt an der Lösung selbst (`H^{n+2}` = `H^5`), die
   Gleichung ist eine *degenerierte* Diffusion. Explizite Schemata brauchen
   `max D · Δt < ½ Δx²`; produktionsnahe SIA-Modelle fahren deshalb adaptive
   Zeitschritte im Bereich von Monaten bis wenigen Jahren. Dieses Projekt hat
   `+10.000 Jahre` in einem Schritt als **getestete Abnahme-Invariante**. Ein
   SIA-Pass müsste intern auf tausende Teilschritte sub-takten — bei n=832 und
   einem `H^5`-abhängigen Deckel ist das nicht budgetierbar (zum Vergleich: die
   *lineare* Hangdiffusion sub-taktet heute schon mit `totalK/0.2`, und die hat
   ein konstantes κ).
2. **Gültigkeitsbereich.** Le Meur et al. (2004) und Egholm et al. (2011) zeigen,
   dass die SIA in steilem alpinem Gelände versagt (sie vernachlässigt gerade die
   longitudinalen Spannungen, die die U-Tal-Form erzeugen) und erst ab
   Gitterweiten von 1–3 km brauchbar ist. Deshalb gibt es iSOSIA. Unser Gelände
   ist genau der steile alpine Fall — wir würden die teure Variante bezahlen und
   ihr schlechtestes Regime bekommen.

### 4.2 Das Flux-Modell

Hergarten (2021) / Liebl, Hergarten & Egholm (2023, *Geosci. Model Dev.* 16,
1315–1343, „Modeling large-scale landform evolution with a stream power law for
glacial erosion (OpenLEM v37)") formulieren die glaziale Erosion detachment-limitiert
exakt wie die fluviale Stream-Power:

```
E  =  K_g · A_i^m · S^n            m/n = 0.5 (Default)
```

`A_i` = Eisfluss, ausgedrückt als **äquivalente Einzugsgebietsfläche** (Eisfluss
geteilt durch eine Referenz-Niederschlagsrate); `S` = Gefälle der **Eisoberfläche**.
Die Annahme: der gesamte Eisfluss stammt aus dem Gleiten am Bett, die
Eisdeformation wird vernachlässigt. Das Eisnetz wird wie ein dendritisches
Flussnetz auf einer Hauptfließlinie akkumuliert.

**Das Benchmark** (dieselbe Arbeit, gegen iSOSIA v3.4.3):
großräumige Erosionsmuster und Eiskonfiguration stimmen nach ~25 ka gut überein;
Gesamt-Erosionsvolumen innerhalb ~10 %. Unterschiede: OpenLEM erodiert in der
Frühphase (V→U-Übergang) die Talflanken 30–50 % stärker, und die
Endquerschnitte sind eher rechteckig statt parabolisch. Die Autoren nennen das
Modell **komplementär**, geeignet für orogen-skalige Läufe, in denen die
Recheneffizienz neue Fragen erst möglich macht.

### 4.3 Entscheidung

**Flux-Modell.** Begründung über das Benchmark hinaus:

- Es läuft auf **derselben Maschinerie**, die `computeFlow` ohnehin je Schritt
  baut: Priority-Flood → `order` (aufsteigende Füllhöhe) → Akkumulation in
  umgekehrter Reihenfolge. Der Eisfluss ist die Akkumulation der positiven
  Massenbilanz über dieselbe Empfängerstruktur. Kein neuer Löser, kein neuer
  Zeitschritt-Deckel, keine zweite Stabilitätstheorie.
- Es ist **implizit stabil** in derselben Form wie `outletIncision`
  (`hNew = (h + f·h_r)/(1 + f)`) — die Bauform, mit der dieses Repo schon
  `+10.000-Jahre`-Sprünge fährt.
- Die Rollentrennung D8/MFD (AGENTS.md) überträgt sich unverändert: Eis-Erosion
  auf dem D8-Empfängerbaum, Render-Ableitungen auf MFD.
- Der Genauigkeitsverlust liegt dort, wo dieses Projekt ihn tragen kann: die
  Talquerschnitts-*Form* ist Kosmetik gegenüber der Frage, ob überhaupt
  Trogtäler, Kare und Moränen entstehen.

Der Preis ist benannt: rechteckige statt parabolischer Tröge und eine zu starke
Flanken-Erosion in der Frühphase. Falls sich das visuell rächt, ist die
Gegenmaßnahme ein lateraler Ausstrich der Erosionsspur (Liebl et al. machen genau
das: „artificially expanded erosion swath"), nicht der Wechsel auf SIA.

---

## 5. Erosionsgesetz für #35

Die glaziale Erosionsrate wird durchgängig als Potenzgesetz der **Gleitgeschwindigkeit**
angesetzt:

```
ė  =  K_g · u_s^l
```

- **l = 1** — Humphrey & Raymond (1994), Variegated Glacier: die klassische
  lineare Annahme; über die Surge-Phase gemessen.
- **l ≈ 2** — Herman et al. (2015, *Science* 350, 193–195, „Erosion by an Alpine
  glacier"): simultane Messung von Schwebfracht und Eisgeschwindigkeit am
  Franz-Josef-Gletscher; die Erosionsrate skaliert mit dem **Quadrat** der
  Gleitgeschwindigkeit. Koppes et al. (2015) stützen den überlinearen Exponenten
  aus einem unabhängigen Datensatz.

Im Flux-Modell wird `u_s` nicht explizit gelöst; die äquivalente Formulierung ist
`E = K_g A_i^m S^n` mit `m/n = 0.5` (Liebl et al. 2023). Beide Lesarten sind
kompatibel — `A_i^m S^n` ist die Stream-Power-Schreibweise derselben Aussage
„Abtrag ∝ (überlinear) Fließintensität".

**Empfehlung für #35:** mit `m = 0.5, n = 1` starten — exakt die Exponenten, die
`outletIncision` heute fluvial fährt (`SimConfig.mExp = 0.5`, n = 1 implizit
stabil). Damit ist die glaziale Rate ein *Faktor* auf einer schon kalibrierten
Maschinerie statt einer zweiten Kalibrier-Achse; der überlineare Charakter kommt
über `K_g > K_fluvial` herein (real erodieren Gletscher 1–2 Größenordnungen
schneller als Flüsse).

---

## 6. Feldinventar für den EINEN Versionssprung

Das Speicherformat kennt bewusst keine Migration (`WorldSnapshot`-Doku: alte
Dateien werden abgelehnt). Alle Kryo-Felder müssen deshalb **gemeinsam** hinein,
auch die, die erst #35 beschreibt. `WorldSnapshot.version` **2 → 3**.

| Feld | Typ | Rolle | Wer schreibt | Leer wenn |
|---|---|---|---|---|
| `temperature` | `[Double]` | °C je Zelle, `T₀ − Γ(h−sea)` | #33 `updateClimate` | `climateEnabled = false` |
| `snow` | `[Double]` | SWE, echter Bilanz-Zustand | #33 `updateClimate` | `climateEnabled = false` |
| `ice` | `[Double]` | Eisdicke in Höheneinheiten | **#35** (in #33 konstant 0) | `climateEnabled = false` |

**Warum `temperature` mitreist, obwohl es eine reine Ableitung aus `h` ist.**
Dieselbe Doktrin wie bei `rain`, `hf`, `area`, `lithHardness` (Inventar-Doku in
`Terrain.swift`): „auch Felder, die der nächste Schritt neu ableitet, reisen mit
— dann ist der erste gerenderte Frame korrekt, ohne einen Sim-Schritt zu
erzwingen". Und: die Schneebilanz ist Zustand, ihr Eingang darf beim Laden nicht
für einen Frame fehlen.

**Warum `ice` schon jetzt.** Es ist der einzige Zustand, den das Flux-Modell aus
§4 braucht — der Eisfluss `A_i` selbst wird je Schritt aus Massenbilanz und
`order` akkumuliert und ist damit Arbeitsspeicher, kein Zustand (genau wie `area`
… das zwar mitreist, aber nur fürs sofortige Rendering). Damit ist die Liste
vollständig: **#35 braucht keinen weiteren Versionssprung.**

**Geprüft und NICHT aufgenommen:**

- `iceFlux`/`slidingVelocity` — Ableitung je Schritt aus `ice` + `h` + `order`.
- `firn` als eigener Vorrat zwischen Schnee und Eis — der Übergang ist in §3 der
  `1/τ₀`-Term; ein drittes Reservoir wäre eine Kalibrier-Achse ohne sichtbaren
  Unterschied auf einer 130-Einheiten-Insel.
- Eine `snowRate`-EWMA analog zu `streamRate` — die Bilanz ist bereits ein
  Gedächtnis (τ = 1/μ), eine zweite Glättung wäre doppelt.
- Der Gradient/Temperaturgradient selbst — steht in der Config, und die reist
  vollständig mit (`SimConfig` ist Codable-synthetisiert).

---

## 7. Eine Quelle der Wahrheit: was den Perzentil-Schnee ablöst

Heute gibt es zwei Konsumenten der Schneegrenze:

1. `SimNode.terrainColorBytes` malt `bands.snowAmount(h)` weiß.
2. `HeightBands.bearsTrees(h)` (Waldgrenze) schließt die Schneezone von der
   Baum-Geometrie aus.

Beide werden auf das Schneefeld umgezogen — auf **verschiedene Weise**, und das
ist Absicht:

- **Färbung liest das Feld direkt** (je Zelle). Nur so wird das Luv/Lee-Signal
  der Akkumulation sichtbar; eine Höhenschwelle könnte es prinzipiell nicht
  zeigen.
- **Die Waldgrenze bleibt eine HÖHE** — `HeightBands.snowStart/snowFull` —, aber
  diese Höhe wird nicht mehr aus einem Perzentil gesetzt, sondern **aus dem
  Schneefeld zurückgerechnet**: der Landanteil mit Schneedeckung über der
  Schwelle wird gemessen, und `snowStart` ist das Höhenquantil, das genau diesen
  Anteil abschneidet. Damit gilt weiter „Schneezone == Flächenanteil X", aber X
  ist jetzt **gemessen statt konfiguriert** und folgt dem Klima.

Warum die Waldgrenze nicht auch je Zelle: `snowStart/snowFull` sind Teil des
`HeightBands`-Vertrags, der über `SimNode.heightBands()` an Shader und
Diagnose geht und im Spielstand mitreist. Eine Höhe bleibt die richtige
Abstraktion für „ab wo hört der Wald auf" — sie ist stetig, monoton und ohne
Feldzugriff auswertbar. Der Perzentil-Schnee ist damit **abgelöst**, nicht nur
umgangen: `bandSnowPercentile`/`bandSnowFullPercentile` wirken nur noch als
Rückfall, wenn das Klima abgeschaltet ist (dann ist alles bit-identisch zu heute).

---

## Quellen

- **Hock, R. (2003).** *Temperature index melt modelling in mountain areas.*
  Journal of Hydrology 282, 104–115.
  [ScienceDirect](https://www.sciencedirect.com/science/article/abs/pii/S0022169403002579) ·
  [PDF](https://www.oocities.org/haniskywalker/hock2003.pdf)
- **Braithwaite, R. (1995).** *Positive degree-day factors for ablation on the
  Greenland ice sheet…* J. Glaciology 41, 153–160. (Über Hock 2003 §2 referiert;
  DDF Schnee 3–5, Eis 5–8 mm w.e. d⁻¹ K⁻¹.)
- **Jennings, K., Winchell, T., Livneh, B. & Molotch, N. (2018).** *Spatial
  variation of the rain–snow temperature threshold across the Northern
  Hemisphere.* Nature Communications 9, 1148.
  [Nature](https://www.nature.com/articles/s41467-018-03629-7)
- **Kienzle, S. (2008).** *A new temperature based method to separate rain and
  snow.* Hydrological Processes 22, 5067–5085. (Doppelschwellen-/Sigmoid-Ansatz;
  50 % bei ~2 °C, Übergangsband ~13 K.)
- **Liebl, M., Hergarten, S. & Egholm, D. (2023).** *Modeling large-scale landform
  evolution with a stream power law for glacial erosion (OpenLEM v37): benchmarking
  experiments against a more process-based description of ice flow (iSOSIA v3.4.3).*
  Geosci. Model Dev. 16, 1315–1343.
  [GMD](https://gmd.copernicus.org/articles/16/1315/2023/) ·
  doi:10.5194/gmd-16-1315-2023
- **Egholm, D. et al. (2011/2012).** *Modeling the flow of glaciers in steep
  terrains: the integrated second-order shallow ice approximation (iSOSIA).*
  JGR Earth Surface.
  [Übersicht](https://www.researchgate.net/publication/235735517)
- **Le Meur, E., Gagliardini, O., Zwinger, T. & Ruokolainen, J. (2004).** *Glacier
  flow modelling: a comparison of the Shallow Ice Approximation and the full-Stokes
  solution.* C. R. Physique 5, 709–722.
  [PDF](https://courses.seas.harvard.edu/climate/eli/Courses/global-change-debates/Sources/Mountain-glaciers/more/LeMeur-etal-2004-glaceirs-and-SIA.pdf)
- **Herman, F. et al. (2015).** *Erosion by an Alpine glacier.* Science 350,
  193–195.
  [PDF](https://web.gps.caltech.edu/~avouac/publications/Science-2015-Herman-193-5.pdf)
- **Humphrey, N. & Raymond, C. (1994).** *Hydrology, erosion and sediment
  production in a surging glacier: Variegated Glacier, Alaska, 1982–83.*
  J. Glaciology 40, 539–552. (Lineares Erosionsgesetz, l = 1.)
- **OGGM (2020).** *Numerics in OGGM's ice dynamics model* — SIA-Geschwindigkeits-
  form (Deformation + Gleiten) und die numerischen Stabilitätsprobleme.
  [oggm.org](https://oggm.org/2020/07/08/numerics/)
- **Bueler, E. & Brown, J. (2009) / PISM-Umfeld** — expliziter SIA-Zeitschritt
  `max D · Δt < ½ Δx²`.
  [arXiv:0810.3449](https://arxiv.org/pdf/0810.3449)
- **ICAO / U.S. Standard Atmosphere** — Temperaturgradient 6,50 °C/km bis 11 km.
  [Lapse rate (Übersicht mit ISA/DALR/SALR)](https://en.wikipedia.org/wiki/Lapse_rate)

Code-Bezüge: `SimCore/Sources/SimCore/Terrain.swift` (`computeRain`,
`updateVegetation`, `updateHeightBands`, `step`),
`SimCore/Sources/SimCore/HeightBands.swift`,
`SimCore/Sources/SimCore/Config.swift` (Kalibrier-Logbuch),
`SimCore/Sources/SimCore/WorldSnapshot.swift` (Feldinventar),
`Extension/Sources/RiverSimGD/SimNode.swift` (`terrainColorBytes`).

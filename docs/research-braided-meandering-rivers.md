# Research: Visibly dynamic braided + meandering rivers

Goal: make rivers **visibly** dynamic in a real-time time-lapse — channels that
meander, **split around bars and rejoin** (braiding / anabranching), and loops
that **pinch off into oxbow lakes**. The current model recomputes a single-flow
**D8** network every tick, so the steepest-neighbour choice snaps between cells
and rivers appear to teleport.

This document is written against the existing SimCore (see file references
inline). It surveys primary sources, gives the core equations/parameters, and
ends with a **risk-ranked implementation path** whose first step is a *headless
measurement* of whether braiding emerges — before touching the tuned look.

Sim facts this doc assumes (from `SimCore/Sources/SimCore/`):
- FastScape implicit stream-power, n=1: `dz/dt = U − K·Aᵐ·S`, `mExp=0.5`,
  `kRock=3.5e-5`, `kSed=1.1e-4` (`Terrain.streamPower`, `Config.swift`).
- SPACE-like transport-limited pass `Qc = Kt·Aᵐ·S`, `transportCap=9.0`
  (`Terrain.transportLimited`).
- Priority-Flood depression filling (Barnes) → `hf`, plus `order[]` ascending
  fill-height (`Terrain.priorityFlood`).
- **D8 single receiver** `computeReceiversAndArea()` — steepest of 8 on `hf`,
  drainage area accumulated in reverse `order` (Terrain.swift:258–291).
- Droplet/particle hydraulic pass (`Hydraulic.erode`).
- A **Lagrangian centreline meander module** already exists (`Meander.swift`,
  `MeanderState.migrate`), currently `meanderEnabled=false`.
- Grid 640×640, height normalized ~ −0.3..1.4, must stay deterministic and
  headless-testable.

---

## 0. TL;DR of the diagnosis

Braiding, meander migration, and oxbow cutoff are **three different
phenomena at three different scales**, and no single trick delivers all three:

| Phenomenon | Physical minimum | Cheapest model that shows it |
|---|---|---|
| River splits around a bar & rejoins | multi-cell flow + a bar to split around | **MFD routing** (splits flow) + **deposition that builds bars** |
| Channel wanders smoothly (no teleport) | continuous flow field with memory | **MFD area** (continuous in topography) or a persistent wetted-depth field |
| Loop pinches off → oxbow | a persistent *centreline* with memory | the **Lagrangian meander module you already have** |

The D8→MFD switch is the single highest-leverage change: it simultaneously (a)
lets one river split and rejoin, (b) removes the argmax teleport, and (c) is a
localized, testable change to two functions. Meandering + oxbows stay in the
Lagrangian module (grid MFD alone will **not** produce clean oxbow cutoffs).

---

## 1. Multi-flow-direction (MFD) routing as a replacement for D8

### 1.1 The partition rule

D8 sends **all** of a cell's flow to the single steepest lower neighbour. MFD
sends a *fraction* `fᵢ` to **every** lower neighbour, weighted by slope:

**Freeman (1991) / Holmgren (1994)** — the power-law form used almost everywhere:

```
        max(0, Sᵢ)ᵖ
fᵢ = ─────────────────────        (sum only over neighbours with Sᵢ > 0)
      Σⱼ max(0, Sⱼ)ᵖ

Sᵢ = (h_k − h_i) / dᵢ             dᵢ = 1 (cardinal) or √2 (diagonal)
```

- `p → 1`: maximally **dispersive** (flow spreads onto ridges — unphysical on
  hillslopes, but *this is what braids/anabranches*).
- `p → ∞`: recovers **D8** (all flow to steepest). Holmgren (1994) proposed
  exactly this generalized exponent to tune convergence.
- **Freeman (1991)** recommends **p = 1.1** as the value that minimizes the grid
  directional bias (p>1.1 biases toward cardinal/ordinal axes; p<1.1 biases
  away). This is the canonical default for hydrology.
- **Holmgren (1994)** recommends **p ≈ 4–6** when you want realistic
  *convergence* into valleys (dendritic look) rather than sheet dispersion.

**Quinn et al. (1991)** — same idea, contour-length weighting instead of a free
exponent:

```
fᵢ = (Sᵢ · Lᵢ) / Σⱼ (Sⱼ · Lⱼ)
```

`Lᵢ` = effective contour length the flow crosses (≈ 0.5·dx for cardinal,
≈ 0.354·dx for diagonal in the original; various tunings exist). Effectively
`p=1` with a geometric correction. Quinn's own later work (1995) makes the
exponent *discharge-dependent* to converge in channels and spread on hillslopes
— a precedent worth noting for a hybrid.

**Tarboton (1997) D-∞** — the "cleaner" MFD. Flow direction is a single
**continuous angle** α ∈ [0, 2π), computed as the steepest downslope on the 8
triangular facets of the 3×3 window. Flow is split between the **two** grid
neighbours that bracket α, weighted by angular proximity:

```
facet neighbours n₁, n₂ bracket α with sub-angles α₁, α₂ (α₁+α₂ = facet angle)
f₁ = α₂ / (α₁+α₂),   f₂ = α₁ / (α₁+α₂)
```

D-∞ gives at most 2 receivers per cell (cheaper, less sheet-spread than full
Freeman MFD) and — crucially for us — the weights vary **continuously** as
topography changes, so the flow pattern *slides* instead of *snapping*. This is
the best fit for "smooth channel motion". A recent, careful comparison of these
routers on regular grids is Anand et al. (ESurf 13:239, 2025).

### 1.2 Drainage-area accumulation with MFD (is topological order still valid?)

Yes. MFD still defines a **DAG** (every receiver is strictly lower on `hf`, so
no cycles once depressions are filled). Accumulation is the same reverse
topological sweep you already do — you just distribute to several receivers:

```
for k in order  (descending hf, i.e. your reverse `order`):
    for each receiver i of k:
        A[i] += f[k→i] · A[k]
```

Your existing `order[]` from Priority-Flood (ascending fill-height) is a **valid
topological order** for MFD too, because every partition target is lower in `hf`.
So `computeReceiversAndArea()` (Terrain.swift:258) generalizes with almost no new
machinery: store, per cell, a small list `(receiver, fraction)` instead of one
`Int32`, and accumulate `A` in the same reverse loop (Terrain.swift:285–290).

**Does MFD let one "river" split around a bar and rejoin?** Yes — this is the
core reason to adopt it. Where a mid-channel bar (a local high) sits in the flow,
both flanking cells receive `Sᵢ>0` and get positive fractions, so `A` stays high
on **both** sides and drops toward zero on the bar. Rendering channel width /
wetness ∝ `Aᵖ` then shows **two threads around an island that merge downstream**.
D8 physically *cannot* show this — the bar forces a single binary choice and the
whole river jumps to one side.

### 1.3 Numerical stability of stream-power with multiple receivers

The FastScape implicit update you use (Terrain.swift:315) assumes **one**
receiver:

```
h_k^{t+1} = (h_k^t + f·h_r) / (1 + f),   f = K·dt·Aᵐ / d
```

This is unconditionally stable *because* it's a 1-receiver linear recurrence
solved in downstream→upstream order. With MFD there are two established options:

1. **Braun & Willett (2013) stack, MFD variant** (used by FastScapeLib's
   `MultipleFlowRouter` and gospl/Cordonnier et al. 2019): keep the implicit
   scheme but define incision against the **weighted-average receiver elevation**
   `h̄_r = Σ fᵢ hᵢ` and effective distance `d̄ = Σ fᵢ dᵢ`. The recurrence stays
   `h_k = (h_k + f·h̄_r)/(1+f)` and remains stable if processed in the same
   descending-`hf` order (all receivers already finalized). **Caveat:** stability
   requires every receiver to be strictly below `h_k`; enforce this by only
   partitioning to cells with `Sᵢ>0` (you already gate on `h[k]>hr`).

2. **Split A, keep D8 incision:** route drainage area with MFD (for *width /
   wetness / where sediment goes*) but keep the single-receiver **steepest**
   neighbour for the incision update. This decouples the risky part (incision
   stability, and your carefully tuned terrain look) from the visible part
   (multi-thread wetness). Lowest risk; see the implementation path §6.

**Practical stability notes.** MFD raises `A` on hillslopes (flow no longer
funnels to one line), so `K·Aᵐ` grows on many cells → if you feed MFD area into
incision, effective erosivity rises and you may need to lower `K` a bit. Higher
`p` (4–6) keeps `A` concentrated and keeps the look close to today's dendritic
result; low `p` (~1.1) is where braiding lives but also where the terrain look is
most at risk. This is the central tradeoff.

**Maps onto our sim:** `computeReceiversAndArea()` becomes MFD; `order[]` is
reused unchanged; `streamPower()` either uses `h̄_r`/`d̄` (option 1) or is left on
D8 while only `area[]` goes MFD (option 2). `transportLimited()` (the SPACE pass)
is where bars actually get built (§2), so MFD area feeding *that* pass is what
produces visible islands.

---

## 2. Cellular / reduced-complexity braided-river models

### 2.1 Murray & Paola (1994, Nature 371:54; 1997) — the minimal braiding recipe

The landmark result: **the only ingredients essential for braiding are (a)
bedload sediment transport and (b) laterally unconstrained free-surface flow over
a cohesionless bed.** No secondary circulation, no bank model, no meander theory.
Braiding is a *free instability* of sediment-laden sheet flow.

The model on a grid, marching downstream row by row:

1. **Water routing (spread).** Discharge arriving at a cell is partitioned to the
   three (or more) downstream neighbours in proportion to a power of the
   water-surface slope:
   ```
   Qw_i ∝ Sᵢ^0.5           (the 0.5 comes from a turbulent friction law)
   ```
   (This is just MFD, §1, with p≈0.5 — very dispersive.)
2. **Sediment flux — the nonlinearity that makes bars.** Bedload capacity is a
   **super-linear** power of local discharge×slope:
   ```
   Qs_i = K · (Qw_i · Sᵢ)ᵐ            with m ≈ 2.5   (their "n"/exponent)
        + lateral term (moves a fraction of Qs to lower cross-stream neighbours)
   ```
   Because `m > 1`, a small extra discharge in one thread transports
   *disproportionately* more sediment → that thread scours deeper → captures more
   flow → **positive feedback that concentrates flow into threads**, while the
   starved neighbours **deposit** and build **bars**. The lateral term smears
   sediment sideways so bars have finite width and threads reorganize.
3. **Bed update (mass conservation).** `Δz = (Qs_in − Qs_out)/cell` per sweep:
   flux **convergence → deposition** (bar growth), **divergence → scour**
   (thread deepening).

**The three minimal ingredients, restated for us:** (a) sediment transport with
**deposition that builds topographic bars** — you have this in
`transportLimited()`; (b) flow that **spreads across multiple cells** — this is
exactly the missing MFD from §1; (c) a **nonlinearity / lateral mechanism** so
threads self-organize — the `m>1` capacity exponent plus a lateral sediment
nudge. **You already have (a) and can add (b); (c) is the small new piece.**

Murray & Paola (1996, WRR) and Doeschl-Wilson & Ashmore (2005) validate that this
cellular model reproduces real braiding statistics (braiding index, bar
wavelength) — it is not just visually plausible.

### 2.2 Nicholas (2013) & CAESAR-Lisflood — the continuum

**Nicholas (2013), ESPL 38:1187, "Modelling the continuum of river channel
patterns"** (model HSTAR): a single 2-D morphodynamic model produces
**straight → meandering → braided → anabranching** just by varying a few
parameters — chiefly **sediment supply/erodibility, bank strength, and
discharge**. The takeaway for us: braided-vs-meandering need not be two code
paths; it can be one model in different parameter regimes (see §3 on coexistence
and §5 for the knobs).

**CAESAR-Lisflood (Coulthard & Van De Wiel; Coulthard et al. 2013)** — a widely
used reduced-complexity LEM that produces braiding at catchment scale by
combining: a LISFLOOD-FP shallow-water flow field (flow with **memory** — a
persistent water-depth grid, not a per-tick argmax), multi-direction flow, a
bedload law (Wilcock–Crowe or Einstein), and **lateral bank erosion by
edge-counting radius-of-curvature** (Coulthard & Van de Wiel 2006). Its lateral
erosion coefficient is a direct braided-vs-meandering dial (§5).

### 2.3 Braiding index intuition & what controls the pattern

**Braiding index (BI)** = mean number of *active* channels crossed on a transect
perpendicular to the valley. Single-thread ≈ 1; braided > ~1.5, commonly 2–5+.
An easy headless proxy on a grid: threshold "wet" cells (`A > A_channel`), then
for each row (or valley cross-section) **count connected wet runs** and average.
BI rising above 1 over time = braiding emerged. This is the metric to build
first (§6, step 0).

**What pushes a reach toward braided vs single-thread vs meandering:**

| Control | Braided | Meandering |
|---|---|---|
| Slope / stream power | high | low |
| Sediment supply (esp. bedload) | high | low–moderate |
| Bank cohesion / **vegetation** | low (erodible, cohesionless) | high (cohesive, vegetated) |
| Discharge variability (flashy) | high | steady |
| Width/depth ratio | high (wide, shallow) | low |

Leopold & Wolman (1957) threshold (classic, order-of-magnitude):
`S > 0.0125 · Q_bankfull^(−0.44)` → braided. You have `veg` and `rain`
(→discharge) fields already — they are the natural handles to make *some reaches*
braid and others meander (§3).

---

## 3. Meander migration + oxbow cutoff, and coexistence with grid erosion

### 3.1 The bend-theory migration law (Ikeda–Parker–Sawai 1981; Howard–Knutson 1984)

A meandering centreline migrates laterally at rate `M(s)` proportional to a
**near-bank excess velocity** `u_b`, which is driven not by *local* curvature
alone but by curvature **integrated upstream with exponential decay** (this
upstream weighting is what makes bends grow asymmetrically and translate
downstream — the classic look):

```
Ikeda–Parker–Sawai (linear bend theory):
u_b(s) = −C·C(s) + (integral of upstream curvature, exponentially weighted)

Howard–Knutson (1984) nominal rate:
M(s) = E · Ω(s)
Ω(s) = ω₀·C(s) + ω₁·∫₀^∞ C(s−ξ)·e^{−(2Cf/H)ξ} dξ
```

- `C(s)` = local curvature = `1/R`, `R` = radius of curvature.
- `E` (or `E₀`) = dimensionless **bank erodibility / migration coefficient** —
  the master rate knob. Field-calibrated values are tiny: `E ≈ 10⁻⁷ … 10⁻⁸`
  (per unit) in Howard-style models; you tune to a target rate (cells/kyr).
- Decay length `≈ H/(2Cf)` (depth / friction) sets how far upstream curvature
  matters — typically a few channel widths.
- `Cf` friction ≈ 0.002–0.01; width/depth and Froude set the secondary-flow gain.

Migration **saturates sinuosity around 2.5–3.5** before cutoffs cap it — matching
your module's comment ("sättigt Sinuosität ~2.3").

### 3.2 Oxbow cutoff → lake

Two mechanisms; you want **neck cutoff** for the "arm forms and closes" look:

- **Neck cutoff:** as a loop grows, its neck narrows; when neck width < ~1–2
  channel widths, the river short-circuits across it. The abandoned loop becomes
  an **oxbow lake**, then slowly fills with fines (deposition) over
  centuries–millennia. Your `Meander.applyCutoffs` + `meanderNeckDist=1.2` +
  `oxbowFillYears=6000` / `oxbowMaxAge=25000` already model exactly this.
- **Chute cutoff:** a high-flow shortcut across the point bar (more common in
  steeper/sandier reaches); this is closer to a *braiding* avulsion.

### 3.3 How meandering and braiding coexist in ONE model (or partition by reach)

Two viable architectures — recommend the second for your risk profile:

- **(A) Emergent from one grid model (Nicholas/CAESA R style).** Braiding and
  meandering both fall out of MFD flow + bedload + lateral bank erosion; the
  pattern is selected locally by slope, sediment, and bank strength. Elegant, but
  clean neck-cutoff oxbows are *hard* to get from a pure Eulerian grid at 640²
  resolution — the loop is only a few cells wide, so the pinch-off is mushy.
- **(B) Partition by reach (recommended).** Use a **per-reach regime switch**
  driven by fields you already have:
  ```
  local stream power  ω ∝ A·S   (or valley slope S alone)
  regime = braided     if S > S_braid  AND  veg < veg_lo   (high energy, erodible)
         = meandering  if S < S_flat    AND  veg > veg_hi   (low energy, cohesive)
         = single-thread otherwise
  ```
  Braided reaches → grid MFD + deposition (§1–2). Meandering reaches → the
  **Lagrangian centreline module you already have** (which does clean oxbows).
  `meanderFlatSlope=0.02` is already exactly this gate ("nur unter dieser Steigung
  mobil"). This keeps the crisp oxbow behaviour where the grid can't deliver it,
  and puts braiding where the grid *can*.

**Maps onto our sim:** meandering already lives in `Meander.swift` /
`meanderStamp` and is gated by `meanderFlatSlope`. Braiding is a *grid* property
(MFD area + `transportLimited` deposition). They don't fight if the meander
module owns the low-slope/high-veg reaches and the grid owns the rest — which is
already the structure implied by `isChannel`/`channelErodeDamp` reconciliation.

---

## 4. Making dynamics VISIBLE without the network "jumping"

### 4.1 Why D8 teleports and MFD does not

D8 receiver = `argmax` over 8 slopes (Terrain.swift:268–279). `argmax` is a
**discontinuous** function of the heights: an infinitesimal change that makes
neighbour B slightly steeper than A flips the *entire* downstream path from A to
B in one tick → the rendered river snaps across the cell. Because you recompute
the network every tick on a continuously-eroding surface, ties flip constantly.

MFD/D-∞ replaces `argmax` with a **continuous partition** (`fᵢ` are smooth
functions of the slopes). When B overtakes A, flow shifts **gradually** from A to
B (fractions cross over continuously) instead of snapping. **So yes — MFD/D-∞
inherently move more smoothly.** D-∞ is the smoothest (its direction is a
continuous angle). This is the single biggest fix for the teleport artifact and
comes *for free* with the §1 change.

### 4.2 Temporal-coherence techniques (belt-and-suspenders)

Even with MFD, per-tick recomputation of `A` on a noisy surface flickers. Cheap,
deterministic smoothers (all headless-friendly):

1. **EWMA on the rendered/routing field.** Keep a persistent `wet[]` (or
   `Adisplay[]`) and relax it toward the freshly computed value each tick:
   `wet ← (1−λ)·wet + λ·A_new`, `λ ≈ 0.05–0.2`. Gives channels *memory*; a thread
   fades in/out over many frames instead of blinking. Deterministic, O(N),
   trivial to test.
2. **Persistent wetted-depth field (LISFLOOD/CAESAR idea).** Instead of
   recomputing routing from scratch, evolve a shallow-water depth `d[]` that
   carries over between ticks. Depth has inherent inertia → channels move
   smoothly. Heavier; a bigger change than EWMA.
3. **Sub-tick / chunked stepping consistency.** You already made diffusion
   framerate-independent (`step()` sub-steps). Make routing-derived visuals use
   the same `dt`-scaled relaxation so a 0.2-yr frame and a 10 000-yr jump land in
   the same place.
4. **Channel as a persistent object (Lagrangian).** The meander centreline
   *is* a memory structure — it never teleports because it stores its own
   position and only migrates by `M·dt`. This is why oxbows must stay Lagrangian.

**Recommendation:** MFD (§1) for the physics + **EWMA `wet[]`** for rendering is
90% of the visual win for ~30 lines and near-zero risk to terrain.

---

## 5. Concrete parameter regimes / calibration seeds

| Quantity | Symbol | Typical range | Source | Sim seed suggestion |
|---|---|---|---|---|
| MFD slope exponent (hydrology default) | p | **1.1** | Freeman 1991 | start p=1.1 for max braiding realism… |
| MFD exponent (dendritic convergence) | p | **4–6** | Holmgren 1994 | …but p≈4 to *protect current look*; sweep down |
| D-∞ receivers | — | ≤2 per cell | Tarboton 1997 | cheapest smooth option |
| Water-routing exponent (braided model) | — | **0.5** | Murray & Paola 1997 | for a dedicated braided pass |
| Bedload capacity exponent (the braiding nonlinearity) | m | **≈2.5** (2–3) | Murray & Paola 1994 | raise `transportLimited` capacity exponent on high-energy reaches; **>1 is essential** |
| Your current SPACE area exponent | m | 0.5 | `Config.mExp` | fine for *area*; the *capacity nonlinearity* is separate |
| Lateral (bank) erosion coeff — braided | — | **0.01–0.001** | CAESAR (Coulthard & Van de Wiel) | high lateral mobility → braids |
| Lateral (bank) erosion coeff — meandering | — | **~0.0001** | CAESAR | your `meanderBankErode=1.2e-4` ✓ already in this band |
| Meander migration coeff | E, E₀ | **10⁻⁷–10⁻⁸** | Howard & Knutson 1984 | your `meanderMigration=5e-5` is in "cells·discharge" units — calibrate to a target cells/kyr, not to E directly |
| Upstream-curvature decay length | H/(2Cf) | few channel widths | Ikeda et al. 1981 | your `meanderSkewLength=4` cells ✓ plausible |
| Friction | Cf | 0.002–0.01 | std. | — |
| Neck-cutoff threshold | — | 1–2 channel widths | Howard 1984 | `meanderNeckDist=1.2` ✓ |
| Braiding slope threshold | S | `S > 0.0125·Q^−0.44` | Leopold & Wolman 1957 | use as the reach regime gate (§3.3) |
| Sinuosity saturation | — | ~2.5–3.5 | Howard 1984 | matches module note |

**Regime map (Nicholas 2013 continuum), in your fields:** high `A·S` + low `veg`
→ braided; low `S` + high `veg` → meandering; else single-thread.

---

## 6. Recommended implementation path (ranked by impact ÷ risk-to-look)

Ranked so the **highest impact per unit risk** comes first, and the very first
item is a pure *measurement* that changes no physics.

### Step 0 — Measurement harness (no physics change; do this first)
Add a headless diagnostic to the test suite:
- **Braiding index BI(t):** threshold `A > A_channel`, count connected wet runs
  per row across the main valley, average. Report BI over a 100 k-yr run.
- **Channel jitter J(t):** you already have `receiverAgreement(with:)`
  (Terrain.swift:897). Log per-tick receiver-agreement as the *teleport* metric —
  low agreement between adjacent ticks = jumping.
- **Oxbow count / sinuosity** from `MeanderState` (already computable).

Deliverable: a test that prints `BI, meanJitter, sinuosity` for a fixed seed.
Now every later change is *measured*, per the "erst headless messen" lesson in
MEMORY.md. **Risk: zero. Impact: unblocks everything.**

### Step 1 — MFD **drainage area only**, keep D8 incision (highest impact ÷ risk)
In `computeReceiversAndArea()` store per-cell `(receiver,fraction)` via Freeman
weights (start `p=4`, Holmgren, to stay near the current dendritic look), and
accumulate `area[]` over multiple receivers in the same reverse-`order` loop.
**Leave `streamPower()` / `outletIncision()` on the single steepest receiver** so
the tuned terrain look and incision stability are untouched. Render channel
wetness ∝ `Aᵖ` from the MFD area.
- Expected: rivers **split around bars and rejoin**; teleport largely gone (area
  is now continuous in topography). Measure BI↑ and jitter↓ vs Step 0 baseline.
- **Risk to look: low** (incision unchanged). Sweep `p` from 4→1.5 watching BI vs
  terrain metrics; stop where braiding appears before the look degrades.

### Step 2 — EWMA `wet[]` for temporally-coherent rendering
Persistent `wet ← (1−λ)·wet + λ·A_new`, `λ≈0.1`, `dt`-scaled. Kills residual
per-tick flicker. **Risk: ~zero** (render-only). Big *perceived* smoothness win.

### Step 3 — Deposition that builds bars (make braids *persist*)
Feed MFD area into `transportLimited()` and ensure flux-convergence deposits on
the low-flow cells between threads (bars), with a **super-linear capacity
exponent (m≈2.5)** on high-energy reaches (Murray & Paola). Add a small **lateral
sediment nudge** so bars have finite width. This turns transient flow-splitting
into *stable islands that migrate*.
- **Risk: medium** — touches sediment mass balance (your SPACE pass). Gate it to
  high-`A`, low-`veg` reaches first so the general terrain look is unaffected;
  measure BI persistence over time.

### Step 4 — Re-enable the Lagrangian meander module on low-energy reaches
Flip `meanderEnabled=true` but **gate by regime** (§3.3): active only where
`S<meanderFlatSlope` and `veg` high. This delivers **smooth meandering + clean
neck-cutoff oxbows** exactly where the grid can't. Reconcile with the grid via
the existing `isChannel`/`channelErodeDamp` path. The module's own note says it
"runs unstably with droplet erosion" — so introduce it *after* the MFD field is
smoother (Steps 1–2 reduce the shock) and keep it off steep reaches.
- **Risk: medium** (previously destabilized). Mitigation: regime gating +
  measure with Step 0 metrics; keep droplet pass off meander-owned cells.

### Step 5 (optional) — D-∞ instead of Freeman for the smoothest motion
If residual grid-axis bias shows, swap Freeman for **Tarboton D-∞** (≤2 receivers,
continuous angle). Marginal extra smoothness; do only if Steps 1–2 leave visible
faceting. **Risk: low, impact: incremental.**

**Rationale for the ordering:** Steps 0–2 are nearly risk-free to the tuned
terrain and already deliver *split-and-rejoin* + *no teleport* — the two most
visible wins. Steps 3–4 add *persistence* and *oxbows* but touch mass balance /
the previously-unstable meander module, so they come later and stay reach-gated
and measured.

---

## Sources

Primary:
- Freeman, T.G. (1991) *Calculating catchment area with divergent flow based on a
  regular grid.* Computers & Geosciences 17:413–422.
- Quinn, P. et al. (1991) *The prediction of hillslope flow paths for distributed
  hydrological modelling using digital terrain models.* Hydrol. Processes 5:59–79.
- Holmgren, P. (1994) *Multiple flow direction algorithms for runoff modelling in
  grid based elevation models: an empirical evaluation.* Hydrol. Processes 8:327–334.
  https://www.researchgate.net/publication/229484151
- Tarboton, D.G. (1997) *A new method for the determination of flow directions and
  upslope areas in grid digital elevation models (D-∞).* Water Resources Research
  33(2):309–319. https://agupubs.onlinelibrary.wiley.com/doi/10.1029/96WR03137
- Murray, A.B. & Paola, C. (1994) *A cellular model of braided rivers.* Nature
  371:54–57. https://www.nature.com/articles/371054a0
- Murray, A.B. & Paola, C. (1997) *Properties of a cellular braided-stream model.*
  Earth Surf. Process. Landforms 22:1001–1025.
- Murray, A.B. (1996) *A new quantitative test of geomorphic models, applied to a
  model of braided streams.* WRR. https://agupubs.onlinelibrary.wiley.com/doi/10.1029/96WR00604
- Nicholas, A.P. (2013) *Modelling the continuum of river channel patterns.* Earth
  Surf. Process. Landforms 38:1187–1196.
  https://www.researchgate.net/publication/263178913
- Coulthard, T.J. & Van De Wiel, M.J. (2006) *A cellular model of river meandering.*
  Earth Surf. Process. Landforms; Coulthard et al. (2013) *CAESAR-Lisflood.*
  https://github.com/tcoulthard/caesar-lisflood/wiki
- Ikeda, S., Parker, G. & Sawai, K. (1981) *Bend theory of river meanders. Part 1.*
  J. Fluid Mech. 112:363–377.
- Howard, A.D. & Knutson, T.R. (1984) *Sufficient conditions for river meandering:
  a simulation approach.* Water Resources Research 20:1659–1667.
- Braun, J. & Willett, S.D. (2013) *A very efficient O(n), implicit and parallel
  method to solve the stream power equation.* Geomorphology 180–181:170–179.
  https://www.researchgate.net/publication/236741975
- Cordonnier, G., Bovy, B. & Braun, J. (2019) *A versatile, linear complexity
  algorithm for flow routing in topographies with depressions.* Earth Surf. Dynam.
- Barnes, R. et al. (2014) *Priority-flood depression filling.* Computers & Geosciences.
- Leopold, L.B. & Wolman, M.G. (1957) *River channel patterns: braided, meandering
  and straight.* USGS Prof. Paper 282-B.

Reviews / secondary:
- Williams, R.D. et al. (2016) *Numerical modelling of braided river morphodynamics:
  review and future challenges.* Geography Compass.
  https://compass.onlinelibrary.wiley.com/doi/10.1111/gec3.12260
- *A review of numerical modelling of morphodynamics in braided rivers* (2023) Water
  15:595. https://doi.org/10.3390/w15030595
- Anand, S.K. et al. (2025) *An evaluation of flow-routing algorithms for calculating
  contributing area on regular grids.* Earth Surf. Dynam. 13:239.
  https://esurf.copernicus.org/articles/13/239/2025/
- Doeschl-Wilson, A.B. & Ashmore, P.E. (2005) *Assessing a numerical cellular
  braided-stream model with a physical model.* ESPL.
  https://onlinelibrary.wiley.com/doi/abs/10.1002/esp.1146

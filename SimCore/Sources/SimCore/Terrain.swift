import Foundation

/// Rolle einer Zelle im Wasserhaushalt abflussloser Becken (Issue #11) —
/// der Zustand hinter `Terrain.endorheicBasin`.
///
/// Die Rohwerte sind das Speicherformat: `endorheicBasin` liegt als ein Byte je
/// Zelle im Schnappschuss (`WorldSnapshot.uint8Fields`), und diese Zuordnung
/// 0/1/2 ist damit Teil des Dateiformats — beim Ändern bräuchte es eine neue
/// Snapshot-Version.
public enum BasinRole: UInt8, Sendable {
    /// Kein verdunstungs-limitiertes Becken (Normalfall: der See läuft bis zur
    /// Sill über — exakt das Verhalten vor Issue #11).
    case none = 0
    /// Trockengefallener Beckenboden (Playa: hier stand Wasser, bis die Bilanz
    /// den Spiegel gesenkt hat).
    case dryBed = 1
    /// Wasserfläche eines abflusslosen Beckens = **terminale Senke**: das Wasser
    /// verlässt sie nur über die Verdunstung, nicht über die Sill
    /// (`receiver` = −1, kein MFD-Überlauf, keine Auslass-Inzision).
    case water = 2

    /// Rolle aus einem gespeicherten Byte. Unbekannte Werte (fremde/defekte
    /// Datei, die Prüfsumme deckt nur Transportfehler ab) werden zu `.none` —
    /// dem neutralen Zustand, den `capEndorheicBasins` im nächsten Schritt
    /// ohnehin neu bestimmt; ein Absturz oder eine halb typisierte Welt wäre
    /// die schlechtere Antwort.
    public init(persisted byte: UInt8) {
        self = BasinRole(rawValue: byte) ?? .none
    }
}

/// Der Simulationskern: hält alle Felder und führt die Landschaftsentwicklung
/// aus. Kennt bewusst KEIN Godot — dadurch headless mit XCTest testbar.
///
/// Entwässerung über Priority-Flood (Barnes et al.) → füllt Senken, damit Flüsse
/// bis zum Meer routen; Seen = Zellen mit Füllhöhe > Geländehöhe. Zwei Netze mit
/// strikt getrennten Rollen: **D8/`area`** speist die Erosion, **MFD/`areaMFD`**
/// (Freeman/Quinn) NUR Render und Braiding.
///
/// Pass-Reihenfolge des Produktionspfads (`cfg.hydraulicEnabled`, LEM-Konvention
/// — sie ist nicht beliebig, s. `step()` und docs/research-terrain-aging.md §4):
///
///     Uplift (abklingend U(t), Servo nur als Untergrenze)
///     → Lithologie (Härte/Erodierbarkeit aus der frischen Höhe, Issue #12)
///     → computeFlow (Priority-Flood, D8, MFD)
///     → Gletscher (updateIce: Eisfluss, glaziale Erosion, Moränen, Issue #35)
///     → Mäander (migrate + stamp) → outletIncision → Pfützen/Seen → braidPass
///     → Droplet-Erosion (Hydraulic.erode) + Stream-Map-EWMA → Hangdiffusion
///     → Wave → Klima-Vertikale (Temperatur + Schnee) → Vegetation
///
/// Der Gletscher-Pass steht bewusst zwischen Abflussfeld und fluvialer
/// Makro-Inzision: er braucht das frische Bett, und seine Maske `underIce`
/// legt den fluvialen Abtrag unter dem Eis still — seit Issue #96 über den
/// EINEN Bett-Funnel (`erodeCell`/`depositCell` samt ihrer Fassungen), über
/// den JEDE fluviale Bett-Bewegung schreibt: Mäander-Carve und -Ufer,
/// Altarme, Braid-Fracht, Auen-Aggradation, Auslass-Inzision, Tropfen und
/// Pinsel. Nur die Hangdiffusion läuft bewusst auch auf Eiszellen
/// (kein fluvialer Pass, s. `docs/glacier-measurements.md` §I.1).
///
/// Die fluviale Makro-Inzision ist damit `outletIncision` (Flächen-Stream-Power
/// auf dem Entwässerungsnetz, impliziter n=1-Solver in Empfänger-Reihenfolge →
/// unbedingt stabil bei großen Zeitschritten); die feine dendritische Textur
/// legen die Tropfen (`Hydraulic.erode`), gerundet wird über LINEARE
/// Hangdiffusion mit räumlich variablem kappa (`hillslopeDiffusion`) — nicht
/// über Schwellen-Talus. Beide Raten (fluvial und Hang) werden zusätzlich vom
/// **Gesteinsfeld** moduliert (`lithHardness`/`lithErodeK`, Issue #12): harte
/// Bänke tragen Schichtstufen, Mesas und lithologische Knickpunkte.
///
/// Der Nicht-Droplet-Zweig (`hydraulicEnabled = false`, `transportLimited` +
/// `diffusionPass`) ist reiner TESTPFAD, s. Kommentare dort.
public final class Terrain {
    public let cfg: SimConfig
    private let n: Int

    // Kernfelder
    public private(set) var h: [Double]      // Geländehöhe (rock + sed)
    public private(set) var rock: [Double]   // hartes Grundgestein
    public private(set) var sed: [Double]    // lockeres Sediment
    public private(set) var upliftBase: [Double] // tektonisches Feld (±, fix je Terrain)
    public private(set) var rain: [Double]   // Luftfeuchte/Niederschlag
    /// Abfluss-GEWICHT je Zelle (Issue #10) — `rain`, normiert auf sein LANDMITTEL,
    /// über See auf den neutralen Wert 1.0 gesetzt. Leer, solange
    /// `cfg.rainWeightedFlow` aus ist (dann laufen alle Pfade bit-identisch zum
    /// Stand vor Issue #9). Gefüllt am Ende von `computeRain`, verbraucht von
    /// `seedFlowAccumulator` (beide Netze) und den Tropfen-Startpunkten
    /// (`Hydraulic.spawnPosition`). Herleitung: `SimConfig.rainWeightedFlow`.
    public private(set) var rainWeight: [Double] = []
    /// Abfluss-GEWICHT INKLUSIVE SCHMELZWASSER (Issue #36) — dieselbe Bauform wie
    /// `rainWeight` (Landmittel 1, über See neutral 1.0), nur speist zusätzlich die
    /// Ablation der Schneedecke ein. Gefüllt am Ende von `computeRain`
    /// (`updateRunoffWeight`), verbraucht ausschließlich über `flowWeight`.
    ///
    /// **Leer** heißt „keine Schmelze im Spiel" — dann fällt `flowWeight` auf
    /// `rainWeight` zurück und ALLE Pfade rechnen bit-identisch zum Stand vor #36.
    /// Das gilt nicht nur bei `cfg.meltRunoffEnabled = false`, sondern auch, wenn
    /// die Welt gerade nichts zu schmelzen hat (Klima aus, kein Schneefeld, oder
    /// Schnee nur in Dauerfrostlagen): `updateRunoffWeight` prüft das und lässt das
    /// Feld dann leer, statt eine Kopie von `rainWeight` zu halten.
    ///
    /// **Nicht im Zustands-Inventar** (`TerrainState`) — abgeleitet; die
    /// Begründung steht mit allen anderen an der Einordnung
    /// (`SimCoreTests/StateInventoryTests.classification`, Issue #98).
    public private(set) var runoffWeight: [Double] = []
    /// **Die EINE Quelle der Abfluss-Gewichtung** (Issue #36): Schmelz-Gewicht,
    /// wenn es eines gibt, sonst das Regen-Gewicht. Alle drei Konsumenten lesen
    /// dieses Feld und keins der beiden Rohfelder — `seedFlowAccumulator` (D8
    /// `area` UND MFD `areaMFD`) und die Tropfen-Startpunkte (`Hydraulic.erode`,
    /// Parameter `rainWeight`). Leer = ungewichtet (Zellfläche/gleichverteilt).
    ///
    /// Kein Kopieren: die Property gibt eines der beiden Arrays zurück (COW).
    public var flowWeight: [Double] { runoffWeight.isEmpty ? rainWeight : runoffWeight }
    /// **Lithologie** (Issue #12): Härte-Signal je Zelle, −1 = weichstes …
    /// +1 = härtestes Gestein. Leer, solange `cfg.lithologyEnabled` aus ist (dann
    /// laufen alle Pfade bit-identisch zum Stand vor #12). Zusammengesetzt aus
    /// der stratigraphischen Schichtwelle (hängt an `h` — deshalb wird das Feld
    /// je Schritt in `updateLithology` neu abgeleitet) und dem fixen
    /// Provinz-Rauschen. Herleitung und Kalibrierung: `SimConfig.lithologyEnabled`.
    public private(set) var lithHardness: [Double] = []
    /// Relative Erodierbarkeit je Zelle = `1 − lithContrast · lithHardness`
    /// (Mittel ≈ 1, damit die globale Kalibrierung stehen bleibt). Verbraucht von
    /// `outletIncision`, `Hydraulic.erode` (Fels-Anteil) und `transportLimited`.
    private(set) var lithErodeK: [Double] = []
    /// Referenzhöhe der Schichtebene je Zelle — geneigte Ebene + Faltungs-
    /// Verbiegung, **fix je Seed** (`buildLithologyField`). Die stratigraphische
    /// Koordinate einer Zelle ist `(h − lithBed) / lithLayerThickness`.
    private var lithBed: [Double] = []
    /// Großräumige Härte-Provinzen (−1…1), fix je Seed: Batholith gegen
    /// Sedimentbecken → strukturkontrollierte Entwässerung über ganze Landstriche.
    private var lithProvince: [Double] = []
    /// **Temperatur** je Zelle in °C (Issue #33): `T₀ − Γ·max(0, h − sea)`. Reine
    /// Ableitung aus der Höhe — deshalb je Schritt in `updateClimate` neu
    /// gerechnet, aber Teil des Inventars (dieselbe Doktrin wie `rain`/`hf`: der
    /// erste Frame nach dem Laden soll korrekt sein). Über See ist die Höhe auf
    /// `sea` geklemmt, das Meer trägt also überall `T₀`. Leer, solange
    /// `cfg.climateEnabled` aus ist. Herleitung der Kopplung Höhe → Temperatur
    /// (es gibt keinen vertikalen Meter-Maßstab!): `SimConfig.climateLapseRate`.
    public private(set) var temperature: [Double] = []
    /// **Schneedecke** als Schneewasser-Äquivalent (SWE) in abstrakten Einheiten
    /// (Issue #33) — echter Bilanz-ZUSTAND, kein abgeleitetes Feld. Akkumulation
    /// aus `rain` bei Frost, Ablation als Ratenkonstante über 0 °C; die
    /// geschlossene Lösung `S* + (S−S*)·e^(−μdt)` macht den Pass exakt
    /// dt-invariant. SWE 1.0 ≙ voll ausgebildete Dauerschneedecke
    /// (s. `SimConfig.snowAccumPerYear`). Leer, solange das Klima aus ist.
    /// Konsumenten: `snowCover(_:)` (Färbung je Zelle) und die Rückrechnung der
    /// Schneegrenze in `updateHeightBands` (Waldgrenze). KEIN Erosionspass —
    /// bewusste Scope-Grenze, s. `SimConfig.climateEnabled`.
    public private(set) var snow: [Double] = []
    /// **Eisdicke** in Höheneinheiten (Issue #33 legt das Feld an, Issue #35
    /// beschreibt es). Es reist schon jetzt mit, weil das Speicherformat bewusst
    /// keine Migration kennt: ALLE Kryo-Felder mussten in EINEN Versionssprung
    /// (`WorldSnapshot.version` 2 → 3), sonst hätte der Eisfluss eine zweite
    /// Ungültigkeits-Runde für alle Spielstände gekostet. Es ist der EINZIGE
    /// zusätzliche ZUSTAND des Gletscher-Passes — Eisfluss, Gleit-Rate und
    /// Vergletscherungs-Maske sind Ableitungen je Schritt
    /// (`docs/research-climate-cryosphere.md` §4/§6).
    ///
    /// Beschrieben von `updateIce` (Issue #35): Firn→Eis aus `snow`, Transport
    /// auf der Eis-Oberfläche `h + ice`, Ablation über `temperature`. Leer, wenn
    /// das Klima aus ist; konstant 0, solange `cfg.iceEnabled` aus ist.
    /// **`h` enthält das Eis NICHT** — es ist eine eigene Auflage über dem Bett.
    /// Die Entwässerung (`computeFlow`) läuft deshalb unverändert auf dem Bett;
    /// subglaziales Wasser folgt real ebenfalls dem Bettgefälle.
    public private(set) var ice: [Double] = []
    /// **Vergletscherungs-Maske**: `ice[k] > cfg.iceMinThickness`. Gate für den
    /// fluvialen Abtrag — unter einem Gletscher trägt kein Oberflächenwasser ab;
    /// sonst carvt dasselbe Tal ein zweites Mal, mit fluvialem statt glazialem
    /// Querschnitt. EINE Prüfstelle seit Issue #96: der Bett-Funnel
    /// `erodeCell`/`depositCell` (das Gate steht in `Terrain.Bed.erode`),
    /// über den jede fluviale Bett-Bewegung schreibt — auch die
    /// Auslass-Inzision, die Tropfenschleife (mit ihrer strengeren Maske aus
    /// Eis UND Gürtelbett, `beltDropletGate`) und der Pinsel. Nicht gegatet
    /// sind die zwei benannten Ausnahmen Hangdiffusion und Brandung: kein
    /// fluvialer Pass, trägt aber Nachbar-Änderungen auf die Eiszelle —
    /// gemessen in `docs/glacier-measurements.md` §I.1.
    /// Dieselbe Bauform wie `isChannel`: **leer heißt aus**, und wenn keine Zelle
    /// Eis trägt, wird das Feld auch geleert → das Gate ist dann
    /// bit-identisch nicht vorhanden.
    /// Die Schwelle ist dieselbe, an der in `iceFlowSubStep` Transport und
    /// Abrasion einsetzen — der dünne Saum ist damit fluvial UND nur fluvial,
    /// nie beides zugleich.
    ///
    /// Reine ABLEITUNG aus `ice` (kein Zustand, nicht im Snapshot-Inventar) —
    /// Begründung und der nötige Handgriff beim Zurückspielen stehen an der
    /// Einordnung (`SimCoreTests/StateInventoryTests.classification`, Issue #98).
    public private(set) var underIce: [Bool] = []
    /// Arbeitspuffer des Eistransports (Zwei-Phasen-Scratch, s. `iceFlowSubStep`):
    /// Ausstrom je Einheit Oberflächen-Abfall (`iceRate`), die eingefrorene
    /// Eis-Oberfläche des Teilschritts (`iceSurf`) und die lokale glaziale
    /// Erosionsrate, die Pass 2 über die Schleifspur mittelt (`iceEro`). Erst
    /// beim ersten Gletscher-Pass angelegt — ohne Eis kostet das Feature keinen
    /// Speicher.
    private var iceRate: [Double] = []
    private var iceSurf: [Double] = []
    private var iceEro: [Double] = []
    /// Zeilen-Kastensummen der Erosionsrate für die Schleifspur (`iceEroH`).
    private var iceEroH: [Double] = []
    /// Lawinen-Scratch (`SimConfig.iceAvalancheSlopeHi`): Ziel-Zelle je
    /// Quellzelle (−1 = keine Lawine) und die Netto-Änderung der Firn-Zufuhr
    /// je Zelle (Quelle −, Ziel +). `iceAvFeed` ist außerhalb der Lawinenliste
    /// immer 0 und wird am Ende jedes `updateIce` wieder dahin zurückgesetzt.
    private var iceAvTarget: [Int32] = []
    private var iceAvFeed: [Double] = []
    private var iceAvPhi: [Double] = []
    public private(set) var veg: [Double]    // Vegetationsdichte 0..1
    /// Vegetations-Klasse je Zelle: 0 kahl · 1 Gras · 2 Wald · 3 Auwald.
    /// ADDITIV zu `veg` (das bleibt Dichte 0..1 für alle bestehenden
    /// Konsumenten): die Klasse differenziert nur den Erosionsschutz
    /// (vegDamp) und die Mäander-Ufer-Kohäsion. Abgeleitet in updateVegClass.
    public private(set) var vegClass: [UInt8]
    /// Flussnähe 0..1 (gedämpfte Dilatation der Wasser-Maske) — Eingangsgröße
    /// der Auwald-Klasse, geglättet, damit die Klassen-Grenzen weich bleiben.
    private var riparian: [Double]
    private var vegScratch: [Double] // Pingpong-Puffer der Riparian-Dilatation
    /// Zwischenstufe des separablen Samen-Druck-Maximums (s. `updateVegetation`).
    private var vegScratchRow: [Double] = []
    /// Erosionsschutz-Faktoren je Klasse ([kahl, Gras, Wald, Auwald], aus cfg):
    /// Schutz = 1 − 0.6·Faktor·veg — die 0.6-Basiskalibrierung bleibt fix.
    private let vegTypeFactor: [Double]
    /// **Höhenbänder** (Issue #4): Vegetations-, Fels- und Schneegrenzen als
    /// Perzentile der aktuellen Landhöhen statt absoluter Werte. Wird in
    /// `updateHeightBands()` (Anfang von `updateVegetation`, also einmal je
    /// Zeitschritt) neu abgeleitet und ist die EINZIGE Quelle sowohl für die
    /// Vegetation im Sim-Kern als auch für die Biom-Färbung in der GDExtension.
    public private(set) var heightBands: HeightBands

    // Entwässerung
    public private(set) var hf: [Double]     // gefüllte Oberfläche (Priority-Flood)
    /// Darstellungs-SEESPIEGEL: folgt `hf` ratenbegrenzt (`lakeLevelResponseYears`).
    /// Priority-Flood setzt `hf` INSTANTAN aufs Sill-Niveau — jede Deposition am
    /// Becken-Auslass (Droplets, Braiding, Mäander; gemessen: keine Einzelquelle
    /// dominiert) lässt sonst die GESAMTE Seefläche im Render schlagartig springen
    /// und die Auslass-Inzision schneidet sie über ~100 J. wieder frei (Plug/
    /// Breach-Sägezahn). Physisch: ein See füllt sich mit endlicher Rate.
    /// Gedämpft wird nur der Anstieg: der Spiegel liegt nie über `hf` (sonst
    /// Geister-Seen auf frisch abgetragenem, trockenem Boden, Issue #174, s.
    /// `relaxWaterLevel`).
    /// NUR fürs Rendering — die gesamte Physik (Pools, Verlandung, Tropfen)
    /// liest weiter `hf` (ein träges Verlandungs-Ziel war messbar wirkungslos
    /// und störte die Braid-Bänke, s. Kommentar in fillShallowPonds).
    public private(set) var waterLevel: [Double]
    /// BILANZ-Seespiegel abflussloser Becken (Issue #11): die Höhe, auf die der
    /// Wasserhaushalt (Zufluss gegen Verdunstung) das Becken dieser Zelle
    /// deckelt. Persistenter Zustand — der Ziel-Stand wird je Schritt neu
    /// gerechnet, der WEG dorthin ist ratenbegrenzt (`endorheicResponseYears`),
    /// und das Gedächtnis dafür steht hier. Für Zellen ohne verdunstungs-
    /// limitiertes Becken ist es einfach der Füllstand `hf` (bzw. veraltet, s.
    /// `capEndorheicBasins`: der Wert wird beim Wiedereintritt geklemmt).
    private var lakeBalance: [Double]
    /// Becken-Rolle je Zelle aus dem Wasserhaushalt (Issue #11), s. `BasinRole`.
    public private(set) var endorheicBasin: [BasinRole]
    /// Salzkruste 0..1 — Verdunstungsrückstand auf trockengefallenem
    /// Beckenboden, EWMA mit `endorheicSaltYears`. NUR Rendering
    /// (SimRender.TerrainColorRenderer malt die helle Kruste) und Vegetations-Ziel
    /// (Salzpfannen sind kahl); keine Erosionsphysik.
    public private(set) var saltCrust: [Double]
    /// Gemessener ZUFLUSS des Beckens je Zelle (Abfluss-Einheiten wie `area`) —
    /// nur in verdunstungs-limitierten Becken gesetzt, sonst 0. Er wird auf der
    /// VOLLSTAND-Entwässerung gemessen (Pass 1 in `floodAndRoute`) und ist im
    /// fertigen `area` nicht mehr ablesbar: dort ist die Seefläche eine terminale
    /// Senke. Für Diagnose/Wächter (`testBasinWaterAreaMatchesTheBudget`).
    public private(set) var endorheicInflow: [Double]
    /// Ziel-Maske der Salzkruste: trockengefallener Beckenboden, auf dem
    /// SUBSTANZIELL Wasser stand (Vollstand-Tiefe > `endorheicSaltMinDepth`).
    /// Bewusst enger als `endorheicBasin == .dryBed`: der Priority-Flood flutet den
    /// ganzen flachen Beckenboden, ein Millimeter-Saum ist aber keine Salzpfanne
    /// (gemessen n=256/Seed 1337: 9788 trockengefallene Zellen, davon nur ein
    /// Bruchteil je über der Render-Seetiefe).
    private var playaBed: [Bool]
    private var basinSeen: [Bool]   // Arbeitspuffer der Becken-Komponentensuche
    private var basinCells: [Int32] // Zellen des aktuellen Beckens (Bilanz-Sortierung)
    private var basinSlots: [Int32] // deren Plätze in `order` (lokale Umsortierung)
    private var orderPos: [Int32]   // Umkehrabbildung zu `order` (nur beim Deckeln gefüllt)
    public private(set) var receiver: [Int32] // Abfluss-Nachbar (-1 = Senke/Meer)
    /// Einzugsgebiet (Single-Flow/D8 → Erosion). Ohne `cfg.rainWeightedFlow`
    /// reine Zellflächen; mit Schalter (Produktion) ABFLUSS = Fläche ×
    /// normiertes Abfluss-Gewicht (s. `seedFlowAccumulator`, `flowWeight`) — also
    /// Regen und, seit Issue #36, Schmelzwasser.
    /// Die SKALA ist in beiden Fällen dieselbe — das Gewicht hat Landmittel 1.
    public private(set) var area: [Double]
    /// Multi-Flow-Einzugsgebiet (Freeman) → NUR Render/Braiding, nie Erosion.
    /// Dieselbe Gewichtung wie `area` (s. `seedFlowAccumulator`).
    public private(set) var areaMFD: [Double]
    private var order: [Int32]               // Pop-Reihenfolge (aufsteigende Füllhöhe)
    private var floodParent: [Int32]

    private var heap: MinHeap
    private var visited: [Bool]
    private var scratch: [Double] // Arbeitspuffer für die Diffusion
    /// `A^m` je Zelle für `outletIncision` — reiner Arbeitspuffer, s. dort.
    private var areaPow: [Double] = []
    /// Gate-Status der Auslass-Inzision (Runde 7, s. dort): 0 überspringen,
    /// 1 normal, 2 Weltrand. Reiner Arbeitspuffer, je Aufruf neu gesetzt.
    private var incisionGate: [Int8] = []
    /// Vegetations-/Lithologie-Erosionsfaktor je Zelle für `outletIncision`
    /// (Runde 7) — hängt an Feldern, die der Pass nicht schreibt. Reiner
    /// Arbeitspuffer, je Aufruf neu gesetzt.
    private var incisionKErode: [Double] = []
    /// Braid-Status je Zelle (Runde 7, s. `braidPass`): 0 Meer, 1 inaktives
    /// Land (Deposition möglich), 2 aktiver Reach. Reiner Arbeitspuffer, je
    /// Aufruf vor dem seriellen Lauf vollständig neu gesetzt.
    private var braidStatus: [Int8] = []
    /// Vorfilter des `channelCarve` (Runde 7, s. dort): `area`- und Gürtel-
    /// Gate, die einzigen zwei Filter des Passes, die im Pass unverändert
    /// bleiben. Reiner Arbeitspuffer, je Aufruf neu gesetzt.
    private var carveStatus: [Bool] = []
    private var mfdRoutes: [MFDRoute] = []
    /// Route-Klassifikation des MFD-Passes (Runde 7): −1 Meer/Beckenwasser,
    /// 0 flach, sonst Zahl der tieferen Nachbarn — Dispersions-Zellen tragen
    /// c + 10. Reiner Arbeitspuffer, vor jedem Lesen vollständig neu gesetzt.
    private var mfdRouteCounts: [Int8] = []
    /// Disbursive MFD-Gewichte — nur für canDisperse-Zellen geschrieben
    /// (Runde 7, s. `MFDRoute`). Reiner Arbeitspuffer.
    private var mfdDispersed: [MFDDispersion] = []
    private var qs: [Double]      // Sedimentfracht in Transit (transport-limitiert)
    /// Zellen unter einer Mäander-Zentrumslinie (M3-Maske). Reconciliation-Maske für
    /// BEIDE Erosionspfade: `transportLimited` (Grid) und `Hydraulic.erode` (Droplet).
    private(set) var isChannel: [Bool]
    /// Alter der Gleithang-Bank in Jahren seit ihrer Ablagerung, `-1` = keine
    /// Bank (Issue #174, Paket B; nur mit `meanderBelt`). Frisch = Sand/Kies,
    /// alt = Aue; die Scroll-Bars sind Isolinien dieses Felds. Sim-Zustand: der
    /// Gürtel-Stempel liest es (ob eine Zelle gerade Kanal war).
    public private(set) var barAge: [Double]
    /// Zellen, deren Bett der Gürtel-Stempel in DIESEM Schritt setzt —
    /// `channelCarve` lässt sie aus (sonst gräbt er seine Einzell-Rinne in die
    /// Gürtelsohle). Arbeitspuffer, je Schritt neu.
    private var inBelt: [Bool]
    /// nickmcd-Stream-Map: zeitgemittelte Tropfen-Pfade. Wo Wasser WIRKLICH
    /// fließt — scharfe Fäden statt dispergierter Abflussfläche. Koppelt zurück
    /// in die Droplets (weniger Verdunstung auf etablierten Läufen → River
    /// Sharpening) und ist die Render-Maske für Flüsse. Werte 0..1.
    ///
    /// WICHTIG für dt-Invarianz: gemittelt wird die lineare Besuchs-RATE
    /// (`streamRate`, Besuche/Jahr — Erwartungswert unabhängig von der
    /// Schrittweite); die Sättigung auf 0..1 passiert erst NACH der Mittelung.
    /// Sättigung vor der Mittelung machte die Map dt-abhängig (ein Einzelbesuch
    /// saturierte bei kleinen Schritten sofort → Zufallspfade so hell wie Flüsse).
    public private(set) var streamMap: [Double]
    private var streamRate: [Double] // EWMA der Besuche/Jahr
    private var trackBuf: [Double]   // je Schritt: Tropfen-Besuchszahl je Zelle
    /// Je Schritt: Faktor der Tropfen-Deposition je Zelle (Issue #108, s.
    /// `buildDepositDamp`). Reiner Arbeitspuffer wie `trackBuf`/`areaPow` —
    /// leitet sich vollständig aus `area` und der Config ab und gehört deshalb
    /// nicht ins Zustands-Inventar.
    private var depositDampBuf: [Double] = []
    /// Mündungen des laufenden Schritts für `deltaDeposit` (Landzelle mit
    /// Meeres-Empfänger ab `deltaMinCells`, Issue #174), je Schritt neu.
    private var deltaMouthCells: [Int] = []
    private var pondSeen: [Bool]     // Arbeitspuffer der Pfützen-Komponentensuche
    private var noise: SimplexNoise

    /// **Störungsgrad** je Zelle 0..1 (Issue #26): wie stark hat ein Werkzeug
    /// diese Zelle zuletzt umgegraben — und wie viel Regeneration steht noch
    /// aus. Wird von `applyDelta` (dem gemeinsamen Trichter ALLER Pinsel)
    /// aufgebaut und in `regenerateDisturbed` exponentiell abgebaut. Solange er
    /// > 0 ist, gilt die Zelle als frische Baustelle: kein Bewuchs-Standort,
    /// Mikro-Relief wächst hinein, Mäanderzustand der alten Landschaft fällt weg.
    public private(set) var disturb: [Double]
    /// **Offenes Regenerations-Budget** je Zelle (Höheneinheiten, ±): die
    /// Geländeänderung, die der Regenerations-Pfad noch eintragen wird. Gefüllt
    /// beim Eingriff (Setzung/Rebound des bewegten Materials + Mikro-Relief),
    /// abgearbeitet in `regenerateDisturbed` mit derselben Zeitkonstante wie
    /// `disturb`. Ein einziges Budget-Feld statt „Effekt je Schritt neu
    /// ausrechnen": so teleskopiert die Summe über beliebige Schrittweiten exakt
    /// (Framerate-Invariante).
    private var regenPending: [Double]
    /// Schnell-Ausstieg: ohne je gesetzten Störungsgrad wird der gesamte
    /// Regenerations-Pfad übersprungen → normale Alterung bit-identisch zum
    /// Stand vor #26 (Wächter `testUntouchedAgingIsBitIdentical`).
    private var disturbActive = false

    /// Wandernde Fluss-Zentrumslinien (Mäander-Migration). In M2 noch entkoppelt
    /// vom Höhenfeld: sie evolvieren mit der Zeit, formen `h` aber noch nicht
    /// (das macht `meanderStamp` ab M3).
    public private(set) var meander = MeanderState()

    public private(set) var years: Double = 0
    private var seed: UInt32
    private var flowStepCount: UInt32 = 0
    /// Laufende Nummer des nächsten Tropfens im fortlaufenden Tropfen-Strom
    /// (Issue #2). Jeder Tropfen zieht seinen Startpunkt aus einem eigenen, aus
    /// dieser Nummer abgeleiteten Zufallsstrom (`Hydraulic.dropRNG`) — damit
    /// hängt der Strom an der Zahl tatsächlich EMITTIERTER Tropfen und nicht an
    /// der Zahl der Schritte. Vorher lief er über einen Schrittzähler: leere
    /// Frame-Schritte (Tropfenzahl 0 wegen `dropCarry`) schoben ihn trotzdem
    /// weiter, und ein großer Sprung zog alle Tropfen aus EINEM Strom — die
    /// Tropfenzahl war damit zwar dt-invariant, die Tropfen selbst aber nicht.
    private var dropsEmitted: UInt64 = 0
    /// Angebrochener Tropfen aus dem letzten Schritt (Issue #2). Die Tropfenzahl
    /// ist eine RATE (`hydraulicPerYear` · Fläche · dt); bei Frame-Zeitschritten
    /// unter einem halben Jahr ist der Sollwert < 1, und ein `max(1, …)` je
    /// Schritt hätte daraus dauerhaft aufgerundete Erosion gemacht. Der Rest
    /// wird stattdessen mitgenommen und beim nächsten Schritt eingelöst → über
    /// die Zeit ist die Tropfenzahl exakt ∝ Simulationszeit, egal wie fein
    /// getaktet wird.
    private var dropCarry: Double = 0
    /// Nicht verbuchte Zeit der Gürtel-Kopplung; einschließlich der ersten Prüfung bei Jahr 0.
    private var beltCouplingCarry: Double = 0

    /// Frisches Terrain: Puffer anlegen UND generieren. Der Default-Seed steht
    /// in `RenderContract` — er ist dieselbe Zahl, die die Godot-Schicht anzeigt
    /// und die GDExtension für ihr erstes Terrain nimmt (Issue #51).
    /// `settleYears`: Einlauf der Generierung, s. `generate(seed:settleYears:)`.
    public convenience init(config: SimConfig = SimConfig(),
                            seed: UInt32 = RenderContract.defaultSeed,
                            settleYears: Double = 0) {
        self.init(allocating: config, seed: seed)
        generate(seed: seed, settleYears: settleYears)
    }

    /// Legt alle Puffer an, generiert aber NICHT — der Weg für die
    /// Wiederherstellung aus einem `WorldSnapshot` (Issue #8): dort kommt jedes
    /// Feld aus der Datei, ein `generate` davor wäre reine Rechenzeit (Breach +
    /// Spin-up) und würde nur überschrieben.
    init(allocating config: SimConfig, seed: UInt32) {
        self.cfg = config
        self.n = config.n
        self.seed = seed
        self.mfdMinA = config.braidMinCells * config.cellSize * config.cellSize
        self.mfdFlatCell = config.meanderFlatSlope * config.cellSize
        let c = config.count
        h = .init(repeating: 0, count: c)
        rock = .init(repeating: 0, count: c)
        sed = .init(repeating: 0, count: c)
        upliftBase = .init(repeating: 0, count: c)
        rain = .init(repeating: 0, count: c)
        veg = .init(repeating: 0, count: c)
        vegClass = .init(repeating: 0, count: c)
        disturb = .init(repeating: 0, count: c)
        regenPending = .init(repeating: 0, count: c)
        riparian = .init(repeating: 0, count: c)
        vegScratch = .init(repeating: 0, count: c)
        vegTypeFactor = [1, 1, config.vegTypeFactorForest, config.vegTypeFactorRiparian]
        // Vorbelegung, bis `generate` das erste Höhenfeld gelegt hat; danach
        // leitet updateHeightBands() die Bänder aus den echten Landhöhen ab.
        heightBands = config.heightBandsOverride ?? .legacyAbsolute
        hf = .init(repeating: 0, count: c)
        waterLevel = .init(repeating: 0, count: c)
        lakeBalance = .init(repeating: 0, count: c)
        endorheicBasin = .init(repeating: .none, count: c)
        saltCrust = .init(repeating: 0, count: c)
        endorheicInflow = .init(repeating: 0, count: c)
        playaBed = .init(repeating: false, count: c)
        basinSeen = .init(repeating: false, count: c)
        basinCells = []
        basinSlots = []
        orderPos = .init(repeating: 0, count: c)
        receiver = .init(repeating: -1, count: c)
        area = .init(repeating: 0, count: c)
        areaMFD = .init(repeating: 0, count: c)
        order = .init(repeating: 0, count: c)
        floodParent = .init(repeating: -1, count: c)
        visited = .init(repeating: false, count: c)
        scratch = .init(repeating: 0, count: c)
        qs = .init(repeating: 0, count: c)
        isChannel = .init(repeating: false, count: c)
        barAge = .init(repeating: -1, count: c)
        inBelt = .init(repeating: false, count: c)
        streamMap = .init(repeating: 0, count: c)
        streamRate = .init(repeating: 0, count: c)
        trackBuf = .init(repeating: 0, count: c)
        pondSeen = .init(repeating: false, count: c)
        heap = MinHeap(capacity: c)
        noise = SimplexNoise(seed: seed)
    }

    @inline(__always) func idx(_ i: Int, _ j: Int) -> Int { j * n + i }

    /// Pass-Grenze fürs Profiling (Issue #43, s. `SimProfile`). `@autoclosure`,
    /// damit im Normalfall (`enabled == false`) nicht einmal der Name entsteht.
    @inline(__always) private func mark(_ name: @autoclosure () -> String?) {
        if SimProfile.enabled { SimProfile.mark(name()) }
    }

    // MARK: - Datenparallelität

    private static let coreCount = ProcessInfo.processInfo.activeProcessorCount

    /// Führt `body(lo, hi)` über disjunkte Index-Bereiche parallel aus. Nur für
    /// Pässe, deren Zellen unabhängig sind (jede schreibt ausschließlich ihren
    /// eigenen Index) — das Ergebnis ist BIT-IDENTISCH zur sequenziellen Schleife.
    /// Mehr Chunks als Kerne, damit concurrentPerform die ungleich schnellen
    /// P-/E-Kerne auslasten kann.
    @inline(__always) private func parallel(_ count: Int, _ body: (Int, Int) -> Void) {
        let chunks = min(count, max(1, Terrain.coreCount * 4))
        if chunks <= 1 { body(0, count); return }
        DispatchQueue.concurrentPerform(iterations: chunks) { c in
            body(count * c / chunks, count * (c + 1) / chunks)
        }
    }

    /// Setzt ein ganzes Feld auf `value`.
    ///
    /// PERF (Issue #43): `for k in 0..<count { feld[k] = wert }` auf einer
    /// KLASSEN-Property kostet je Zelle Bounds-, COW- und Exklusivitäts-Prüfung
    /// — bei n = 832 gemessen ~9 ms JE FELD und Schritt, für einen Memset. Über
    /// den Roh-Puffer ist es genau das: ein `memset`. Gleiche Werte, deshalb
    /// überall mechanisch ersetzbar.
    @inline(__always) private func fill<T>(_ array: inout [T], _ value: T) {
        array.withUnsafeMutableBufferPointer { b in
            guard let p = b.baseAddress else { return }
            p.update(repeating: value, count: b.count)
        }
    }

    /// „Enthält das Feld ein Element mit `predicate`?" auf dem Roh-Puffer —
    /// dieselbe Abkürzung wie `fill` für die Such-Gegenstücke (Eis-/Becken-
    /// Aktivitätsprüfungen), die ohne Treffer das ganze Gitter durchlaufen.
    @inline(__always) private func anyCell<T>(_ array: [T], _ predicate: (T) -> Bool) -> Bool {
        array.withUnsafeBufferPointer { b in
            guard let p = b.baseAddress else { return false }
            for k in 0..<b.count where predicate(p[k]) { return true }
            return false
        }
    }

    // MARK: - Exponentielle Relaxation

    /// Anteil `1 − e^(−dt/τ)`, den eine exponentielle Relaxation mit
    /// Zeitkonstante `tau` in der Zeitspanne `dt` zurücklegt — die
    /// Framerate-Unabhängigkeit dieses Projekts in EINER Zeile (AGENTS.md,
    /// „Framerate-Unabhängigkeit", Bauform 2): der Rest teleskopiert exakt,
    /// `(1 − f(dt₁))·(1 − f(dt₂)) = 1 − f(dt₁ + dt₂)`, also landen viele
    /// Mini-Schritte und EIN großer Sprung auf demselben Wert. Die früher
    /// verwendete linear gedeckelte Form (`min(1, dt/τ)`) tat das nicht und
    /// sättigte bei großen Schritten.
    ///
    /// EINZIGE Quelle für alle Relaxations-/Verlandungs-Raten (Seespiegel,
    /// Salzkruste, Becken-Bilanz, Pfützen, Altarme, Vegetation, Stream-Map,
    /// Regeneration). Bewusst OHNE Gültigkeitsprüfung von `tau`: die Aufrufer
    /// bewachen ihre Zeitkonstante selbst (meist `guard τ > 0`), und ein
    /// Deckel hier würde ihr dokumentiertes Randverhalten verschieben.
    /// Wächter: `RelaxationTests`.
    @inline(__always)
    public static func relaxFraction(dt: Double, tau: Double) -> Double {
        1 - exp(-dt / tau)
    }

    // MARK: - Terrain-Generierung

    /// Setzt alle Zustandsfelder und Arbeitspuffer vollständig auf den Stand
    /// eines frisch allokierten Terrains zurück (Issue #174).
    ///
    /// `Terrain.generate(seed:settleYears:)` ruft dies als ersten Schritt auf,
    /// damit kein Zustand einer früheren Welt (Mäander-Masken, Stream-Map,
    /// Kryo-Felder, Vegetation, Puffer) überlebt und das Ergebnis bit-identisch
    /// zu `Terrain(config:seed:settleYears:)` ist. Vorher überlebten u. a.
    /// `isChannel` der Mäander, Vegetation und Stream-Map, und Seed 42 im Spiel
    /// war eine andere Welt als in jeder Messreihe. Wer ein Feld hinzufügt,
    /// setzt es hier zurück; Wächter:
    /// `FingerprintTests.testGenerateOnUsedTerrainYieldsFreshWorld`.
    private func resetToAllocated(seed: UInt32) {
        self.seed = seed
        self.years = 0
        self.dropsEmitted = 0
        self.flowStepCount = 0
        self.dropCarry = 0
        self.beltCouplingCarry = cfg.meanderBeltCouplingYears
        self.disturbActive = false
        self.beltSubsteps = 0
        self.beltCouplingLog = nil
        self.noise = SimplexNoise(seed: seed)
        self.meander = MeanderState()
        self.heightBands = cfg.heightBandsOverride ?? .legacyAbsolute

        // Arrays mit dynamischer Allokation (leer beim Start)
        rainWeight = []
        runoffWeight = []
        lithHardness = []
        lithErodeK = []
        lithBed = []
        lithProvince = []
        temperature = []
        snow = []
        ice = []
        underIce = []
        iceRate = []
        iceSurf = []
        iceEro = []
        iceEroH = []
        iceAvTarget = []
        iceAvFeed = []
        iceAvPhi = []
        vegScratchRow = []
        areaPow = []
        depositDampBuf = []
        dropletGateBuf = []
        segOwner = []
        segPos = []
        deltaMouthCells.removeAll(keepingCapacity: true)
        basinCells.removeAll(keepingCapacity: true)
        basinSlots.removeAll(keepingCapacity: true)

        // Feste Gitterpuffer (Größe cfg.count) über Rohpuffer auf Standardwerte
        fill(&h, 0)
        fill(&rock, 0)
        fill(&sed, 0)
        fill(&upliftBase, 0)
        fill(&rain, 0)
        fill(&veg, 0)
        fill(&vegClass, 0)
        fill(&disturb, 0)
        fill(&regenPending, 0)
        fill(&riparian, 0)
        fill(&vegScratch, 0)
        fill(&hf, 0)
        fill(&waterLevel, 0)
        fill(&lakeBalance, 0)
        fill(&endorheicBasin, .none)
        fill(&saltCrust, 0)
        fill(&endorheicInflow, 0)
        fill(&playaBed, false)
        fill(&basinSeen, false)
        fill(&orderPos, 0)
        fill(&receiver, -1)
        fill(&area, 0)
        fill(&areaMFD, 0)
        fill(&order, 0)
        fill(&floodParent, -1)
        fill(&visited, false)
        fill(&scratch, 0)
        fill(&qs, 0)
        fill(&isChannel, false)
        fill(&barAge, -1)
        fill(&inBelt, false)
        fill(&streamMap, 0)
        fill(&streamRate, 0)
        fill(&trackBuf, 0)
        fill(&pondSeen, false)
        heap = MinHeap(capacity: cfg.count)
    }

    /// `settleYears` > 0 lässt die frische Welt so viele Jahre ECHTE Sim-Physik
    /// einlaufen und stellt die Uhr danach auf Jahr 0 zurück — dieselbe Doktrin
    /// wie `updateClimate(dt: 10000)` unten: der Einlauf ist ÄLTER als das
    /// Spieljahr 0. Begründung (PR #106): das rohe Noise+Pre-Erosions-Relief
    /// ist ein unphysikalischer Extremzustand (gestanzte Kerben-„Krater",
    /// Nadel-Grate; auf dem 720er-Produktionsgrid Gratkrümmung ≈ −0.88 gegen
    /// ≈ −0.03 bei 100k — Faktor 27, kalibriert war die Alterung auf n=160 mit
    /// Faktor 2). Ein kurzer Lauf der Pässe, die danach ohnehin weiterlaufen,
    /// entschärft genau diese Formen — junge und gealterte Welt sprechen
    /// dieselbe Formensprache, die Jugend-Schärfe bleibt. Default 0: die
    /// SimCore-Testwelten und alle Kalibrier-Messreihen bleiben unverändert;
    /// den Produktionswert setzt die Brücke (`SimConfig.productionSettleYears`).
    ///
    /// Auf einem BENUTZTEN Terrain (im Spiel: neuer Seed auf demselben Node)
    /// liefert der Aufruf dieselbe Welt wie ein frisches `Terrain(seed:)`,
    /// s. `resetToAllocated`.
    public func generate(seed: UInt32, settleYears: Double = 0) {
        resetToAllocated(seed: seed)

        // Grundrelief und Tektonik-Feld: die Großform aus Issue #174 oder, für
        // die Testwelten der Kalibrier-Suite, die Form davor (`rangeLandform`).
        let (box, boy) = cfg.rangeLandform ? generateRangeRelief(seed: seed)
                                           : generateLegacyRelief(seed: seed)
        // Pre-Erosion (runevision-Filter): verzweigte Rinnen/Grate einmalig ins
        // Basisrelief carven — deterministisch je Seed (Rinnen-Muster wandert mit).
        if cfg.preErodeEnabled {
            ErosionFilter.apply(h: &h, n: n, sea: cfg.sea,
                                seedOffsetX: box, seedOffsetY: boy,
                                params: cfg.preErodeParams)
        }
        initLayers()
        // Gesteinsfeld (Issue #12) VOR dem ersten Flow: der Becken-Breach und die
        // Spin-up-Tropfen sollen die Härtekontraste schon sehen — die antezedente
        // Entwässerung ist damit von Anfang an strukturkontrolliert.
        buildLithologyField()
        updateLithology()
        // Becken-Wasserhaushalt (Issue #11) im Gleichgewicht starten: die
        // Generierung ruft `computeFlow` mit dt = 0, der Bilanz-Spiegel snappt
        // also auf seinen Zielstand statt sich über die ersten Spieljahre
        // einzuschwingen (dieselbe Doktrin wie `waterLevel = hf` unten).
        for k in 0..<cfg.count {
            lakeBalance[k] = h[k]
            endorheicBasin[k] = .none
            saltCrust[k] = 0
            disturb[k] = 0 // frisches Terrain hat keine Baustellen (Issue #26)
            barAge[k] = -1 // noch keine Gleithang-Bank (Issue #174)
            regenPending[k] = 0
        }
        disturbActive = false
        // Kryo-Felder leeren, BEVOR der erste `computeFlow` läuft. Seit Issue #36
        // speist die Schneedecke den Abfluss; ein `generate` auf einem BESTEHENDEN
        // Terrain (im Spiel: neuer Seed auf demselben Node) würde sonst die neue
        // Insel mit dem Schnee der alten entwässern — der Seed wäre nicht mehr
        // allein bestimmend, und Determinismus ist eine getestete Invariante.
        // `updateClimate(dt: 10000)` unten baut die Felder gleich frisch auf.
        temperature = []; snow = []; ice = []
        // Die Vergletscherungs-Maske ist eine Ableitung daraus (#35) — mit dem
        // Eis muss sie weg, sonst gatet die alte Insel die Erosion der neuen.
        underIce = []
        computeFlow()
        if cfg.breachEnabled { breachBasins() }
        spinUpStreamMap()
        // Die Spin-up-Tropfen lagern Sediment ab und können frisch entwässerte
        // Becken wieder andämmen → einmal nachbreachen (billig, fast alles offen).
        if cfg.breachEnabled { breachBasins() }
        // Klima im eingeschwungenen Zustand starten (Issue #33) — dieselbe
        // Doktrin wie `waterLevel = hf` und `lakeBalance = h` oben: die
        // Schneedecke ist ÄLTER als das Spieljahr 0 und soll nicht über die
        // ersten Jahrhunderte einschwingen. 10.000 Jahre sind bei der trägsten
        // Zeitkonstante (`snowTurnoverYears` 500) 20 τ — der Vorrat steht exakt
        // auf S*. Muss VOR `updateVegetation` laufen: dessen
        // `updateHeightBands` liest die Schneegrenze aus dem Feld.
        updateClimate(dt: 10000)
        // Vegetation im eingeschwungenen Zustand starten.
        updateVegetation(years: 10000)
        seedMeander()
        // Einlauf (s. Doc-Kommentar oben): VOR den Startzustands-Doktrinen
        // darunter, damit Seespiegel und Playa-Kruste den EINGELAUFENEN Stand
        // einfrieren. Getaktet wie der Zeitraffer (1000-Jahr-Chunks).
        if settleYears > 0 {
            var remaining = settleYears
            while remaining > 0 {
                let dt = min(1000, remaining)
                step(dtYears: dt)
                remaining -= dt
            }
            years = 0
            // Geburtsjahre des Einlaufs lägen sonst in der Zukunft des
            // Spieljahrs 0: eingesetzte Strecken blieben bis ~Jahr 2200
            // unsichtbar. Alles aus dem Einlauf ist ausgewachsen.
            for ci in meander.channels.indices { meander.channels[ci].born = [] }
        }
        waterLevel = hf // Startzustand: Seespiegel = Füllstand (kein Einschwingen)
        // Playas starten mit ihrer Kruste (sie sind ÄLTER als das Spieljahr 0) —
        // sonst salzt eine seit der Generierung trockene Pfanne erst über die
        // ersten ~1200 Jahre ein.
        for k in 0..<cfg.count where playaBed[k] { saltCrust[k] = 1 }
    }

    /// Grundrelief und Tektonik-Feld mit Gebirgskamm und Tieflandkorridoren
    /// (Issue #174, `RangeSkeleton`). Liefert den Rausch-Versatz für die
    /// Pre-Erosion.
    private func generateRangeRelief(seed: UInt32) -> (Double, Double) {
        // --- Per-Seed-Makro-Parameter: jeder Seed bekommt eine eigene Insel-Form,
        // Reliefstärke, Grat/Rundhügel-Charakter und Küsten-Archetyp → echte Vielfalt
        // statt immer derselben zentrierten Rund-Insel. Deterministisch (Mulberry32).
        var gr = Mulberry32(seed: seed ^ 0x1234_abcd)
        let box = gr.next() * 1000, boy = gr.next() * 1000        // Noise-Region (Seed sampelt anderswo)
        let cx = Double(n - 1) / 2
        // Zentrum und Ausdehnung seit Issue #174 enger (vorher ±0,17 n Versatz,
        // fStart 0,58–0,88, Ellipse über die kurze Achse normiert, also mit
        // bis zu 1,8-facher langer Halbachse): die Insel soll als Ganzes im
        // Gitter liegen, der Randabstand unten schneidet sonst gerade, steile
        // Küsten parallel zum Rand.
        let ccx = cx + (gr.next() - 0.5) * 0.12 * Double(n)        // Insel-Zentrum versetzt
        let ccy = cx + (gr.next() - 0.5) * 0.12 * Double(n)
        let aAng = gr.next() * .pi                                  // Anisotropie-Achse
        let aRatio = 0.55 + gr.next() * 1.05                        // Streckung: 0.55 langer Zug … 1.6 gestaucht
        let fStart = 0.55 + gr.next() * 0.15                        // Landausdehnung (kleine Insel ↔ Kontinent)
        let fWidth = 0.30 + gr.next() * 0.15                        // Küstensaum-Breite (≥ 0,30: flache Küstenebene, s. u.)
        let relief = cfg.baseRelief * (0.80 + gr.next() * 0.45)     // Reliefstärke variiert
        let roll = gr.next() * gr.next() * 0.7                      // 0=schroffe Grate … Rundhügel (quadr.→meist schroff)
        let mFreqK = 0.22 + gr.next() * 0.42                        // Massiv-Frequenz (Gipfel-Klumpung entlang des Kamms)
        _ = gr.next()                                               // (war mBias, die Tiefland-Grundhöhe — jetzt Sache des Kamms)
        let bfMul = 0.72 + gr.next() * 0.75                         // Feature-Skala (grob ↔ fein)
        let sharp = 1.0 + gr.next() * 0.9                           // Grat-Schärfe (pow-Exponent)
        let archetype = Int(gr.next() * 3.0)                        // 0 Insel · 1 Küste · 2 Archipel
        let coastAng = gr.next() * 2 * .pi                          // Küsten-Richtung (Archetyp 1)

        @inline(__always) func smooth(_ a: Double, _ b: Double, _ v: Double) -> Double {
            let t = min(max((v - a) / (b - a), 0), 1); return t * t * (3 - 2 * t)
        }

        // Großform (Issue #174, `RangeSkeleton`): EIN Kamm entlang der langen
        // Inselachse statt Grate über die ganze Fläche. Beim Archetyp Küste
        // läuft er parallel zur Küste im Hinterland.
        let ca = cos(aAng), sa = sin(aAng)
        var axisDir = aRatio < 1 ? SIMD2(-sa, ca) : SIMD2(ca, sa)
        var axisCenter = SIMD2(ccx, ccy)
        let longSemi = fStart * cx
        if archetype == 1 {
            let cd = SIMD2(cos(coastAng), sin(coastAng))
            axisDir = SIMD2(-cd.y, cd.x)
            axisCenter = SIMD2(cx, cx) - 0.18 * Double(n) * cd
        }
        var lr = Mulberry32(seed: seed ^ 0x7a11_4e5d)
        let skeleton = RangeSkeleton(n: n, rng: &lr, center: axisCenter, axisDir: axisDir,
                                     halfLength: min(0.42 * Double(n), 0.75 * longSemi))
        let form = skeleton.evaluate(n: n)

        // Tektonik-Feld: fix je Terrain (reale Tektonik wechselt nicht alle 100 J).
        let uNoise = SimplexNoise(seed: seed ^ 0x5eed)
        var uRnd = Mulberry32(seed: seed ^ 0x5eed)
        let uox = uRnd.next() * 1000, uoy = uRnd.next() * 1000
        let uFreq = cfg.upliftFreq / Double(n)
        for j in 0..<n {
            for i in 0..<n {
                // RIDGED Tektonik: Hebung konzentriert sich auf Gebirgs-GRATE (statt
                // eines glatten Blobs). Entscheidend gegen die Langzeit-Degradation —
                // die Erosion läuft sonst ins glatte Hebungsfeld (→ runde Kuppeln);
                // ein gratiges Hebungsfeld trägt langfristig gratige Berge.
                // Seit Issue #174 nur noch im Gebirgsgürtel: `applyUplift` und der
                // Relief-Servo heben ausschließlich über den POSITIVEN Teil, die
                // Ebenen und Täler bleiben damit tektonisch ruhig — sonst höbe der
                // Servo das Tiefland über die Jahrtausende wieder zu Hügeln.
                let ridge = uNoise.ridged01(Double(i) * uFreq + uox,
                                            Double(j) * uFreq + uoy, octaves: 5)
                upliftBase[idx(i, j)] = (ridge * 1.15 - 0.22) * form.mountain[idx(i, j)]
            }
        }

        // Grundrelief: Grate (ridged, optional mit fBm gemischt) im Gebirgsgürtel,
        // sanfte Hügel daneben, flache Ebene dahinter; Täler schneiden vom Kamm
        // zur Küste. Darüber der per-Seed variierende Insel-/Küsten-/Archipel-
        // Falloff unter den Meeresspiegel und der Randabstand.
        let bf = cfg.baseFreq / Double(n)
        // Ebene: Höhe 0,20 über einem Meer bei 0,15. Die Küstenlinie liegt damit
        // bei falloff = 0,75, im oberen, flachen Teil der Smoothstep: das
        // Küstengefälle der Ebene (0,20 · 1,125 / (0,30 · 360 Zellen) ≈ 0,002 je
        // Zelle) bleibt unter der Mäander-Schwelle (0,02 · cellSize ≈ 0,003).
        let plainBase = 0.20
        let valleyHeadRise = 0.10   // Talschluss über der Ebene (Gefälle ≈ 0,1 / 2,2 R)
        // Randabstand relativ zu n (bei 720: 24 Zellen Rand, 72 Zellen Rampe,
        // ±14 Zellen Rauschen) — in absoluten Zellen fraß er den Testwelten
        // (n = 96…256) einen Großteil des Landes.
        let borderMargin = 0.033 * Double(n)
        let borderRamp = 0.10 * Double(n)
        let borderWobble = 0.04 * Double(n)
        for j in 0..<n {
            for i in 0..<n {
                let k = idx(i, j)
                let x = Double(i) * bf * bfMul + box, y = Double(j) * bf * bfMul + boy
                let ridge = noise.ridged01(x, y, octaves: cfg.baseOctaves)
                let rollv = noise.fbm01(x, y, octaves: 6)          // sanfte Alternative
                let base = (1 - roll) * ridge + roll * rollv       // Grat ↔ Rundhügel
                let massif = noise.fbm01(x * mFreqK, y * mFreqK, octaves: 3)
                let ridgeE = 0.38 + 0.62 * pow(base, sharp)
                let mountain = ridgeE * relief * (0.40 + 0.50 * massif)
                let hills = relief * 0.40 * base * (0.5 + 0.5 * massif) // Vorberge: dieselben Grate, niedriger
                let plain = plainBase + 0.03 * (noise.fbm01(x * 0.5 + 70, y * 0.5 + 70, octaves: 3) - 0.5)
                let wm = form.mountain[k]
                let land = plain + valleyHeadRise * form.rise[k]
                    + form.hill[k] * (1 - wm) * hills + wm * mountain
                // Anisotroper, versetzter Falloff.
                let dx = Double(i) - ccx, dy = Double(j) - ccy
                let rx = dx * ca + dy * sa
                let ry = (-dx * sa + dy * ca) * aRatio
                let d = (rx * rx + ry * ry).squareRoot() / cx / min(1, aRatio) // lange Halbachse = fStart
                var falloff = 1 - smooth(fStart, fStart + fWidth, d)
                if archetype == 1 {                                // Küste: Land auf einer Seite
                    let proj = (Double(i) - cx) * cos(coastAng) + (Double(j) - cx) * sin(coastAng)
                    let wob = (noise.fbm01(x * 0.6 + 30, y * 0.6 + 30, octaves: 3) - 0.5) * 0.5
                    let g = proj / Double(n) + wob
                    falloff = min(falloff, 1 - smooth(0.0, 0.26, g))
                } else if archetype == 2 {                         // Archipel: in Inseln zerlegen
                    let isl = noise.fbm01(x * 0.7 + 50, y * 0.7 + 50, octaves: 4)
                    falloff *= smooth(0.34, 0.52, isl)
                }
                // Randabstand (Issue #174): kein Land am Gitterrand, sonst endet
                // die Insel in einer geraden Kante und das Heightfield zeigt seine
                // senkrechte Unterseite. Verrauscht, damit die Küste dort nicht
                // dem Rand parallel läuft.
                let bd = Double(min(min(i, j), min(n - 1 - i, n - 1 - j)))
                let bw = bd + borderWobble * (noise.fbm01(x * 0.8 + 90, y * 0.8 + 90, octaves: 3) - 0.5)
                falloff = min(falloff, smooth(borderMargin, borderMargin + borderRamp, bw))
                h[k] = land * falloff
            }
        }
        return (box, boy)
    }

    /// Grundrelief und Tektonik-Feld VOR Issue #174: Grate über die ganze
    /// Landfläche, Massiv-Rauschen nur als Höhe. Unverändert erhalten, weil die
    /// Mechanik-Wächter der Suite ihre Testwelt darauf kalibriert haben
    /// (`calibrationRangeLandform` in `SimCoreTests/TestCalibration.swift`);
    /// bit-identisch zum Stand davor.
    private func generateLegacyRelief(seed: UInt32) -> (Double, Double) {
        // Tektonik-Feld: fix je Terrain (reale Tektonik wechselt nicht alle 100 J).
        let uNoise = SimplexNoise(seed: seed ^ 0x5eed)
        var uRnd = Mulberry32(seed: seed ^ 0x5eed)
        let uox = uRnd.next() * 1000, uoy = uRnd.next() * 1000
        let uFreq = cfg.upliftFreq / Double(n)
        // Positiv vorgespannt: da detachment-limited Stream-Power Material ins Meer
        // austrägt (nicht massenerhaltend), muss die Tektonik die Landmasse netto
        // tragen — sonst erodiert/senkt die Insel über 100k+ Jahre zu Graten weg.
        for j in 0..<n {
            for i in 0..<n {
                // RIDGED Tektonik: Hebung konzentriert sich auf Gebirgs-GRATE (statt
                // eines glatten Blobs). Entscheidend gegen die Langzeit-Degradation —
                // die Erosion läuft sonst ins glatte Hebungsfeld (→ runde Kuppeln);
                // ein gratiges Hebungsfeld trägt langfristig gratige Berge.
                let ridge = uNoise.ridged01(Double(i) * uFreq + uox,
                                            Double(j) * uFreq + uoy, octaves: 5)
                upliftBase[idx(i, j)] = ridge * 1.15 - 0.22 // Grate → stark hoch, Täler → leicht runter
            }
        }

        // --- Per-Seed-Makro-Parameter: jeder Seed bekommt eine eigene Insel-Form,
        // Reliefstärke, Grat/Rundhügel-Charakter und Küsten-Archetyp → echte Vielfalt
        // statt immer derselben zentrierten Rund-Insel. Deterministisch (Mulberry32).
        var gr = Mulberry32(seed: seed ^ 0x1234_abcd)
        let box = gr.next() * 1000, boy = gr.next() * 1000        // Noise-Region (Seed sampelt anderswo)
        let cx = Double(n - 1) / 2
        let ccx = cx + (gr.next() - 0.5) * 0.34 * Double(n)        // Insel-Zentrum versetzt
        let ccy = cx + (gr.next() - 0.5) * 0.34 * Double(n)
        let aAng = gr.next() * .pi                                  // Anisotropie-Achse
        let aRatio = 0.55 + gr.next() * 1.05                        // Streckung: 0.55 langer Zug … 1.6 gestaucht
        let fStart = 0.58 + gr.next() * 0.30                        // Landausdehnung (kleine Insel ↔ Kontinent)
        let fWidth = 0.18 + gr.next() * 0.26                        // Küstensaum-Breite
        let relief = cfg.baseRelief * (0.80 + gr.next() * 0.45)     // Reliefstärke variiert
        let roll = gr.next() * gr.next() * 0.7                      // 0=schroffe Grate … Rundhügel (quadr.→meist schroff)
        let mFreqK = 0.22 + gr.next() * 0.42                        // Massiv-Frequenz (Berg-Klumpung)
        let mBias = 0.38 + gr.next() * 0.26                         // Tiefland-Grundhöhe
        let bfMul = 0.72 + gr.next() * 0.75                         // Feature-Skala (grob ↔ fein)
        let sharp = 1.0 + gr.next() * 0.9                           // Grat-Schärfe (pow-Exponent)
        let archetype = Int(gr.next() * 3.0)                        // 0 Insel · 1 Küste · 2 Archipel
        let coastAng = gr.next() * 2 * .pi                          // Küsten-Richtung (Archetyp 1)

        @inline(__always) func smooth(_ a: Double, _ b: Double, _ v: Double) -> Double {
            let t = min(max((v - a) / (b - a), 0), 1); return t * t * (3 - 2 * t)
        }

        // Grundrelief: RIDGED-Multifractal (scharfe Grate), optional mit fBm gemischt
        // (Rundhügel), moduliert vom Massiv-Feld, mit per-Seed variierendem Insel-/
        // Küsten-/Archipel-Falloff unter den Meeresspiegel.
        let bf = cfg.baseFreq / Double(n)
        let ca = cos(aAng), sa = sin(aAng)
        for j in 0..<n {
            for i in 0..<n {
                let x = Double(i) * bf * bfMul + box, y = Double(j) * bf * bfMul + boy
                let ridge = noise.ridged01(x, y, octaves: cfg.baseOctaves)
                let rollv = noise.fbm01(x, y, octaves: 6)          // sanfte Alternative
                let base = (1 - roll) * ridge + roll * rollv       // Grat ↔ Rundhügel
                let massif = noise.fbm01(x * mFreqK, y * mFreqK, octaves: 3)
                let m = mBias + (1 - mBias) * massif               // Gebirge vs. Tiefland
                // Anisotroper, versetzter Falloff.
                let dx = Double(i) - ccx, dy = Double(j) - ccy
                let rx = dx * ca + dy * sa
                let ry = (-dx * sa + dy * ca) * aRatio
                let d = (rx * rx + ry * ry).squareRoot() / cx
                var falloff = 1 - smooth(fStart, fStart + fWidth, d)
                if archetype == 1 {                                // Küste: Land auf einer Seite
                    let proj = (Double(i) - cx) * cos(coastAng) + (Double(j) - cx) * sin(coastAng)
                    let wob = (noise.fbm01(x * 0.6 + 30, y * 0.6 + 30, octaves: 3) - 0.5) * 0.5
                    let g = proj / Double(n) + wob
                    falloff = min(falloff, 1 - smooth(0.0, 0.26, g))
                } else if archetype == 2 {                         // Archipel: in Inseln zerlegen
                    let isl = noise.fbm01(x * 0.7 + 50, y * 0.7 + 50, octaves: 4)
                    falloff *= smooth(0.34, 0.52, isl)
                }
                let ridgeE = 0.38 + 0.62 * pow(base, sharp)        // Talboden angehoben → Täler bleiben Land
                h[idx(i, j)] = ridgeE * relief * m * falloff
            }
        }
        return (box, boy)
    }

    /// Seespiegel sofort auf den Füllstand setzen — für Spieler-Eingriffe
    /// (sculpt → recomputeFlow): deren Feedback soll instantan sein, nur die
    /// Sim-Dynamik (Plug/Breach am Auslass) ist träge.
    public func snapWaterLevel() { waterLevel = hf }

    /// Initialisiert die Stream-Map bei der Generierung (sonst wären am Anfang
    /// keine Flüsse sichtbar, bis genug Sim-Schritte Tracks akkumuliert haben):
    /// ein paar Tropfen-Chargen laufen das frische Terrain hinab und hinterlassen
    /// die ersten zeitgemittelten Pfade.
    private func spinUpStreamMap() {
        fill(&streamRate, 0)
        fill(&streamMap, 0)
        guard cfg.hydraulicEnabled else { return }
        let density = Double(n * n) / (640.0 * 640.0)
        for round in 0..<4 {
            fill(&trackBuf, 0)
            let drops = max(200, Int(2000 * density))
            // Diese Charge entspricht so vielen Jahren Tropfen-Budget:
            let dtEq = Double(drops) / max(1e-9, cfg.hydraulicPerYear * density)
            Hydraulic.erode(h: &h, rock: &rock, sed: &sed, n: n, count: drops,
                            seed: seed &+ UInt32(0x9e37 + round), floor: cfg.floor,
                            p: cfg.hydraulic,
                            seaLevel: cfg.hydraulicSkipWaterSpawns ? cfg.sea : nil,
                            hf: hf, receiver: receiver,
                            stream: streamMap,
                            // Dieselbe Quelle wie im Sim-Schritt (Issue #36). In der
                            // Generierung gibt es noch kein Schneefeld, `flowWeight`
                            // liefert hier also das reine Regen-Gewicht — der Spin-up
                            // bleibt bit-identisch.
                            flowWeight: flowWeight,
                            erodibility: lithErodeK,
                            track: &trackBuf)
            for k in 0..<cfg.count {
                streamRate[k] = 0.5 * streamRate[k] + 0.5 * (trackBuf[k] / dtEq)
            }
            deriveStreamMap()
        }
        computeFlow() // die Spin-up-Tropfen haben h leicht verändert
    }

    /// Spin-up der Becken-Entwässerung (nickmcd-Verhalten: Seen entwässern zum
    /// Meer statt vollzulaufen). Lässt die Auslass-Inzision die Sillen der
    /// geschlossenen Becken durchschneiden, BEVOR die Landschaft sichtbar wird —
    /// physisch antezedente Täler. Nutzt bewusst denselben getesteten
    /// `outletIncision`-Pass wie der Sim-Loop; MFD wird im Spin-up übersprungen
    /// (nur fürs Rendering nötig) und am Ende einmal frisch berechnet.
    ///
    /// **Ohne Becken-Wasserhaushalt (Issue #11).** Der Spin-up misst seinen
    /// Fortschritt am See-Anteil (`lakeStats`) — mit gedeckelten Spiegeln SIEHT er
    /// die Becken nicht mehr, bricht nach der ersten Runde ab und lässt genau die
    /// geschlossenen Becken stehen, die er durchschneiden soll (gemessen n=832
    /// Seed 1337 mit Deckel IM Spin-up: 87684 trockengefallene Zellen bei der
    /// Generierung — mehr als die GESAMTE Ponding-Fläche des gebreachten Terrains,
    /// 41648 Zellen; die sichtbare Seefläche fiel von 2.61 % auf 1.04 %).
    /// Physisch sind das auch zwei verschiedene Zeitebenen: der Breach ist die
    /// ANTEZEDENTE Entwässerungsgeschichte (älter als die Landschaft), der
    /// Wasserhaushalt das heutige Klima. Der Deckel kommt deshalb erst im
    /// abschließenden `computeFlow`.
    private func breachBasins() {
        // Routing zuerst OHNE Deckel neu aufbauen: sonst schneidet die erste
        // Inzisionsrunde auf dem gedeckelten Netz des vorigen computeFlow, und
        // die Generierung hinge doch am Klima (der Spin-up soll über alle κ
        // bit-identisch laufen).
        floodAndRoute(dt: 0, applyBalance: false)
        for _ in 0..<cfg.breachMaxRounds {
            let s = lakeStats()
            let land = Double(landCellCount())
            // Fertig, wenn der See-Anteil klein ist UND kein einzelner See mehr
            // dominiert (diskrete nickmcd-Seen statt Zentralbecken).
            if s.fraction < cfg.breachTargetLakeFrac && Double(s.largest) < 0.025 * land { break }
            outletIncision(dt: cfg.breachDT, minAreaCells: 100)
            floodAndRoute(dt: 0, applyBalance: false) // s. Doku: Breach ist verdunstungs-blind
        }
        computeFlow() // hier snappt der Bilanz-Spiegel auf seinen Zielstand
    }

    /// pow() ist im 3.3M-Aufrufe-Hot-Loop von computeFlow teuer; die MFD-
    /// Exponenten sind aber Ganzzahlen (4 dendritisch, 2 dispersiv) →
    /// Multiplikations-Schnellpfad, generischer pow nur als Fallback.
    @inline(__always) private func powFast(_ s: Double, _ p: Double) -> Double {
        if p == 4.0 { let s2 = s * s; return s2 * s2 }
        if p == 2.0 { return s * s }
        // KEIN 0.5→sqrt-Schnellpfad: libm-pow(x, 0.5) weicht bei Laufzeit-Exponent
        // in ~0,14% der Fälle um 1 ulp von sqrt ab (gemessen; Literal-Tests täuschen,
        // weil LLVM pow(x, 0.5) selbst zu sqrt faltet) → nicht bit-identisch, und
        // die 1-ulp-Differenz divergiert übers chaotische System messbar.
        return pow(s, p)
    }

    /// Leitet die 0..1-Stream-Map aus der geglätteten Besuchs-Rate ab.
    /// Rationale Sättigung rate/(rate+r0) statt 1−exp(−rate/r0): gleiche Form
    /// (0.5 bei r0, →1 darüber), aber ohne 409k exp()-Aufrufe je Schritt.
    private func deriveStreamMap() {
        let r0 = cfg.streamRefRate
        for k in 0..<cfg.count {
            streamMap[k] = streamRate[k] / (streamRate[k] + r0)
        }
    }

    /// Diagnostik zum Becken-Wasserhaushalt (Issue #11): Zahl der verdunstungs-
    /// limitierten (abflusslosen) Becken sowie ihre Wasser- und Trockenfläche in
    /// Zellen. `basins` zählt zusammenhängende Komponenten (8er, wie die
    /// Becken-Erkennung selbst) von `endorheicBasin != .none` — ein Becken mit
    /// Restsee UND trockenem Saum ist EINS.
    public func endorheicStats() -> (basins: Int, water: Int, dryBed: Int) {
        var water = 0, dryBed = 0
        for k in 0..<cfg.count {
            if endorheicBasin[k] == .water { water += 1 }
            else if endorheicBasin[k] == .dryBed { dryBed += 1 }
        }
        guard water + dryBed > 0 else { return (0, 0, 0) }
        var seen = [Bool](repeating: false, count: cfg.count)
        var stack = [Int]()
        var basins = 0
        for start in 0..<cfg.count where endorheicBasin[start] != .none && !seen[start] {
            basins += 1
            stack.removeAll(keepingCapacity: true); stack.append(start); seen[start] = true
            while let k = stack.popLast() {
                let i = k % n, j = k / n
                for dj in -1...1 {
                    for di in -1...1 {
                        let ni = i + di, nj = j + dj
                        if ni < 0 || ni >= n || nj < 0 || nj >= n { continue }
                        let nb = nj * n + ni
                        if endorheicBasin[nb] != .none && !seen[nb] { seen[nb] = true; stack.append(nb) }
                    }
                }
            }
        }
        return (basins, water, dryBed)
    }

    /// See-Diagnostik: Anteil der Landzellen mit stehendem Wasser (hf−h > `depth`)
    /// und größte zusammenhängende Seefläche (4er-Nachbarschaft, in Zellen).
    /// depth 0.01 = jedes Ponding; 0.03 = nur Seen, die der Renderer auch zeigt.
    public func lakeStats(depth: Double = 0.01) -> (fraction: Double, largest: Int) {
        var wet = 0, land = 0
        var isLake = [Bool](repeating: false, count: cfg.count)
        for k in 0..<cfg.count where hf[k] > cfg.sea {
            land += 1
            if hf[k] - h[k] > depth { wet += 1; isLake[k] = true }
        }
        var seen = [Bool](repeating: false, count: cfg.count)
        var largest = 0
        var stack = [Int]()
        for start in 0..<cfg.count where isLake[start] && !seen[start] {
            stack.removeAll(keepingCapacity: true); stack.append(start); seen[start] = true
            var size = 0
            while let k = stack.popLast() {
                size += 1
                let i = k % n, j = k / n
                if i > 0 && isLake[k-1] && !seen[k-1] { seen[k-1] = true; stack.append(k-1) }
                if i < n-1 && isLake[k+1] && !seen[k+1] { seen[k+1] = true; stack.append(k+1) }
                if j > 0 && isLake[k-n] && !seen[k-n] { seen[k-n] = true; stack.append(k-n) }
                if j < n-1 && isLake[k+n] && !seen[k+n] { seen[k+n] = true; stack.append(k+n) }
            }
            largest = max(largest, size)
        }
        return (land == 0 ? 0 : Double(wet) / Double(land), largest)
    }

    // MARK: - Lithologie (räumlich variable Erodierbarkeit, Issue #12)

    /// Baut die **fixen** Anteile des Gesteinsfelds: die geneigte, gefaltete
    /// Schichtebene (`lithBed`) und die Härte-Provinzen (`lithProvince`). Beide
    /// hängen ausschließlich am Seed → gleicher Seed, gleiches Feld (Wächter:
    /// `Lithology.testFieldIsDeterministicPerSeed`).
    ///
    /// Eigener Noise-/PRNG-Zweig (`seed ^ 0x1170`), damit die Lithologie NICHT mit
    /// Relief (`seed`) oder Tektonik (`seed ^ 0x5eed`) korreliert: sonst läge jede
    /// harte Bank auf einem Grat und das Feld wäre nur eine zweite Lesart der
    /// Topografie, statt sie zu formen. Streichrichtung und Fallen variieren je
    /// Seed (wie die Makro-Parameter der Insel in `generate`).
    ///
    /// Sequenzielle Schleife: läuft einmal je Generierung, nicht je Schritt.
    private func buildLithologyField() {
        guard cfg.lithologyEnabled else {
            lithBed = []; lithProvince = []; lithHardness = []; lithErodeK = []
            return
        }
        let c = cfg.count
        if lithBed.count != c {
            lithBed = .init(repeating: 0, count: c)
            lithProvince = .init(repeating: 0, count: c)
            lithHardness = .init(repeating: 0, count: c)
            lithErodeK = .init(repeating: 1, count: c)
        }
        let lNoise = SimplexNoise(seed: seed ^ 0x1170)
        var lr = Mulberry32(seed: seed ^ 0x1170)
        let lox = lr.next() * 1000, loy = lr.next() * 1000
        let dipAng = lr.next() * 2 * .pi
        // Fallen 0.4…1.6 × cfg.lithDip: manche Seeds sind fast flach gelagert
        // (Tafelberge/Mesas), andere deutlich verkippt (Cuestas/Schichtkämme).
        let dip = cfg.lithDip * (0.4 + 1.2 * lr.next())
        let dx = cos(dipAng) * dip / Double(n - 1)
        let dy = sin(dipAng) * dip / Double(n - 1)
        let warpFreq = 2.2 / Double(n)   // Faltungs-Wellenlänge ~ halbe Karte
        let provFreq = 1.6 / Double(n)   // Provinz-Wellenlänge ~ halbe Karte
        for j in 0..<n {
            for i in 0..<n {
                let k = idx(i, j)
                let x = Double(i), y = Double(j)
                let warp = lNoise.fbm01(x * warpFreq + lox, y * warpFreq + loy, octaves: 3) * 2 - 1
                lithBed[k] = x * dx + y * dy + warp * cfg.lithWarp
                // fBm nutzt seine [-1,1]-Spanne nie aus (Oktaven mitteln sich weg)
                // → gedehnt und geklemmt, damit es echte Provinz-EXTREME gibt.
                let prov = lNoise.fbm01(x * provFreq + lox + 500, y * provFreq + loy + 500,
                                        octaves: 3) * 2 - 1
                lithProvince[k] = min(1, max(-1, prov * 1.8))
            }
        }
    }

    /// Leitet Härte und Erodierbarkeit aus der **aktuellen** Höhe ab.
    ///
    ///     s     = (h − lithBed) / lithLayerThickness     stratigraphische Koordinate
    ///     Welle = glattes Wechselprofil über s           −1 Bandmitte … +1 Bandgrenze
    ///     hard  = (1−Mix)·Welle + Mix·Provinz + Bias     geklemmt auf [−1, 1]
    ///     K     = 1 − lithContrast·hard                  Erodierbarkeit (Mittel ≈ 1)
    ///
    /// Dass `s` an `h` hängt, IST der Mechanismus: die harte Bank bleibt auf ihrem
    /// Höhenniveau liegen, während die Erosion das weiche Gestein darunter
    /// ausräumt — die Kante wandert seitwärts (Schichtstufen-Rückverlegung), nicht
    /// nach unten. Ein an die Zelle geheftetes, höhen-UNABHÄNGIGES Feld kann das
    /// nicht: dort erodiert die weiche Zelle einmal tief und ist fertig.
    ///
    /// Das Profil ist bewusst polynomial (Dreieck + Smoothstep) statt `sin`: der
    /// Pass läuft je Zeitschritt über alle Zellen (n=832 → 692k), 692k `sin`
    /// kosten pro Schritt ~14 ms Frame-Budget, die Polynom-Variante nichts
    /// Messbares. Die Form ist dieselbe (Mittel 0, weiche Bandgrenzen).
    /// Per-Zelle unabhängig (liest h/lithBed/lithProvince, schreibt nur
    /// lithHardness/lithErodeK) → datenparallel bit-identisch.
    private func updateLithology() {
        guard cfg.lithologyEnabled, lithBed.count == cfg.count else { return }
        let thick = max(1e-9, cfg.lithLayerThickness)
        let mix = min(1, max(0, cfg.lithProvinceMix))
        let bias = cfg.lithHardBias
        let contrast = cfg.lithContrast
        let cnt = cfg.count
        h.withUnsafeBufferPointer { hb in
        lithBed.withUnsafeBufferPointer { bb in
        lithProvince.withUnsafeBufferPointer { pb in
        lithHardness.withUnsafeMutableBufferPointer { hdb in
        lithErodeK.withUnsafeMutableBufferPointer { kb in
            let ph = hb.baseAddress!, pbed = bb.baseAddress!, pprov = pb.baseAddress!
            let phard = hdb.baseAddress!, pk = kb.baseAddress!
            parallel(cnt) { lo, hi in
                for k in lo..<hi {
                    let s = (ph[k] - pbed[k]) / thick
                    let frac = s - s.rounded(.down)          // Phase im Paket 0..1
                    let tri = abs(2 * frac - 1)              // Dreieck: 1 an der Bandgrenze
                    let sm = tri * tri * (3 - 2 * tri)       // Smoothstep → weiche Kontakte
                    let wave = 2 * sm - 1                    // −1 … +1, Mittel 0
                    var hard = (1 - mix) * wave + mix * pprov[k] + bias
                    hard = min(1, max(-1, hard))
                    phard[k] = hard
                    // Untergrenze 0.05: kein Nullteiler-artiger „unerodierbarer"
                    // Fels, auch wenn lithContrast > 1 gefahren wird.
                    pk[k] = max(0.05, 1 - contrast * hard)
                }
            }
        }}}}}
    }

    private func initLayers() {
        let sedInit = 0.02
        for k in 0..<cfg.count {
            sed[k] = min(sedInit, max(h[k] - cfg.floor, 0))
            rock[k] = h[k] - sed[k]
        }
    }

    // MARK: - Klima (orographischer Niederschlag, Wind von Westen)

    public func computeRain() {
        let nn = n, sea = cfg.sea
        h.withUnsafeBufferPointer { hb in
        rain.withUnsafeMutableBufferPointer { rb in
        let ph = hb.baseAddress!, prain = rb.baseAddress!
        // Jede Zeile ist ein unabhängiger West→Ost-Sweep → zeilenparallel.
        parallel(nn) { jLo, jHi in
        for j in jLo..<jHi {
            var m = 1.0
            let k0 = j * nn
            var hs = ph[k0] <= sea ? sea : ph[k0]
            for i in 0..<nn {
                let k = k0 + i
                if ph[k] <= sea {
                    m = min(1, m + 0.015) // über Wasser auftanken
                    prain[k] = m
                    hs = sea
                    continue
                }
                prain[k] = m
                // Anstieg auf GEGLÄTTETER Höhe (EWMA ~4 Zellen): seit der Pre-
                // Erosion trägt jeder Hang feine Rinnen — als Roh-Anstiege gezählt
                // trockneten sie die ganze Insel aus (Regen ≈ 0 → kein Grün).
                // Orographie = Makro-Relief, nicht Rinnen-Textur.
                let hsNew = hs + 0.25 * (ph[k] - hs)
                let uph = max(0, hsNew - hs)
                hs = hsNew
                // Floor 0.18 (war 0.05): auch der Regenschatten-Osten bekommt
                // Grundfeuchte → moosige Tiefland-Ebenen statt kahler Blässe.
                m = max(0.18, m - m * (0.0012 + uph * 1.5))
            }
        }
        }
        }}
        updateRainWeight()
        // Schmelzwasser (Issue #36) sitzt AUF dem frischen Regen-Gewicht: eigener
        // Pass, damit beide Gewichtsfelder aus demselben `rain` fallen und die
        // Rückfall-Kette (`flowWeight`) eindeutig bleibt — auch auf den
        // Abbruchpfaden von `updateRainWeight` (Schalter aus, Insel ohne Regen).
        updateRunoffWeight()
    }

    /// Baut `rainWeight` aus dem frischen `rain` (Issue #10).
    ///
    ///     w[k] = rain[k] / mittleres Land-rain   (Land)
    ///     w[k] = 1.0                             (See)
    ///
    /// Zwei Eigenschaften, auf denen die ganze Rekalibrierung ruht:
    /// 1. **Σw über Land = Zahl der Landzellen** (per Konstruktion des Mittels) —
    ///    der Gesamtabfluss bleibt exakt der der ungewichteten Akkumulation, alle
    ///    in ZELLEN kalibrierten Gates behalten ihre Bedeutung, und die
    ///    Auflösungs-Abhängigkeit des Regen-Landmittels (0.563 bei n=192 …
    ///    0.364 bei n=832) fällt heraus.
    /// 2. **See = 1.0 = das Landmittel**, also der neutrale Wert: die
    ///    Tropfen-Ablehnungs-Stichprobe zieht damit denselben Anteil Starts aufs
    ///    Meer wie ungewichtet (bei `hydraulicSkipWaterSpawns` = derselbe
    ///    Tropfen-Etat auf Land). Für die Akkumulation ist der See-Wert egal —
    ///    Seezellen sind Senken und reichen nichts weiter.
    ///
    /// Das Landmittel wird SEQUENZIELL summiert (feste Reihenfolge → bit-genau
    /// reproduzierbar); die Division je Zelle ist per-Zelle unabhängig und
    /// deshalb parallel bit-identisch. Ohne Land (alles überflutet) bleibt das
    /// Feld neutral bei 1.0.
    private func updateRainWeight() {
        guard cfg.rainWeightedFlow else {
            if !rainWeight.isEmpty { rainWeight = [] }
            return
        }
        let cnt = cfg.count, sea = cfg.sea
        if rainWeight.count != cnt { rainWeight = .init(repeating: 1, count: cnt) }
        var sum = 0.0, land = 0
        h.withUnsafeBufferPointer { hb in
        rain.withUnsafeBufferPointer { rb in
            let ph = hb.baseAddress!, prain = rb.baseAddress!
            for k in 0..<cnt where ph[k] > sea { sum += prain[k]; land += 1 }
        }}
        let mean = land == 0 ? 0 : sum / Double(land)
        guard mean > 1e-9 else {
            rainWeight.withUnsafeMutableBufferPointer { $0.update(repeating: 1) }
            return
        }
        let inv = 1 / mean
        h.withUnsafeBufferPointer { hb in
        rain.withUnsafeBufferPointer { rb in
        rainWeight.withUnsafeMutableBufferPointer { wb in
            let ph = hb.baseAddress!, prain = rb.baseAddress!, pw = wb.baseAddress!
            parallel(cnt) { lo, hi in
                for k in lo..<hi { pw[k] = ph[k] > sea ? prain[k] * inv : 1.0 }
            }
        }}}
    }

    /// Baut `runoffWeight` — Regen PLUS Schmelzwasser — aus dem frischen `rain` und
    /// der Schneedecke des vorigen Schritts (Issue #36). Kalibrier-Logbuch und
    /// Herleitung der Umrechnung: `SimConfig.meltRunoffEnabled`.
    ///
    /// ```
    /// m(k)   = snowMeltPerKYear · max(0, T) · S        Schmelzfluss [SWE/Jahr]
    /// roh(k) = rain[k] − withhold · rain[k] · f_schnee(T)   (Einlagerung, Default 0)
    ///          + min(m(k) / snowAccumPerYear, cap · rain[k])   (Ablation, in Regen-Einheiten)
    /// w(k)   = min(roh(k) / Landmittel, (1 + cap) · rainWeight[k])   (Land)
    ///                                  Divisor s. `cfg.meltRunoffNormalized`,
    ///                                  Deckel s. `cfg.meltRunoffCapPerRain`
    /// w(k)   = 1.0                     (See, neutral wie bei `rainWeight`)
    /// ```
    ///
    /// **Operator-Splitting.** `rain` ist frisch (dieser Schritt), `temperature`
    /// und `snow` stehen auf dem Stand des SCHRITTENDES vom letzten Mal
    /// (`updateClimate` läuft dort). Dieselbe Kohärenz-Annahme wie im Rest des
    /// Schritts: über einen Zeitschritt ändert sich die Schneedecke (τ ≥ 500 a)
    /// nicht sprunghaft. Nach der Generierung ist das Klima bereits eingeschwungen
    /// (`generate` ruft `updateClimate(dt: 10000)`), der erste Sim-Schritt sieht
    /// also eine echte Schneedecke — der Abfluss der GENERIERUNG selbst bleibt
    /// dagegen bewusst schmelzfrei (dort läuft `computeFlow`, bevor es Schnee gibt),
    /// damit die kalibrierte Welt-Erzeugung bit-identisch bleibt.
    ///
    /// **dt-Invarianz.** Reine Ableitung ohne eigenen Zustand: kein Term hängt an
    /// `dt`. Die Zeitabhängigkeit steckt komplett in `snow` (dort exakt gelöst).
    ///
    /// **Leeres Ergebnis = bit-identisch zum Stand vor #36.** Das Feld bleibt leer,
    /// wenn der Schalter aus ist, das Klima aus ist, `rainWeight` fehlt (dann ist
    /// der Abfluss ungewichtet und eine Schmelz-Gewichtung wäre ein Widerspruch)
    /// — oder wenn keine einzige Zelle einen Schmelz- bzw. Einlagerungs-Beitrag
    /// liefert. Letzteres ist der Normalfall einer schneefreien Welt und wird
    /// GEMESSEN, nicht geraten: die sequenzielle Summenschleife merkt sich, ob
    /// irgendein `roh` von `rain` abweicht.
    ///
    /// Die Land-Summen laufen SEQUENZIELL (feste Reihenfolge → bit-genau
    /// reproduzierbar), die Skalierung je Zelle ist unabhängig und deshalb parallel
    /// bit-identisch — dieselbe Aufteilung wie in `updateRainWeight`.
    private func updateRunoffWeight() {
        let cnt = cfg.count
        guard cfg.meltRunoffEnabled, cfg.climateEnabled,
              rainWeight.count == cnt, snow.count == cnt, temperature.count == cnt else {
            if !runoffWeight.isEmpty { runoffWeight = [] }
            return
        }
        if runoffWeight.count != cnt { runoffWeight = .init(repeating: 1, count: cnt) }
        let sea = cfg.sea
        let tFreeze = cfg.snowFreezeTemp
        let phaseSpan = max(1e-9, cfg.snowRainTemp - tFreeze) // s. updateClimate
        let tRain = cfg.snowRainTemp
        let withhold = min(1, max(0, cfg.meltRunoffWithholdSolid))
        // Schmelzfluss → Regen-Einheiten: die Umkehrung der Akkumulation
        // (a = snowAccumPerYear · rain · f_schnee), s. SimConfig.meltRunoffEnabled.
        let meltToRain = cfg.snowMeltPerKYear / max(1e-12, cfg.snowAccumPerYear)
        // Deckel des Schmelzbeitrags (Vielfaches des lokalen Regens): im Lauf
        // nie bindend, aber nach einem Spieler-Eingriff auf beschneitem Gelände
        // die Grenze zwischen „mehr Schmelze" und einer Punkt-Quelle.
        // Herleitung: `SimConfig.meltRunoffCapPerRain`.
        let cap = max(0, cfg.meltRunoffCapPerRain)
        var rawSum = 0.0, rainSum = 0.0, land = 0
        var anyMelt = false
        // Ein sequenzieller Pass baut das rohe Gewicht UND beide Land-Summen: die
        // Formel ist billig (kein exp), ein zusätzlicher paralleler Bau-Pass würde
        // nur ein zweites Mal über 700k Zellen laufen.
        h.withUnsafeBufferPointer { hb in
        rain.withUnsafeBufferPointer { rnb in
        temperature.withUnsafeBufferPointer { tb in
        snow.withUnsafeBufferPointer { sb in
        runoffWeight.withUnsafeMutableBufferPointer { wb in
            let ph = hb.baseAddress!, prain = rnb.baseAddress!
            let pt = tb.baseAddress!, ps = sb.baseAddress!, pw = wb.baseAddress!
            for k in 0..<cnt {
                guard ph[k] > sea else { pw[k] = 1.0; continue }
                let t = pt[k]
                var raw = prain[k]
                if withhold > 0 && t < tRain {
                    let fSnow = min(1, max(0, (tRain - t) / phaseSpan))
                    raw -= withhold * prain[k] * fSnow
                    if raw < 0 { raw = 0 }
                }
                if t > 0 && ps[k] > 0 {
                    raw += min(meltToRain * t * ps[k], cap * prain[k])
                }
                if raw != prain[k] { anyMelt = true }
                pw[k] = raw
                rawSum += raw
                rainSum += prain[k]
                land += 1
            }
        }}}}}
        // Keine Zelle trägt Schmelze oder Einlagerung bei → auf `rainWeight`
        // zurückfallen (bit-identisch, und der Tropfen-Pfad spart die Kopie).
        let mean = land == 0 ? 0 : (cfg.meltRunoffNormalized ? rawSum : rainSum) / Double(land)
        guard anyMelt, mean > 1e-9 else {
            runoffWeight = []
            return
        }
        let inv = 1 / mean
        // Der Deckel gilt am NORMIERTEN Gewicht, denn das ist die Größe, die die
        // Tropfen-Stichprobe sieht: bei `meltRunoffWithholdSolid > 0` liegt das
        // Landmittel des rohen Gewichts UNTER dem Regenmittel, die Renormierung
        // hebt also jede Zelle an — ein am Rohwert gedeckelter Ausreißer käme
        // danach trotzdem über `(1 + Deckel)·rainWeight`. Der Roh-Deckel oben
        // bleibt trotzdem stehen: er hält den Divisor selbst frei von Ausreißern.
        // Ohne Einlagerung ist diese Klammer nachweislich schlaff (roh ≥ rain ⇒
        // Rohmittel ≥ Regenmittel), der Produktions-Arm rechnet also unverändert.
        // Wenn sie greift, nimmt sie Wasser weg statt welches zu erfinden: Σ über
        // Land bleibt ≤ Zellzahl. Wächter:
        // `MeltRunoff.testMeltContributionStaysCappedWithSolidWithholding`.
        let ceiling = 1 + cap
        h.withUnsafeBufferPointer { hb in
        rainWeight.withUnsafeBufferPointer { rwb in
        runoffWeight.withUnsafeMutableBufferPointer { wb in
            let ph = hb.baseAddress!, prw = rwb.baseAddress!, pw = wb.baseAddress!
            parallel(cnt) { lo, hi in
                for k in lo..<hi where ph[k] > sea {
                    pw[k] = min(pw[k] * inv, ceiling * prw[k])
                }
            }
        }}}
    }

    // MARK: - Klima-Vertikale: Temperatur und Schneedecke (Issue #33)

    /// Zieht Temperatur- und Schneefeld um `dt` Jahre nach. Kalibrier-Logbuch und
    /// Modellherleitung: `SimConfig.climateEnabled` ff.,
    /// `docs/research-climate-cryosphere.md`.
    ///
    /// ```
    /// T      = T₀ − Γ·max(0, h − sea)                  (Meer trägt überall T₀)
    /// f_s    = clamp((T_regen − T)/(T_regen − T_frost), 0, 1)
    /// a      = c_akk · rain · f_s                      Akkumulation
    /// μ      = 1/τ₀ + c_schmelz · max(0, T)            Ablations-Ratenkonstante
    /// S      ← S* + (S − S*)·e^(−μ·dt),  S* = a/μ      exakte Lösung von Ṡ = a − μS
    /// ```
    ///
    /// **dt-Invarianz.** Die Relaxationsform teleskopiert exakt: N Schritte à dt
    /// liefern denselben Faktor wie EIN Schritt à N·dt, weil
    /// `e^(−μdt)^N = e^(−μ·N·dt)` und `S*` je Schritt derselbe ist (μ und a hängen
    /// nur an T und rain, nicht an dt). `dt = 0` lässt das Feld exakt unverändert
    /// — genau das braucht der Sculpt-Pfad, der nur die Temperatur nachziehen
    /// will; die Bilanz wird dafür ÜBERSPRUNGEN statt mit e⁰ = 1 gerechnet
    /// (`target + (S − target)·1` rundet in Fließkomma nicht garantiert auf `S`
    /// zurück, ein zeitloser Sculpt-Schritt dürfte die persistierte Bilanz aber
    /// nicht um ein ULP verschieben). Die klassische degree-day-Form mit
    /// `max(0, …)` wäre schon für dt > 0 nicht dt-invariant,
    /// s. `SimConfig.snowMeltPerKYear`.
    ///
    /// **Operator-Splitting** wie im Rest des Schritts: `T` liest die FINALEN
    /// Höhen des Zeitschritts, `rain` das Feld vom Schrittanfang (`computeFlow`
    /// ruft `computeRain`). Beide sind über einen Zeitschritt kohärent genug —
    /// die Feuchte ändert sich über Jahrhunderte nicht sprunghaft.
    ///
    /// Per-Zelle unabhängig (jede Zelle schreibt nur ihren Index) → parallel
    /// bit-identisch zur sequenziellen Schleife.
    public func updateClimate(dt: Double) {
        guard cfg.climateEnabled else {
            // AUS heißt LEER (Muster Lithologie/Regen-Gewichtung): kein Konsument
            // findet ein Feld, alle rechnen mit dem Rückfall von vor #33.
            if !temperature.isEmpty { temperature = [] }
            if !snow.isEmpty { snow = [] }
            if !ice.isEmpty { ice = [] }
            return
        }
        let cnt = cfg.count
        if temperature.count != cnt { temperature = .init(repeating: 0, count: cnt) }
        if snow.count != cnt { snow = .init(repeating: 0, count: cnt) }
        if ice.count != cnt { ice = .init(repeating: 0, count: cnt) }
        let sea = cfg.sea
        let t0 = cfg.climateSeaLevelTemp, gamma = cfg.climateLapseRate
        let tFreeze = cfg.snowFreezeTemp
        // Spanne der Phasen-Rampe; bei entarteter Config (obere ≤ untere Schwelle)
        // bleibt eine harte Kante bei `snowRainTemp` statt einer Division durch 0.
        let phaseSpan = max(1e-9, cfg.snowRainTemp - tFreeze)
        let tRain = cfg.snowRainTemp
        let accum = cfg.snowAccumPerYear
        let base = 1 / max(1e-9, cfg.snowTurnoverYears)
        let melt = cfg.snowMeltPerKYear
        // Zeitloser Aufruf (Sculpt-Pfad, `SimNode.recomputeFlow`): nur die
        // Temperatur nachziehen, die Bilanz bleibt Byte für Byte stehen.
        let holdSnow = (dt == 0)
        h.withUnsafeBufferPointer { hb in
        rain.withUnsafeBufferPointer { rnb in
        temperature.withUnsafeMutableBufferPointer { tb in
        snow.withUnsafeMutableBufferPointer { sb in
            let ph = hb.baseAddress!, prain = rnb.baseAddress!
            let pt = tb.baseAddress!, ps = sb.baseAddress!
            parallel(cnt) { lo, hi in
                for k in lo..<hi {
                    let t = t0 - gamma * max(0, ph[k] - sea)
                    pt[k] = t
                    if holdSnow { continue }
                    let fSnow = min(1, max(0, (tRain - t) / phaseSpan))
                    let a = accum * prain[k] * fSnow
                    // Schneefreie Zelle ohne Zufuhr: Ziel 0, Vorrat 0 — die
                    // Relaxation liefert dann exakt 0 (0 + (0−0)·e^… = 0), das
                    // `exp` wäre reine Rechenzeit. BIT-IDENTISCH, nicht approximiert.
                    // Der Zweig trägt die große Mehrheit der Zellen: das ganze Meer
                    // und alles Land unter der Regen/Schnee-Grenze (bei
                    // Produktionswerten h < 0.458, s. climateLapseRate). Gemessen
                    // n=832: der Pass fällt damit von 3.12 ms auf unter 1 ms je
                    // Schritt (docs/climate-snow-measurements.md §7).
                    if a == 0 && ps[k] == 0 { continue }
                    let mu = base + melt * max(0, t)
                    let target = a / mu
                    ps[k] = target + (ps[k] - target) * exp(-mu * dt)
                }
            }
        }}}}
    }

    /// Sättigung eines Schneevorrats zur **Deckung** (0 … <1): `S/(S + ref)`, wie
    /// bei der Stream-Map (`streamRefRate`). EINZIGE Quelle der Formel — der
    /// Färbungs-Loop in `SimRender.TerrainColorRenderer` ruft sie über den rohen
    /// Puffer auf, statt sie ein zweites Mal hinzuschreiben (dieselbe Doktrin wie
    /// `vegetationSuitability` seit Issue #4). Wächter:
    /// `ClimateSnow.testSnowCoverIsTheSingleSourceForColouring`.
    @inline(__always) public static func snowCoverage(swe: Double, ref: Double) -> Double {
        swe / (swe + ref)
    }

    /// **Schneedeckung** einer Zelle (0 … <1) — die EINE Quelle für die
    /// Schnee-Färbung, s. `snowCoverage(swe:ref:)`.
    ///
    /// Ohne Klima (Feld leer) fällt die Antwort auf das HÖHENBAND zurück
    /// (`HeightBands.snowAmount`) — also exakt auf das Verhalten vor #33.
    @inline(__always) public func snowCover(_ k: Int) -> Double {
        guard snow.count == cfg.count else { return heightBands.snowAmount(h[k]) }
        return Terrain.snowCoverage(swe: snow[k], ref: cfg.snowCoverRef)
    }

    /// Landanteile mit Schneedeckung über den beiden Band-Schwellen — die
    /// Rückprojektion des Schneefelds auf eine HÖHE für `HeightBands`
    /// (Waldgrenze, Shader-Durchreichung). `nil` = Klima aus → Perzentil-Rückfall.
    ///
    /// Sequenzielle Integer-Zählung: das Ergebnis hängt an keiner Summationsreihen-
    /// folge und ist damit bit-genau reproduzierbar.
    private func snowAreaFractions() -> (ramp: Double, full: Double)? {
        guard cfg.climateEnabled, snow.count == cfg.count else { return nil }
        let sea = cfg.sea, ref = cfg.snowCoverRef
        let cStart = cfg.snowBandCoverStart, cFull = cfg.snowBandCoverFull
        let cnt = cfg.count
        var land = 0, ramp = 0, full = 0
        h.withUnsafeBufferPointer { hb in
        snow.withUnsafeBufferPointer { sb in
            let ph = hb.baseAddress!, psnow = sb.baseAddress!
            for k in 0..<cnt where ph[k] > sea {
                land += 1
                let c = Terrain.snowCoverage(swe: psnow[k], ref: ref)
                if c > cStart { ramp += 1 }
                if c >= cFull { full += 1 }
            }
        }}
        guard land > 0 else { return nil }
        return (Double(ramp) / Double(land), Double(full) / Double(land))
    }

    // MARK: - Gletscher: Eisfluss, glaziale Erosion und Moränen (Issue #35)

    /// Zieht das Eisfeld um `dt` Jahre nach: Transport, glaziale Erosion, Bilanz
    /// und Moränen — und baut danach die Maske `underIce`, die die beiden
    /// fluvialen Abtragspfade unter dem Gletscher stilllegt.
    /// Kalibrier-Logbuch: `SimConfig.iceEnabled` ff.,
    /// Modellwahl `docs/research-climate-cryosphere.md` §4/§5,
    /// Messreihen `docs/glacier-measurements.md`.
    ///
    /// ```
    /// s      = h + ice                                  Eis-OBERFLÄCHE (h ist das Bett)
    /// out(k) = min(kappa·I·ΣΔs⁺, moveFrac·I)            Ausstrom je Teilschritt
    /// I      ← I + Σ_nb out(nb)·Δs⁺(nb→k)/ΣΔs⁺(nb) − out(k)
    /// E      = iceErodeK · (I·S)^m · S,  S = ΣΔs⁺/cellSize    (Flux-Modell, n = 1)
    /// a      = iceFirnPerSnowYear · snow · clamp(−T/coldSpan, 0, 1)
    /// μ      = 1/iceTurnoverYears + iceMeltPerKYear · max(0, T)
    /// I      ← I* + (I − I*)·e^(−μ·dt),  I* = a/μ       exakte Lösung von İ = a − μI
    /// Moräne = iceMoraineK · (Schmelz-Anteil von ∫μ·I dt)
    /// ```
    ///
    /// **Sub-Taktung** exakt wie die Hangdiffusion in `step()`: die Transport-Zahl
    /// des ganzen Schritts (`kappa_Jahr · dt`) wird auf so viele gleich starke
    /// Teilschritte verteilt, dass jeder unter seinen Stabilitätsgrenzen bleibt
    /// (Ausstrom-Anteil UND Diffusionszahl, s. `iceTransportDomain`). Damit ist
    /// die Gesamtwirkung ∝ `dt` — ein `+10.000 Jahre`-Sprung transportiert
    /// dasselbe wie 50.000 Frame-Schritte à 0,2 Jahre (Wächter
    /// `Glacier.testIceIsFramerateIndependent`). Die Bilanz teleskopiert
    /// ohnehin exakt (Relaxationsform), und der Erosionsterm ist eine RATE mal
    /// `subDt`.
    ///
    /// **Operator-Splitting** wie im Rest des Schritts: `snow` steht auf dem
    /// Stand des vorigen Schrittendes (dieselbe Annahme wie in
    /// `updateRunoffWeight`), `h` auf dem frischen Stand dieses Schritts. Die
    /// TEMPERATUR dagegen liest der Teilschritt nicht aus dem Feld, sondern
    /// rechnet sie aus dem Bett, das er gerade vor sich hat (s.
    /// `iceFlowSubStep`): sie ist eine reine Funktion von `h`, und der Gletscher
    /// senkt sein eigenes Bett über den Schritt.
    ///
    /// **Schnell-Ausstieg.** Ohne Eis UND ohne Zufuhr (keine Zelle unter 0 °C mit
    /// Schneevorrat) tut der Pass nichts und leert die Maske → alles rechnet
    /// bit-identisch zum Stand vor #35. Das ist nicht nur eine Optimierung: der
    /// Test dafür ist ein Abnahmekriterium des Tickets. Der EINE sequenzielle
    /// Suchlauf ist gegen die bis zu 100 Teilschritte eines großen Sprungs
    /// vernachlässigbar.
    public func updateIce(dt: Double) {
        let cnt = cfg.count
        guard cfg.iceEnabled, cfg.climateEnabled, dt > 0,
              ice.count == cnt, snow.count == cnt, temperature.count == cnt else {
            if !underIce.isEmpty { underIce = [] }
            return
        }
        // Gibt es überhaupt Eis oder eine Quelle dafür? (Reihenfolge-unabhängig,
        // also bit-genau reproduzierbar.)
        let firnT = cfg.iceFirnTemp
        var active = anyCell(ice) { $0 > 0 }
        if !active {
            active = temperature.withUnsafeBufferPointer { tb in
            snow.withUnsafeBufferPointer { sb in
                let pt = tb.baseAddress!, ps = sb.baseAddress!
                for k in 0..<cnt where pt[k] < firnT && ps[k] > 0 { return true }
                return false
            }}
        }
        guard active else {
            if !underIce.isEmpty { underIce = [] }
            return
        }
        if iceRate.count != cnt { iceRate = .init(repeating: 0, count: cnt) }
        if iceSurf.count != cnt { iceSurf = .init(repeating: 0, count: cnt) }
        if iceEro.count != cnt { iceEro = .init(repeating: 0, count: cnt) }
        if iceEroH.count != cnt { iceEroH = .init(repeating: 0, count: cnt) }
        // kappa auflösungs-unabhängig (∝ 1/dx² ∝ (n−1)², auf n = 640 kalibriert) —
        // dieselbe Umrechnung wie bei `hillDiffusion` in `step()`.
        let refN = 639.0, m1 = Double(n - 1)
        let kYear = cfg.iceFlowK * (m1 * m1) / (refN * refN) / 100.0
        // Der explizite Transport hat ZWEI Kennzahlen je Teilschritt, und beide
        // hält die Sub-Taktung unter ihrer Grenze (s. `iceTransportDomain`):
        //   * `kappa · ΣΔs⁺` ≤ `iceFlowSubCap` — der Anteil der Säule, der die
        //     Zelle verlässt (Positivität), am STEILSTEN Eis-Hang;
        //   * `kappa · I` ≤ `iceFlowSubCap / 2` — die Diffusionszahl der
        //     Eis-OBERFLÄCHE (der Fluss von k nach nb ist `kappa·I_k·(s_k − s_nb)`,
        //     also Diffusion von s mit dem Koeffizienten `kappa·I`), an der
        //     DICKSTEN Säule. Der Schachbrett-Modus des 5-Punkt-Sterns wächst
        //     je Teilschritt um den Faktor `1 − 8·kappa·I`: über 1/4 schaukelt er
        //     sich auf, zwischen 1/8 und 1/4 kippt er bei jedem Teilschritt das
        //     Vorzeichen. Erst unter 1/8 ist das Ergebnis konvergiert (gemessen:
        //     Grenze 1/4 gegen 1/8 −6 … −12 % Eismasse, 1/8 gegen 1/16 < 0,01 %).
        // Bis Issue #174 stand hier nur die erste. Dickes Eis auf flachem Bett
        // (I ≫ ΣΔs⁺) lief damit instabil, sobald der Schritt groß genug war, um
        // `kappa·I` über 1/4 zu heben: bei dt = 1000 Schachbrett-Oberfläche
        // (Rauheit ×70), Schliff 0,065 im Mittel unter dem Eis in EINEM Schritt
        // gegen 0,005 bei zehn Schritten à 100 — die Eismasse hing damit an der
        // Schrittweite (`docs/glacier-measurements.md` §L).
        // Beide Größen werden hier EINMAL gemessen statt pessimistisch
        // angenommen: mit `ΣΔs⁺ ≤ 1` als Annahme liefe die Sub-Taktung um den
        // Faktor 1/wMax (gemessen 5…20) zu fein, und der Pass dominierte den
        // Zeitschritt (§E). Der harte Positivitäts-Deckel `iceFlowMoveFraction`
        // bleibt trotzdem stehen: die Messung stammt vom Zustand VOR den
        // Teilschritten, und ein Sculpt-Eingriff kann die Oberfläche dazwischen
        // versteilern.
        var domain = iceTransportDomain()
        guard domain.iLo <= domain.iHi else { rebuildIceMask(); return }
        // Lawinen-Karte EINMAL je Schritt aus dem Bett vom Schrittanfang
        // (Operator-Splitting wie `snow`/`flowWeight`): Ziele und Anteile
        // erweitern das Arbeitsfenster um ihre Ziel-Zellen. Gemessen: die Karte
        // selbst ist dt-neutral (Eis allein auf festem Bett: dt 15,6 / 100 / 1000
        // gleich auf 0,01 %), eine Karte je 15 Sim-Jahre oder je Teilschritt
        // ändert die dt-Spanne der Langläufe nicht (`docs/glacier-measurements.md`
        // §M), kostet aber ein Vielfaches.
        let avalanche = iceAvalancheMap(domain: &domain)
        let totalK = kYear * dt * domain.scale
        let nSub = max(1, Int((totalK / max(1e-9, cfg.iceFlowSubCap)).rounded(.up)))
        let subK = kYear * dt / Double(nSub)
        let subDt = dt / Double(nSub)
        // Je Teilschritt erreicht Eis höchstens den direkten Nachbarn: im Teilschritt
        // s liegt Eis nur innerhalb von s Zellen um die Anfangssäulen und
        // Firnquellen, also rechnet Pass 2 dort `s + 1` Zellen darum — JE ZEILE
        // (Zeilenbereiche, nicht das Rechteck um alles Eis; bei Seed 1337 deckt
        // das Eis rund ein Zehntel des Rechtecks) und wachsend (die Bereiche
        // werden je Teilschritt um eine Zelle erweitert statt von Anfang an um
        // nSub). Zellen außerhalb tragen weder Eis noch Zufuhr noch Zufluss, Pass 2
        // ließe sie ohnehin unberührt (Schnell-Ausstieg): bit-identisch zum
        // vollen Rechteck um die Anfangs-Menge ± nSub. Pass 1 friert zusätzlich den
        // Rand für Nachbarfluss und Schleifspur ein (`halo`). Außerhalb bleiben
        // Eis und Bilanz null.
        let swath = max(0, cfg.iceErodeSwathRadius)
        let halo = max(1, swath)
        let nn = n
        var curLo = domain.rowLo, curHi = domain.rowHi
        for _ in 0..<nSub {
            let p2 = Terrain.dilateRows(curLo, curHi, by: 1, in: nn)
            curLo = p2.lo; curHi = p2.hi
            let p1 = Terrain.dilateRows(p2.lo, p2.hi, by: halo, in: nn)
            iceFlowSubStep(kappa: subK, dt: subDt, p1Lo: p1.lo, p1Hi: p1.hi, p2Lo: p2.lo, p2Hi: p2.hi,
                           avalanche: avalanche)
        }
        if let avalanche { clearAvalancheFeed(avalanche) }
        rebuildIceMask()
    }

    /// Zeilenbereiche (`lo ... hi` je Zeile, leer wenn `hi < lo`) um `r` Zellen in
    /// beide Richtungen erweitern: Zeile j nimmt die Vereinigung der Zeilen
    /// `j − r … j + r` und wird an beiden Enden um `r` Spalten breiter.
    private static func dilateRows(_ lo: [Int], _ hi: [Int], by r: Int, in nn: Int) -> (lo: [Int], hi: [Int]) {
        var outLo = [Int](repeating: nn, count: nn), outHi = [Int](repeating: -1, count: nn)
        for j in 0..<nn {
            var l = nn, h = -1
            for q in max(0, j - r)...min(nn - 1, j + r) where hi[q] >= lo[q] {
                if lo[q] < l { l = lo[q] }
                if hi[q] > h { h = hi[q] }
            }
            if h >= 0 { outLo[j] = max(0, l - r); outHi[j] = min(nn - 1, h + r) }
        }
        return (outLo, outHi)
    }

    private struct IceAvalanche {
        var src: [Int], dst: [Int], phi: [Double]
    }
    private func clearAvalancheFeed(_ av: IceAvalanche) {
        iceAvFeed.withUnsafeMutableBufferPointer { fb in
            let pf = fb.baseAddress!
            for s in 0..<av.src.count { pf[av.src[s]] = 0; pf[av.dst[s]] = 0 }
        }
    }

    /// Lawinen-Karte des Firns (`SimConfig.iceAvalancheSlopeHi`), einmal je Schritt
    /// aus dem Bett vom Schrittanfang (`updateIce`): jede kalte, beschneite Zelle mit
    /// Makrosteigung (Maximum im Umkreis `iceAvalancheReach`) über `Lo` bekommt
    /// ihr Ziel — die erste Zelle am Hangfuß, deren Steigung unter `Lo` liegt, auf
    /// dem steilsten Abstieg über `h` (8 Nachbarn, Diagonale durch √2) — und ihren
    /// abgehenden Anteil `φ = smoothstep((s − Lo)/(Hi − Lo))`. Der Lauf endet vor
    /// dem Meer und in Mulden (dort bleibt der Firn liegen).
    ///
    /// Zeilenparallel (je Zelle nur der eigene Eintrag in `iceAvTarget`, Pfad
    /// liest nur `h`), danach seriell kompaktiert: die Liste liegt in
    /// aufsteigender Zellreihenfolge, die Zufuhr wird also in fester
    /// Reihenfolge summiert — bit-identisch zur sequenziellen Schleife. Wie viel
    /// Zufuhr abgeht, rechnet `applyAvalancheFeed` mit der Temperatur des Betts,
    /// das der Teilschritt vor sich hat. Erweitert `domain` (Rechteck und
    /// Zeilenbereiche) um die Ziel-Zellen.
    private func iceAvalancheMap(domain: inout IceDomain) -> IceAvalanche? {
        let hiS = cfg.iceAvalancheSlopeHi
        guard hiS > 0, cfg.cellSize > 0, n >= 8 else { return nil }
        let nn = n, cnt = cfg.count
        let sea = cfg.sea, t0 = cfg.climateSeaLevelTemp, gamma = cfg.climateLapseRate
        let firnT = cfg.iceFirnTemp
        // Weltsteigung → Makrosteigung (Maßstab wie die Kennzahl „flach"):
        // `macroSlope` ist das Mittel beider Achsen je Zelle, der Faktor 2 macht
        // eine achsenparallele Wand exakt.
        let toMacro = cfg.cellSize / (2 * RenderContract.heightScale)
        let loM = max(0, cfg.iceAvalancheSlopeLo) * toMacro
        let spanM = max(1e-12, hiS * toMacro - loM)
        let maxRun = max(1, cfg.iceAvalancheMaxRun)
        if iceAvTarget.count != cnt { iceAvTarget = .init(repeating: -1, count: cnt) }
        if iceAvFeed.count != cnt { iceAvFeed = .init(repeating: 0, count: cnt) }
        if iceAvPhi.count != cnt { iceAvPhi = .init(repeating: 0, count: cnt) }
        let rowLo = max(2, domain.jLo), rowHi = min(nn - 3, domain.jHi)
        let colLo = max(2, domain.iLo), colHi = min(nn - 3, domain.iHi)
        guard rowLo <= rowHi, colLo <= colHi else { return nil }
        var rowCount = [Int](repeating: 0, count: nn)
        let reachC = max(0, cfg.iceAvalancheReach)
        let slopeAround = { (ph: UnsafePointer<Double>, i: Int, j: Int) -> Double in
            var sl = Terrain.macroSlope(ph, j * nn + i, nn)
            if reachC > 0 {
                for dj in -reachC...reachC { for di in -reachC...reachC {
                    let ii = i + di, jj = j + dj
                    if ii < 2 || ii > nn - 3 || jj < 2 || jj > nn - 3 { continue }
                    sl = max(sl, Terrain.macroSlope(ph, jj * nn + ii, nn))
                } }
            }
            return sl
        }
        h.withUnsafeBufferPointer { hb in
        snow.withUnsafeBufferPointer { sb in
        iceAvTarget.withUnsafeMutableBufferPointer { tb in
        iceAvPhi.withUnsafeMutableBufferPointer { fb in
        rowCount.withUnsafeMutableBufferPointer { cb in
            let ph = hb.baseAddress!, psnow = sb.baseAddress!
            let pt = tb.baseAddress!, pc = cb.baseAddress!, pf = fb.baseAddress!
            parallel(rowHi - rowLo + 1) { lo, hi in
                for j in (rowLo + lo)..<(rowLo + hi) {
                    var count = 0
                    for i in colLo...colHi {
                        let k = j * nn + i
                        pt[k] = -1
                        guard psnow[k] > 0, ph[k] > sea,
                              t0 - gamma * (ph[k] - sea) < firnT else { continue }
                        let sl = slopeAround(ph, i, j)
                        guard sl > loM else { continue }
                        var x = (sl - loM) / spanM
                        x = min(1, max(0, x))
                        let f = x * x * (3 - 2 * x)
                        guard f > 0 else { continue }
                        pf[k] = f
                        // Steilster Abstieg bis zur ersten nicht-steilen Zelle.
                        var c = k, ci = i, cj = j
                        var run = 0
                        while run < maxRun {
                            var best = -1, bi = 0, bj = 0, bd = 0.0
                            for dj in -1...1 { for di in -1...1 where di != 0 || dj != 0 {
                                let ii = ci + di, jj = cj + dj
                                if ii < 2 || ii > nn - 3 || jj < 2 || jj > nn - 3 { continue }
                                let q = jj * nn + ii
                                let drop = (ph[c] - ph[q]) / (di != 0 && dj != 0 ? 1.4142135623730951 : 1)
                                if drop > bd { bd = drop; best = q; bi = ii; bj = jj }
                            } }
                            if best < 0 || ph[best] <= sea { break }
                            c = best; ci = bi; cj = bj; run += 1
                            if Terrain.macroSlope(ph, c, nn) <= loM { break }
                        }
                        if c != k { pt[k] = Int32(c); count += 1 }
                    }
                    pc[j] = count
                }
            }
        }}}}}
        var src: [Int] = [], dst: [Int] = [], phi: [Double] = []
        iceAvTarget.withUnsafeBufferPointer { tb in
        iceAvPhi.withUnsafeBufferPointer { fb in
            let pt = tb.baseAddress!, pf = fb.baseAddress!
            for j in rowLo...rowHi where rowCount[j] > 0 {
                for i in colLo...colHi {
                    let k = j * nn + i
                    let c = Int(pt[k])
                    guard c >= 0 else { continue }
                    let ci = c % nn, cj = c / nn
                    src.append(k); dst.append(c); phi.append(pf[k])
                    domain.iLo = min(domain.iLo, ci); domain.iHi = max(domain.iHi, ci)
                    domain.jLo = min(domain.jLo, cj); domain.jHi = max(domain.jHi, cj)
                    domain.rowLo[cj] = min(domain.rowLo[cj], ci); domain.rowHi[cj] = max(domain.rowHi[cj], ci)
                }
            }
        }}
        return src.isEmpty ? nil : IceAvalanche(src: src, dst: dst, phi: phi)
    }

    /// Maßstab der Sub-Taktung: `max(ΣΔs⁺_max, 2·I_max)` über alle Zellen, die Eis
    /// tragen — größte Summe der positiven Oberflächen-Abfälle (Positivität,
    /// Grenze `iceFlowSubCap`) und doppelte größte Eisdicke (Diffusionszahl der
    /// Oberfläche, Grenze `iceFlowSubCap / 2`), s. `updateIce`. Beide sind
    /// Höhen je Zelle; `kappa` mal dem Maximum unter `iceFlowSubCap` hält also
    /// beide Kennzahlen eines Teilschritts unter ihrer Grenze.
    /// Zeilenweise parallel (je Zeile ein eigenes Ergebnis in Roh-Puffern,
    /// danach seriell reduziert); Maximum und Bounding-Box sind
    /// reihenfolge-unabhängig, also bit-genau reproduzierbar. Kostet EINEN
    /// Gitter-Durchlauf und spart dafür ein Vielfaches an Teilschritten.
    private struct IceDomain {
        var scale: Double, iLo: Int, iHi: Int, jLo: Int, jHi: Int
        /// Je Zeile die Spalten der ersten und letzten Zelle mit Eis oder Firnquelle
        /// (`rowHi < rowLo`: leere Zeile).
        var rowLo: [Int], rowHi: [Int]
    }

    private func iceTransportDomain() -> IceDomain {
        let nn = n
        let sea = cfg.sea, t0 = cfg.climateSeaLevelTemp, gamma = cfg.climateLapseRate
        let firnT = cfg.iceFirnTemp
        var rowScale = [Double](repeating: 0, count: nn)
        var rowILo = [Int](repeating: nn, count: nn)
        var rowIHi = [Int](repeating: -1, count: nn)
        h.withUnsafeBufferPointer { hb in
        ice.withUnsafeBufferPointer { ib in
        snow.withUnsafeBufferPointer { sb in
        rowScale.withUnsafeMutableBufferPointer { rsb in
        rowILo.withUnsafeMutableBufferPointer { rlb in
        rowIHi.withUnsafeMutableBufferPointer { rhb in
            let ph = hb.baseAddress!, pice = ib.baseAddress!, psnow = sb.baseAddress!
            let prs = rsb.baseAddress!, prl = rlb.baseAddress!, prh = rhb.baseAddress!
            parallel(nn) { jLo, jHi in
                for j in jLo..<jHi {
                    let row = j * nn
                    var scale = 0.0, iLo = nn, iHi = -1
                    for i in 0..<nn {
                        let k = row + i
                        let ik = pice[k]
                        if ik > 0 || (psnow[k] > 0 && t0 - gamma * max(0, ph[k] - sea) < firnT) {
                            iLo = min(iLo, i); iHi = max(iHi, i)
                        }
                        if ik <= 0 { continue }
                        if 2 * ik > scale { scale = 2 * ik }
                        let sk = ph[k] + ik
                        let sl = i > 0      ? ph[k - 1]  + pice[k - 1]  : sk
                        let sr = i < nn - 1 ? ph[k + 1]  + pice[k + 1]  : sk
                        let sd = j > 0      ? ph[k - nn] + pice[k - nn] : sk
                        let su = j < nn - 1 ? ph[k + nn] + pice[k + nn] : sk
                        var w = 0.0
                        if sk > sl { w += sk - sl }
                        if sk > sr { w += sk - sr }
                        if sk > sd { w += sk - sd }
                        if sk > su { w += sk - su }
                        if w > scale { scale = w }
                    }
                    prs[j] = scale; prl[j] = iLo; prh[j] = iHi
                }
            }
        }}}}}}
        var scale = 0.0
        var iLo = nn, iHi = -1, jLo = nn, jHi = -1
        for j in 0..<nn {
            if rowScale[j] > scale { scale = rowScale[j] }
            guard rowIHi[j] >= 0 else { continue }
            iLo = min(iLo, rowILo[j]); iHi = max(iHi, rowIHi[j])
            jLo = min(jLo, j); jHi = max(jHi, j)
        }
        return IceDomain(scale: scale, iLo: iLo, iHi: iHi, jLo: jLo, jHi: jHi, rowLo: rowILo, rowHi: rowIHi)
    }

    /// Lawinen-Zufuhr EINES Teilschritts: jede Quelle gibt `φ · a` ihrer Firn-
    /// Zufuhr an das Ziel am Hangfuß ab (`iceAvFeed`: Quelle −, Ziel +). `a` mit
    /// DERSELBEN Formel wie in Pass 2 (Temperatur des Betts, das der Teilschritt
    /// vor sich hat), damit eine Quelle mit `φ = 1` exakt 0 behält. Seriell über
    /// die kurze, geordnete Liste: feste Summationsreihenfolge, keine
    /// konkurrierenden Schreibzugriffe.
    private func applyAvalancheFeed(_ av: IceAvalanche, firn: Double) {
        let sea = cfg.sea, t0 = cfg.climateSeaLevelTemp, gamma = cfg.climateLapseRate
        let firnT = cfg.iceFirnTemp, coldSpan = max(1e-9, cfg.iceFirnColdSpan)
        h.withUnsafeBufferPointer { hb in
        snow.withUnsafeBufferPointer { sb in
        iceAvFeed.withUnsafeMutableBufferPointer { fb in
            let ph = hb.baseAddress!, psnow = sb.baseAddress!, pf = fb.baseAddress!
            let m = av.src.count
            for s in 0..<m { pf[av.src[s]] = 0; pf[av.dst[s]] = 0 }
            for s in 0..<m {
                let k = av.src[s]
                let t = t0 - gamma * max(0, ph[k] - sea)
                let fCold = min(1, max(0, (firnT - t) / coldSpan))
                let a = firn * psnow[k] * fCold
                if a <= 0 { continue }
                let moved = av.phi[s] * a
                pf[k] -= moved
                pf[av.dst[s]] += moved
            }
        }}}
    }

    /// EIN Teilschritt des Gletschers. Zwei Pässe über das Gitter, beide
    /// zeilenparallel und bit-identisch zur sequenziellen Schleife:
    ///
    /// * **Pass 1** liest `h`/`ice` (nur lesend) und schreibt je Zelle den
    ///   Ausstrom PRO EINHEIT Oberflächen-Abfall (`iceRate`) sowie die
    ///   eingefrorene Eis-Oberfläche (`iceSurf`). Der Deckel `moveFrac·I` sitzt
    ///   hier — mehr als diesen Anteil gibt eine Säule nie ab, das Schema kann
    ///   also keine negative Eisdicke erzeugen.
    /// * **Pass 2** liest AUSSCHLIESSLICH die beiden eingefrorenen Puffer der
    ///   Nachbarschaft und schreibt nur den eigenen Index (`ice`, `h`, `rock`,
    ///   `sed`). Genau deshalb braucht es den Scratch: Pass 2 verändert `h`, und
    ///   ohne die eingefrorene Oberfläche läse der Nachbar ein halb erodiertes
    ///   Gefälle (und das Ergebnis hinge an der Thread-Aufteilung).
    ///
    /// Die Summe der Abfälle (`ΣΔs⁺`) wird in Pass 2 in derselben
    /// Nachbar-Reihenfolge wie in Pass 1 gebildet — der Ausstrom, den eine Zelle
    /// abzieht, ist damit dieselbe Zahl, die ihre Nachbarn als Zufluss
    /// gutschreiben (bis auf die eine Division `out/ΣΔs⁺`, gegen die der
    /// Nullpunkt-Wächter `if I < 0` steht).
    private func iceFlowSubStep(kappa: Double, dt: Double,
                                p1Lo: [Int], p1Hi: [Int], p2Lo: [Int], p2Hi: [Int],
                                avalanche: IceAvalanche?) {
        let nn = n, cnt = cfg.count
        let sea = cfg.sea, cs = cfg.cellSize
        let moveFrac = max(0, cfg.iceFlowMoveFraction)
        // DIESELBE Schwelle, die `underIce` zieht (s. `rebuildIceMask`): unterhalb
        // fließt kein Eis und es schleift auch keines. Sonst liefen in einer Zelle
        // am dünnen Saum FLUVIALE und GLAZIALE Erosion gleichzeitig — die fluvialen
        // Gates hängen an `underIce`, das Fließen und die Abrasion hingen vorher an
        // „irgendeine positive Restdicke". Die BILANZ (Zufuhr, Schmelze, Moräne)
        // läuft für dünnes Eis weiter: ein Schneefeld muss über die Schwelle
        // wachsen können, sonst gäbe es nie einen Gletscher.
        let thr = max(0, cfg.iceMinThickness)
        let coldSpan = max(1e-9, cfg.iceFirnColdSpan)
        let t0 = cfg.climateSeaLevelTemp, gamma = cfg.climateLapseRate
        let firnT = cfg.iceFirnTemp
        let firn = cfg.iceFirnPerSnowYear
        let baseMu = 1 / max(1e-9, cfg.iceTurnoverYears)
        let eBase = exp(-baseMu * dt)
        let meltC = max(0, cfg.iceMeltPerKYear)
        let moraine = max(0, cfg.iceMoraineK)
        let kEro = max(0, cfg.iceErodeK), mEro = cfg.iceErodeFluxExp
        let mEroIsHalf = mEro == 0.5
        let swath = max(0, cfg.iceErodeSwathRadius)
        let swathSide = 2 * swath + 1
        let swathNorm = 1.0 / Double(swathSide * swathSide)
        // Zeilenbereiche von Pass 1 (mit Rand für Nachbarfluss und Schleifspur) und
        // Pass 2 (Wirkungsbereich), s. `updateIce`; leere Zeilen haben `hi < lo`.
        var freezeJLo = nn, freezeJHi = -1, jLo = nn, jHi = -1
        for j in 0..<nn {
            if p1Hi[j] >= p1Lo[j] { freezeJLo = min(freezeJLo, j); freezeJHi = max(freezeJHi, j) }
            if p2Hi[j] >= p2Lo[j] { jLo = min(jLo, j); jHi = max(jHi, j) }
        }
        guard jHi >= jLo else { return }
        // Gesteinshärte (Issue #12): Abrasion ∝ Eisfluss × Erodierbarkeit. Der
        // Faktor wirkt NUR auf den Fels-Anteil (Regolith weiß nicht, welches
        // Gestein darunter liegt) und wird nur angefasst, wenn er ≠ 1 ist —
        // sonst liefe eine andere Gleitkomma-Reihenfolge und der Lauf driftete um
        // 1 ulp weg (dieselbe Falle wie in `Hydraulic.dig`, dort ausgemessen).
        let lithOn = lithErodeK.count == cnt
        let lithArr = lithOn ? lithErodeK : [1.0]
        if let av = avalanche { applyAvalancheFeed(av, firn: firn) }
        let feedOn = avalanche != nil
        let feedArr = feedOn ? iceAvFeed : [0.0]
        h.withUnsafeMutableBufferPointer { hb in
        rock.withUnsafeMutableBufferPointer { rkb in
        sed.withUnsafeMutableBufferPointer { sb in
        ice.withUnsafeMutableBufferPointer { ib in
        snow.withUnsafeBufferPointer { snb in
        lithArr.withUnsafeBufferPointer { ldb in
        feedArr.withUnsafeBufferPointer { fdb in
        iceRate.withUnsafeMutableBufferPointer { rtb in
        iceSurf.withUnsafeMutableBufferPointer { sfb in
        iceEro.withUnsafeMutableBufferPointer { erb in
        iceEroH.withUnsafeMutableBufferPointer { ehb in
            let ph = hb.baseAddress!, prock = rkb.baseAddress!, psed = sb.baseAddress!
            let pice = ib.baseAddress!, psnow = snb.baseAddress!
            let plith = ldb.baseAddress!, pfeed = fdb.baseAddress!
            let prate = rtb.baseAddress!, psurf = sfb.baseAddress!, pero = erb.baseAddress!
            let peroH = ehb.baseAddress!
            // ---- Pass 1: Oberfläche einfrieren, Ausstrom je Zelle bestimmen ----
            parallel(freezeJHi - freezeJLo + 1) { rowLo, rowHi in
            for j in (freezeJLo + rowLo)..<(freezeJLo + rowHi) {
                guard p1Hi[j] >= p1Lo[j] else { continue }
                for i in p1Lo[j]...p1Hi[j] {
                    let k = j * nn + i
                    let sk = ph[k] + pice[k]
                    psurf[k] = sk
                    let ik = pice[k]
                    if ik <= thr { prate[k] = 0; pero[k] = 0; continue }
                    // Rand gespiegelt (Abfall 0): Eis verlässt die Welt nicht.
                    let sl = i > 0      ? ph[k - 1]  + pice[k - 1]  : sk
                    let sr = i < nn - 1 ? ph[k + 1]  + pice[k + 1]  : sk
                    let sd = j > 0      ? ph[k - nn] + pice[k - nn] : sk
                    let su = j < nn - 1 ? ph[k + nn] + pice[k + nn] : sk
                    var w = 0.0
                    if sk > sl { w += sk - sl }
                    if sk > sr { w += sk - sr }
                    if sk > sd { w += sk - sd }
                    if sk > su { w += sk - su }
                    if w <= 0 { prate[k] = 0; pero[k] = 0; continue } // Mulde: Eis bleibt liegen
                    var out = kappa * ik * w
                    let cap = moveFrac * ik
                    if out > cap { out = cap }
                    prate[k] = out / w
                    // Glaziale Erosions-RATE (je Jahr) am Ort ihrer Entstehung.
                    // Sie wird in Pass 2 über die Schleifspur verteilt, deshalb
                    // steht sie hier im Scratch statt direkt im Gelände.
                    // q = Eisdicke × Oberflächen-Gefälle ist der Gleit-/Fluss-Proxy.
                    // cellSize 0 (keine definierte Schrittweite): kein Gefälle, kein Schliff.
                    if kEro > 0 && cs > 0 && ph[k] > sea {
                        let slope = w / cs
                        // Exponent 0,5 (Standard) als Wurzel: `pow` war der größte Einzelposten
                        // des Passes (Messprotokoll §M); Ergebnis höchstens 1 ulp anders.
                        pero[k] = kEro * (mEroIsHalf ? (ik * slope).squareRoot() : pow(ik * slope, mEro)) * slope
                    } else {
                        pero[k] = 0
                    }
                }
                // Schleifspur, erste Hälfte: Kastensumme der Rate entlang der Zeile.
                // Die Rate ist nur unter Eis ungleich 0, also streut jede Eis-Zelle
                // ihren Wert auf die `2·swath + 1` Nachbarn der EIGENEN Zeile (je Zeile
                // ein Thread, feste Reihenfolge von links nach rechts: bit-identisch
                // zur sequenziellen Schleife); Pass 2 summiert die Zeilensummen
                // senkrecht. Zwei Kastensummen statt (2·swath + 1)² Lesezugriffen je
                // erodierender Zelle — bei Radius 4 sind das 18 statt 81.
                if swath > 0 && kEro > 0 {
                    let base = j * nn
                    for i in max(0, p1Lo[j] - swath)...min(nn - 1, p1Hi[j] + swath) { peroH[base + i] = 0 }
                    for i in p1Lo[j]...p1Hi[j] {
                        let e = pero[base + i]
                        if e != 0 {
                            for ii in max(0, i - swath)...min(nn - 1, i + swath) { peroH[base + ii] += e }
                        }
                    }
                }
            }
            }
            // ---- Pass 2: Zufluss sammeln, erodieren, Bilanz, Moräne ----
            parallel(jHi - jLo + 1) { rowLo, rowHi in
            for j in (jLo + rowLo)..<(jLo + rowHi) {
                guard p2Hi[j] >= p2Lo[j] else { continue }
                for i in p2Lo[j]...p2Hi[j] {
                    let k = j * nn + i
                    // Schnell-Ausstieg VOR den verzweigten Zufluss-Summen: eine eisfreie
                    // Zelle ohne Schnee, ohne Lawinen-Zufuhr und ohne einen Nachbarn mit
                    // Ausstrom bekommt keinen Zufluss (`prate = 0` heißt: nichts fließt
                    // heraus) und keine Zufuhr — dieselbe Abkürzung wie unten
                    // (`i0 == 0 && inflow == 0 && a == 0`), nur ohne die ~50 %
                    // fehlvorhergesagten Zweige auf dem Höhenrauschen; bit-gleich.
                    if pice[k] == 0 && psnow[k] == 0 && (!feedOn || pfeed[k] == 0)
                        && (i == 0 || prate[k - 1] == 0) && (i == nn - 1 || prate[k + 1] == 0)
                        && (j == 0 || prate[k - nn] == 0) && (j == nn - 1 || prate[k + nn] == 0) {
                        continue
                    }
                    let sk = psurf[k]
                    var inflow = 0.0, w = 0.0
                    // Dieselbe Reihenfolge wie Pass 1 (l, r, d, u): `w` ist damit
                    // bit-genau dieselbe Summe.
                    if i > 0      { let d = psurf[k - 1]  - sk
                                    if d > 0 { inflow += prate[k - 1]  * d } else { w -= d } }
                    if i < nn - 1 { let d = psurf[k + 1]  - sk
                                    if d > 0 { inflow += prate[k + 1]  * d } else { w -= d } }
                    if j > 0      { let d = psurf[k - nn] - sk
                                    if d > 0 { inflow += prate[k - nn] * d } else { w -= d } }
                    if j < nn - 1 { let d = psurf[k + nn] - sk
                                    if d > 0 { inflow += prate[k + nn] * d } else { w -= d } }
                    let i0 = pice[k]
                    // Temperatur des Betts, auf dem dieser Teilschritt steht —
                    // dieselbe Formel wie in `updateClimate` (bei unverändertem
                    // `h` also bit-gleich zum Feld). Das Feld selbst ist vom
                    // vorigen Schrittende: der Schliff dieses Schritts senkt das
                    // Bett, in großen Schritten um ein Vielfaches mehr, und das
                    // Eis sähe sonst über den ganzen Schritt das kältere,
                    // höhere Bett (gemessen: 3 % mehr Eis je 1000-Jahr-Schritt
                    // als in zehn Schritten à 100, `docs/glacier-measurements.md`
                    // §L).
                    let t = t0 - gamma * max(0, ph[k] - sea)
                    let fCold = min(1, max(0, (firnT - t) / coldSpan))
                    var a = firn * psnow[k] * fCold
                    if feedOn { a += pfeed[k]; if a < 0 { a = 0 } }
                    // Eisfreie Zelle ohne Zufluss und ohne Zufuhr: nichts zu
                    // rechnen (das Meer und alles Land unterhalb der Firn-Grenze)
                    // — BIT-IDENTISCH zur vollen Rechnung, nicht genähert
                    // (0 + (0−0)·e^… = 0), und der Zweig trägt die große Mehrheit
                    // der Zellen. Dieselbe Abkürzung wie in `updateClimate`.
                    if i0 == 0 && inflow == 0 && a == 0 { continue }
                    var iceNow = i0 + inflow - prate[k] * w
                    if iceNow < 0 { iceNow = 0 }   // s. Doku: Rest der einen Division
                    // ---- Glaziale Erosion (Flux-Modell + Schleifspur) ----
                    // Die Rate steht aus Pass 1 im Scratch (auf der Dicke VOR dem
                    // Transport — das ist das Eis, das diesen Teilschritt über das
                    // Bett gescheuert hat). Hier wird sie über die SCHLEIFSPUR
                    // gemittelt: `swath` Zellen im Quadrat, Gewichte gleich und
                    // die Summe auf die volle Fenstergröße normiert.
                    //
                    // Warum der Ausstrich sein muss (`docs/research-climate-cryosphere.md`
                    // §4.3 sagt es voraus, `docs/glacier-measurements.md` §D misst es):
                    // die LOKALE Flux-Rate ist im Thalweg am größten und gräbt
                    // dort eine Kerbe — das Querprofil wird V-IGER statt U-iger
                    // (gemessen ohne Ausstrich: 1.447 gegen 1.352 im eisfreien
                    // Referenzarm, also die falsche Richtung). Der Gletscher
                    // schleift aber über seine ganze BREITE. Liebl et al. 2023
                    // lösen dasselbe Problem im OpenLEM mit derselben Maßnahme
                    // („artificially expanded erosion swath").
                    //
                    // GATHER statt Scatter: jede Zelle SAMMELT die Raten ihrer
                    // Nachbarschaft, statt ihre eigene zu verteilen — nur so
                    // schreibt Pass 2 weiterhin ausschließlich den eigenen Index
                    // und bleibt parallel bit-identisch. Bei gleichen Gewichten
                    // ist das dieselbe Gesamtmenge (Faltung ist symmetrisch).
                    if kEro > 0 && i0 > thr && w > 0 && ph[k] > sea {
                        var rate = pero[k]
                        if swath > 0 {
                            var sum = 0.0
                            for dj in -swath...swath {
                                let jj = j + dj
                                if jj < 0 || jj >= nn { continue }
                                sum += peroH[jj * nn + i]
                            }
                            rate = sum * swathNorm
                        }
                        var d = rate * dt
                        // Deckel als RATE gelesen (AGENTS.md): ein Teilschritt
                        // nimmt höchstens ein Viertel der lokalen Oberflächen-
                        // Abfälle mit. Bindet im kalibrierten Lauf nicht; er hält
                        // den Trog davon ab, sich in EINEM Teilschritt unter seine
                        // Nachbarn zu graben (dort staut sich sonst das Eis).
                        let capD = 0.25 * w
                        if d > capD { d = capD }
                        let f = lithOn ? plith[k] : 1.0
                        if f != 1.0 {
                            let s = psed[k]
                            if d > s { d = s + (d - s) * f }
                        }
                        if d > 0 {
                            let take = min(d, psed[k])
                            psed[k] -= take
                            prock[k] -= (d - take)
                            ph[k] -= d
                        }
                    }
                    // ---- Massenbilanz (exakte Relaxationsform) ----
                    let meltRate = meltC * max(0, t)
                    let mu = baseMu + meltRate
                    let target = a / mu
                    // Ohne Schmelze (T ≤ 0, das Nährgebiet) ist μ = baseMu und der Faktor
                    // der EINE Wert dieses Teilschritts (`x + 0.0 = x`: bit-gleich).
                    let e = meltRate == 0 ? eBase : exp(-mu * dt)
                    pice[k] = target + (iceNow - target) * e
                    // ---- Moräne: was AUSSCHMILZT, legt seine Schuttfracht ab ----
                    // ∫₀^dt μ·I dt = μ·I*·dt + (I₀−I*)·(1−e^(−μdt)) — exakt, und
                    // davon zählt nur der Schmelz-Anteil von μ (der Grundumsatz ist
                    // Sublimation/Kalben, der trägt keinen Schutt aus). Im
                    // Akkumulationsgebiet (T ≤ 0) ist der Anteil exakt 0.
                    if moraine > 0 && meltRate > 0 && ph[k] > sea {
                        var ablated = mu * target * dt + (iceNow - target) * (1 - e)
                        if ablated < 0 { ablated = 0 }
                        let dep = moraine * ablated * (meltRate / mu)
                        if dep > 0 { psed[k] += dep; ph[k] += dep }
                    }
                    // Kalben: was das Meer erreicht, geht verloren. (Ein
                    // Schelfeis-Modell wäre eine eigene Physik; die Insel ist
                    // dafür zu klein.)
                    if ph[k] <= sea { pice[k] = 0 }
                }
            }
            }
        }}}}}}}}}}}
    }

    /// Baut `underIce` aus der frischen Eisdicke. **Leer, wenn keine Zelle über
    /// der Schwelle liegt** — dann greift keines der fluvialen Gates und die
    /// Arithmetik ist bit-identisch zum Stand ohne Gletscher.
    /// Sequenziell: das Ergebnis hängt an keiner Summationsreihenfolge, und der
    /// Pass ist ein reiner Vergleich je Zelle.
    private func rebuildIceMask() {
        let cnt = cfg.count, thr = cfg.iceMinThickness
        guard anyCell(ice, { $0 > thr }) else {
            if !underIce.isEmpty { underIce = [] }
            return
        }
        if underIce.count != cnt { underIce = .init(repeating: false, count: cnt) }
        underIce.withUnsafeMutableBufferPointer { ub in
        ice.withUnsafeBufferPointer { ib in
            let pu = ub.baseAddress!, pi = ib.baseAddress!
            for k in 0..<cnt { pu[k] = pi[k] > thr }
        }}
    }

    /// Sättigung einer Eisdicke zur **Deckung** (0 … <1): `I/(I + ref)` — dieselbe
    /// Bauform wie `snowCoverage`. EINZIGE Quelle der Formel; der Färbungs-Loop in
    /// `SimRender.TerrainColorRenderer` ruft sie über den rohen Puffer auf, statt
    /// sie ein zweites Mal hinzuschreiben. Wächter:
    /// `Glacier.testIceCoverIsTheSingleSourceForColouring`.
    @inline(__always) public static func iceCoverage(thickness: Double, ref: Double) -> Double {
        thickness / (thickness + ref)
    }

    /// **Eisdeckung** einer Zelle (0 … <1) — die EINE Quelle für die Eis-Färbung.
    /// Ohne Eisfeld (Klima aus) exakt 0: dann malt der Renderer nur Schnee, also
    /// genau das Bild von vor #35.
    @inline(__always) public func iceCover(_ k: Int) -> Double {
        guard ice.count == cfg.count else { return 0 }
        return Terrain.iceCoverage(thickness: ice[k], ref: cfg.iceCoverRef)
    }

    // MARK: - Vegetation

    /// Leitet die Höhenbänder (Issue #4) aus der aktuellen Landhöhen-Verteilung ab.
    /// Reine ABLEITUNG aus `h`, kein Pass mit Zustand — Aufrufstelle ist deshalb
    /// unkritisch, solange sie nach der letzten Höhenänderung des Schritts liegt
    /// (Anfang von `updateVegetation`, das in `step()` zuletzt läuft) und vor jedem
    /// Konsumenten.
    ///
    /// **Kosten, gemessen statt geschätzt** (n=832, Mittel über 200 Durchläufe):
    /// dieser Pass 1.38 ms, der Servo-Pass (`landReliefRobust`) 1.42 ms. Beide sind
    /// ZUSÄTZLICH zueinander — sie laufen an verschiedenen Stellen des Schritts und
    /// müssen es: der Servo liest die Höhen am SCHRITTBEGINN (`applyUplift` →
    /// `reliefServoRate`), die Bänder die FINALEN Höhen des Schritts. Ein
    /// gemeinsamer Pass wäre also keine Optimierung, sondern eine andere Physik.
    /// Unterm Strich kostet Issue #4 damit ~1.4 ms je `step()` — bei 60 fps
    /// Echtzeit-Zeitraffer (winziges dt/Frame, `step()` je Frame) rund 8 % des
    /// 16.7-ms-Budgets.
    ///
    /// Verworfene Auswege: ein Dirty-Flag auf `h` müsste JEDE Mutation in jedem
    /// Erosionspass mitziehen (fehleranfällig, und im Zeitraffer ist `h` ohnehin
    /// jeden Frame schmutzig); ein Neuableiten nur alle N Jahre würde die getestete
    /// dt-Invarianz brechen (Zeitraffer und +10.000-J.-Sprung müssen dasselbe
    /// Ergebnis liefern). Offener, sauberer Weg wäre ein paralleler Histogramm-Fill
    /// (Bins je Thread, Integer-Summen → bit-identisch); das ist eine eigene
    /// Optimierung und nicht Teil dieses Tickets.
    ///
    /// **Die Schneegrenze kommt seit Issue #33 aus dem Schneefeld**, nicht mehr
    /// aus `bandSnowPercentile`: `snowAreaFractions()` misst, wie viel Land das
    /// Klima gerade beschneit, und dieser Anteil wird zurück auf ein Höhenquantil
    /// projiziert. Der Aufruf muss deshalb NACH `updateClimate` liegen (in
    /// `step()` tut er das: Klima direkt vor `updateVegetation`). Ohne Klima
    /// liefert `snowAreaFractions()` `nil` und die Perzentile greifen wie vorher.
    public func updateHeightBands() {
        heightBands = cfg.heightBandsOverride
            ?? HeightBands.fromLandHeights(h, cfg: cfg, snowFractions: snowAreaFractions())
    }

    /// Grob-Steigung um eine Zelle (±2 Zellen, Mittel über beide Achsen).
    /// EINZIGE Quelle für alle „ist das ein Hang?"-Abfragen (Vegetation, Biom-
    /// Färbung, Baum-Platzierung): seit der Pre-Erosion trägt jede Zelle feine
    /// Rinnen — die Per-Zell-Steigung wäre überall „steil" und würde Bewuchs und
    /// Farbe aus allen Tälern waschen. Nur für Zellen mit 2 ≤ i,j ≤ n−3 gültig
    /// (der Aufrufer hält den Rand frei).
    @inline(__always)
    public static func macroSlope(_ p: UnsafePointer<Double>, _ k: Int, _ n: Int) -> Double {
        (abs(p[k + 2] - p[k - 2]) + abs(p[k + 2 * n] - p[k - 2 * n])) * 0.125
    }

    /// Bequeme Variante auf dem Array — dieselbe Formel, nur ein Aufrufweg für
    /// Stellen ohne bereits geöffneten Puffer (z. B. Tests).
    @inline(__always)
    public static func macroSlope(_ a: [Double], _ k: Int, _ n: Int) -> Double {
        a.withUnsafeBufferPointer { macroSlope($0.baseAddress!, k, n) }
    }

    /// Geografische Eignung eines Standorts für Bewuchs (0…1) aus Höhe, Grob-
    /// Steigung und Feuchte. EINZIGE Quelle: der Sim-Kern (`updateVegetation`,
    /// Relaxationsziel von `veg`) und die Biom-Färbung
    /// (`SimRender.TerrainColorRenderer`, Grünanteil) lasen dieselbe Logik vorher
    /// aus zwei Kopien mit auseinandergelaufenen Konstanten (Höhenabfall ab 0.5
    /// bzw. 0.6, Regenfaktor 1.3 bzw. 1.2) — die Färbung zeigte damit nicht ganz
    /// das, was die Sim rechnet.
    @inline(__always)
    public static func vegetationSuitability(height: Double, slope: Double, rain: Double,
                                             bands: HeightBands) -> Double {
        let slopeOk = max(0, 1 - slope * 40)
        let wet = min(1, rain * 1.3)
        return slopeOk * wet * bands.vegetationAltitudeFactor(height)
    }

    public func updateVegetation(years: Double) {
        updateHeightBands()
        let bands = heightBands
        // Exponentielle Relaxation (Issue #2) wie beim Flood-Kill darunter: die
        // lineare Form war bei τ = 250 a schon ab dt = 250 gesättigt (ein
        // 2000-Jahr-Sprung setzte `veg` INSTANTAN aufs Ziel, derselbe Zeitraum
        // in 240-Jahr-Schritten nicht). `veg` geht über `vegDamp` in JEDEN
        // Erosionspass ein — die Abweichung wanderte damit direkt ins Relief.
        let f = Terrain.relaxFraction(dt: years, tau: cfg.vegTimeConstant)
        // Flood-Kill (Stufe 3): eigene, schnelle Zeitkonstante. Exponentiell
        // exakt (1 − e^(−dt/τ)) statt linear gedeckelt: bei τ = 20a ist schon
        // ein Zeitraffer-Schritt (dt ≈ 9..240 J.) fast vollständig — die
        // exakte Form hält kleine und große Schritte konsistent.
        let fKill = Terrain.relaxFraction(dt: years, tau: cfg.vegFloodKillYears)
        let killDepth = cfg.vegFloodKillDepth
        // Sukzession (Stufe 3), Pass 1: Samen-Druck = max(veg) im Dispersal-
        // Umkreis → vegScratch. Liest nur veg, schreibt nur vegScratch[k]
        // → parallel bit-identisch (Pass1/Pass2-Muster wie hillslopeDiffusion).
        let dispersal = cfg.vegDispersalStrength
        let dr = max(0, Int(cfg.vegDispersalRadius.rounded()))
        let nn = n, sea = cfg.sea
        if dispersal > 0 && dr > 0 {
            // PERF (Issue #43): das Box-Maximum ist SEPARABEL — Maximum ist
            // assoziativ und kommutativ, und der Spalten-Ausschnitt hängt nur
            // von `i` ab, der Zeilen-Ausschnitt nur von `j`. Erst zeilenweise,
            // dann spaltenweise maximieren liefert also exakt dasselbe Ergebnis
            // wie das (2dr+1)²-Fenster, kostet aber 2·(2dr+1) statt (2dr+1)²
            // Vergleiche je Zelle (dr = 2: 10 statt 25).
            if vegScratchRow.count != cfg.count {
                vegScratchRow = .init(repeating: 0, count: cfg.count)
            }
            veg.withUnsafeBufferPointer { vb in
            vegScratchRow.withUnsafeMutableBufferPointer { rb in
                let pveg = vb.baseAddress!, prow = rb.baseAddress!
                let iLo = min(dr, nn)
                let iHi = max(iLo, nn - dr)
                parallel(nn) { jLo, jHi in
                    for j in jLo..<jHi {
                        let row = j * nn
                        let psrc = pveg + row, pdst = prow + row
                        for i in 0..<iLo {
                            var m = 0.0
                            for di in max(0, i - dr)...min(nn - 1, i + dr) {
                                m = max(m, psrc[di])
                            }
                            pdst[i] = m
                        }
                        if dr == 2 {
                            for i in iLo..<iHi {
                                pdst[i] = max(psrc[i - 2], max(psrc[i - 1], max(psrc[i], max(psrc[i + 1], psrc[i + 2]))))
                            }
                        } else {
                            for i in iLo..<iHi {
                                var m = psrc[i - dr]
                                for di in (i - dr + 1)...(i + dr) {
                                    m = max(m, psrc[di])
                                }
                                pdst[i] = m
                            }
                        }
                        for i in iHi..<nn {
                            var m = 0.0
                            for di in max(0, i - dr)...min(nn - 1, i + dr) {
                                m = max(m, psrc[di])
                            }
                            pdst[i] = m
                        }
                    }
                }
            }}
            vegScratchRow.withUnsafeBufferPointer { rb in
            vegScratch.withUnsafeMutableBufferPointer { sb in
                let prow = rb.baseAddress!, psc = sb.baseAddress!
                parallel(nn) { jLo, jHi in
                    for j in jLo..<jHi {
                        let jStart = max(0, j - dr)
                        let jEnd = min(nn - 1, j + dr)
                        let dst = psc + j * nn
                        let src0 = prow + jStart * nn
                        for i in 0..<nn { dst[i] = src0[i] }
                        for rj in (jStart + 1)...jEnd {
                            let src = prow + rj * nn
                            for i in 0..<nn {
                                dst[i] = max(dst[i], src[i])
                            }
                        }
                    }
                }
            }}
        }
        // Störungs-Unterdrückung (Issue #26): frisch umgegrabener Rohboden ist
        // kein Standort. Ohne aktive Störung ist das Feld exakt 0 und der
        // Faktor exakt 1.0 → bit-identische Arithmetik zum Stand vor #26.
        let disturbSuppress = cfg.disturbanceEnabled ? cfg.disturbanceVegSuppress : 0
        h.withUnsafeBufferPointer { hb in
        hf.withUnsafeBufferPointer { hfb in
        rain.withUnsafeBufferPointer { rnb in
        vegScratch.withUnsafeBufferPointer { scb in
        saltCrust.withUnsafeBufferPointer { slb in
        disturb.withUnsafeBufferPointer { dsb in
        veg.withUnsafeMutableBufferPointer { vb in
            let ph = hb.baseAddress!, phf = hfb.baseAddress!
            let prain = rnb.baseAddress!, pseed = scb.baseAddress!
            let psalt = slb.baseAddress!, pdist = dsb.baseAddress!
            let pveg = vb.baseAddress!
            // Schreibt nur veg[k] → zeilenparallel, bit-identisch.
            parallel(nn - 4) { lo, hi in
            for j in (lo + 2)..<(hi + 2) {
                for i in 2..<(nn - 2) {
                    let k = j * nn + i
                    // Flood-Kill: tief überflutet → schneller Absterbe-Pfad
                    // statt Relaxation. Auwald steht am tiefsten und säuft
                    // zuerst ab, dann Wald — emergent aus der Topografie.
                    if phf[k] - ph[k] > killDepth {
                        pveg[k] -= pveg[k] * fKill
                        continue
                    }
                    var target = 0.0
                    let v = ph[k]
                    // Obergrenze aus dem Höhenband (Issue #4): früher fest 0.68 —
                    // ein Wert, der bei der aktuellen Kalibrierung über dem
                    // 99,99-Perzentil des Landes lag und damit nie griff.
                    if v > sea + 0.005 && v < bands.vegNone && phf[k] - ph[k] <= 0.015 {
                        let slope = Terrain.macroSlope(ph, k, nn)
                        target = Terrain.vegetationSuitability(height: v, slope: slope,
                                                               rain: prain[k], bands: bands)
                        // Sukzession: Samen-Druck hebt das Ziel NUR auf bewohnbaren
                        // Standorten (geografisches Ziel > 0.05) — steile Hänge und
                        // Höhenwüste bleiben kahl, kein Spontanwald auf kargen Inseln.
                        if dispersal > 0 && target > 0.05 {
                            target = max(target, pseed[k] * dispersal)
                        }
                        // Salzpfanne (Issue #11): der Verdunstungsrückstand eines
                        // ausgetrockneten abflusslosen Beckens ist ein kahler
                        // Standort — sonst begrünt der flache, tief liegende
                        // Beckenboden sofort (flach + Grundfeuchte = hohes Ziel).
                        // Wirkt NUR über saltCrust, das außerhalb solcher Becken
                        // exakt 0 ist → für alles andere unverändert.
                        target *= 1 - psalt[k]
                        // Baustelle (Issue #26): der Störungsgrad drückt das Ziel
                        // gegen 0 und klingt aus → sichtbare Sukzession auf der
                        // frischen Fläche statt sofortiger Waldtapete. Außerhalb
                        // von Eingriffen ist pdist exakt 0.
                        if disturbSuppress > 0 && pdist[k] > 0 {
                            target *= max(0, 1 - disturbSuppress * pdist[k])
                        }
                    }
                    pveg[k] += (target - pveg[k]) * f
                }
            }
            }
        }}}}}}}
        updateVegClass()
    }

    /// Vegetations-Schutzfaktor der Erosionspässe: (1 − 0.6·typFactor·veg).
    /// Die 0.6-Basiskalibrierung bleibt unangetastet (Kalibrier-Kaskade); die
    /// Klassen-Faktoren verstärken sie nur multiplikativ (Gras 1.0 = Status quo,
    /// Wald/Auwald schützen stärker). Max-Produkt 0.6·1.3 = 0.78 < 1.
    @inline(__always) func vegDamp(_ k: Int) -> Double {
        max(0, 1 - 0.6 * vegTypeFactor[Int(vegClass[k])] * veg[k])
    }

    /// Leitet die Vegetations-Klasse je Zelle ab (0 kahl · 1 Gras · 2 Wald ·
    /// 3 Auwald). Auwald = flussnah + flach + feucht: Flussnähe kommt aus einer
    /// gedämpften 3×3-Max-Dilatation (3 Runden, Abfall 0.65/Ring → Werte 1.0 /
    /// 0.65 / 0.42 / 0.27) der Wasser-Maske (substanzielle Läufe `area` ≥
    /// braidMinCells ODER stehendes Wasser hf−h > 0.02). Die Maske liest
    /// bewusst das D8-Netz (`area`), NICHT `areaMFD`: vegClass geht über
    /// `vegDamp` in die Erosion ein, und MFD darf laut AGENTS.md nur Render und
    /// Braiding speisen. D8 konzentriert den Abfluss auf eine Zellspur — die
    /// Ufer-Breite kommt ohnehin aus der Dilatation, nicht aus der Maskenbreite.
    ///
    /// Gehölz sitzt am UFER, nicht im BETT: die Maskenzellen selbst (der
    /// Wasserlauf) bleiben Gras, egal wie dicht `veg` dort ist. Sie mit einer
    /// Gehölz-Klasse zu belegen hieß, Wurzel-Kohäsion auf das Gerinne und den
    /// Talboden zu legen — der Talboden panzerte sich, stehen gebliebene
    /// Knubbel im MFD-Lauf zählten als „Inseln" (Messung Aug 2026:
    /// `testBraidingBuildsBars` zählte im Arm OHNE Braiding-Pass 19 → 31 Inseln
    /// über 12 Seeds, obwohl dort nie ein Bänke-Pass lief; der Braiding-Arm
    /// blieb bei 36 → 37). Gras (Faktor 1.0) heißt: auf dem Gerinne gilt exakt
    /// die Vor-Merge-Dämpfung 1 − 0.6·veg.
    /// Alle Eingangsgrößen
    /// sind glatt (veg relaxiert über τ=250a, riparian fällt über Ringe ab,
    /// Steigung ±2 Zellen) → weiche Klassen-Übergänge statt Flickenteppich.
    /// Determinismus: jeder Pass liest nur fremde Puffer und schreibt
    /// ausschließlich seinen eigenen Index → parallel bit-identisch.
    private func updateVegClass() {
        let nn = n, sea = cfg.sea, cnt = cfg.count
        let cellArea = cfg.cellSize * cfg.cellSize
        let minA = cfg.braidMinCells * cellArea
        // Pass 1: Wasser-Quellmaske → riparian.
        h.withUnsafeBufferPointer { hb in
        hf.withUnsafeBufferPointer { hfb in
        area.withUnsafeBufferPointer { ab in
        riparian.withUnsafeMutableBufferPointer { rb in
            let ph = hb.baseAddress!, phf = hfb.baseAddress!
            let pa = ab.baseAddress!, prip = rb.baseAddress!
            parallel(cnt) { lo, hi in
                for k in lo..<hi {
                    let water = phf[k] > sea
                        && (pa[k] >= minA || phf[k] - ph[k] > 0.02)
                    prip[k] = water ? 1.0 : 0.0
                }
            }
        }}}}
        // Pass 2: 3 Dilatationsrunden (riparian ↔ vegScratch).
        for _ in 0..<3 {
            dilateDamped(from: riparian, to: &vegScratch)
            swap(&riparian, &vegScratch)
        }
        // Pass 3: Klassen. Der 2er-Rand bleibt kahl (wie in updateVegetation,
        // die dort auch kein veg aufbaut).
        h.withUnsafeBufferPointer { hb in
        hf.withUnsafeBufferPointer { hfb in
        veg.withUnsafeBufferPointer { vb in
        riparian.withUnsafeBufferPointer { rb in
        vegClass.withUnsafeMutableBufferPointer { cb in
            let ph = hb.baseAddress!, phf = hfb.baseAddress!
            let pveg = vb.baseAddress!, prip = rb.baseAddress!
            let pcls = cb.baseAddress!
            parallel(nn - 4) { lo, hi in
            for j in (lo + 2)..<(hi + 2) {
                for i in 2..<(nn - 2) {
                    let k = j * nn + i
                    var cls: UInt8 = 0
                    let v = pveg[k]
                    if ph[k] > sea + 0.005 && v >= 0.12 {
                        // Auwald: bis ~2 Zellen vom Wasser (riparian ≥ 0.4),
                        // flach (etwas toleranter als die Baum-Maske) und nicht
                        // selbst tief überflutet. Sonst: dichter Bewuchs = Wald,
                        // Rest = Gras. Kahl nur bei v < 0.12 (steil/hoch/nass
                        // drückt schon das veg-Ziel auf 0 — die Klasse folgt).
                        //
                        // GEHÖLZ (Wald UND Auwald) ist eine UFER-, keine
                        // BETT-Klasse: die Quellmaske-Zellen SELBST sind der
                        // Wasserlauf, und ein Flussbett trägt kein Gehölz.
                        // Nach der Dilatation gilt `riparian == 1` exakt für die
                        // Maskenzellen (dst = max(src, 0.65·maxNb) hält 1.0 und
                        // hebt Nicht-Masken-Zellen auf höchstens 0.65) — das
                        // identifiziert das Bett ohne Zusatzpuffer. Dieselbe
                        // Doktrin wie meanderStamp, das die Bett-Vegetation
                        // wegreißt (testMeanderStampKillsBedVegetation).
                        //
                        // Bett → Gras (Faktor 1.0) und NICHT Wald (1.1): Gras
                        // ist exakt die Vor-Merge-Dämpfung (1 − 0.6·veg), d. h.
                        // auf dem Gerinne bleibt die alte Kalibrierung stehen.
                        // Nur Klasse 3 auszuschließen ließ dichte Bett-Zellen
                        // auf Wald fallen — bei v ≈ 1 immer noch Dämpfung 0.34
                        // statt 0.40, also eine Teil-Panzerung genau in den
                        // flachen Reaches, in denen Bänke entstehen.
                        if prip[k] >= 1 {
                            cls = 1
                        } else if prip[k] >= 0.4 && v >= 0.25 && phf[k] - ph[k] <= 0.02 && Terrain.macroSlope(ph, k, nn) * 40 < 0.6 {
                            cls = 3
                        } else if v > 0.45 {
                            cls = 2
                        } else {
                            cls = 1
                        }
                    }
                    pcls[k] = cls
                }
            }
            }
        }}}}}
    }

    /// Eine gedämpfte 3×3-Max-Dilatationsrunde: dst[k] = max(src[k],
    /// 0.65·max(8 Nachbarn)). Liest nur src, schreibt nur dst[k] →
    /// zeilenparallel bit-identisch.
    private func dilateDamped(from src: [Double], to dst: inout [Double]) {
        let nn = n
        src.withUnsafeBufferPointer { sb in
        dst.withUnsafeMutableBufferPointer { db in
            let ps = sb.baseAddress!, pd = db.baseAddress!
            parallel(nn) { jLo, jHi in
                for j in jLo..<jHi {
                    for i in 0..<nn {
                        let k = j * nn + i
                        var m = 0.0
                        if i > 0 && j > 0 { m = max(m, ps[k - nn - 1]) }
                        if j > 0 { m = max(m, ps[k - nn]) }
                        if i < nn - 1 && j > 0 { m = max(m, ps[k - nn + 1]) }
                        if i > 0 { m = max(m, ps[k - 1]) }
                        if i < nn - 1 { m = max(m, ps[k + 1]) }
                        if i > 0 && j < nn - 1 { m = max(m, ps[k + nn - 1]) }
                        if j < nn - 1 { m = max(m, ps[k + nn]) }
                        if i < nn - 1 && j < nn - 1 { m = max(m, ps[k + nn + 1]) }
                        pd[k] = max(ps[k], 0.65 * m)
                    }
                }
            }
        }}
    }

    // MARK: - Priority-Flood + Entwässerung (D8)

    /// Füllt Senken (Barnes et al.), bestimmt Abfluss-Nachbarn (steilster Abstieg
    /// auf der gefüllten Oberfläche) und akkumuliert das Einzugsgebiet.
    ///
    /// `dtYears` steuert NUR die Ratenbegrenzung des Becken-Wasserhaushalts
    /// (Issue #11); 0 = Zielstand sofort übernehmen (Generierung, Breach-Spin-up,
    /// Spieler-Eingriff via `SimNode.recomputeFlow`) — alles andere ist
    /// dt-unabhängig.
    public func computeFlow(includeMFD: Bool = true, dtYears: Double = 0) {
        mark("computeRain")
        computeRain()
        floodAndRoute(dt: dtYears)
        if includeMFD { mark("computeMFDArea"); computeMFDArea() }
    }

    /// Senkenfüllung + D8-Routing, dazwischen der Becken-Wasserhaushalt.
    /// Reihenfolge ist bewusst so und nicht anders:
    /// 1. `priorityFlood` liefert den VOLLSTAND (Sill-Niveau) jedes Beckens,
    /// 2. das erste `computeReceiversAndArea` den Abfluss auf diesem Vollstand —
    ///    das ist der ZUFLUSS, den ein Becken maximal bekommen kann (die
    ///    Bilanzgröße; sie ist bewusst unabhängig vom aktuellen Spiegel, sonst
    ///    hinge der Zufluss am eigenen Ergebnis),
    /// 3. `capEndorheicBasins` deckelt `hf` dort, wo die Verdunstung den
    ///    Vollstand nicht tragen kann,
    /// 4. und nur DANN — und nur wenn wirklich gedeckelt wurde — wird das Netz
    ///    auf dem gedeckelten Spiegel neu bestimmt (trockengefallener Boden
    ///    entwässert jetzt in den Restsee, die Seefläche ist terminal).
    /// `applyBalance: false` schaltet den Wasserhaushalt für diesen Aufruf aus
    /// (Becken-Rollen werden gelöscht) — das braucht der Breach-Spin-up, s. dort.
    private func floodAndRoute(dt: Double, applyBalance: Bool = true) {
        mark("priorityFlood")
        priorityFlood()
        // Becken-Rollen VOR der Zufluss-Messung löschen: mit den Rollen des
        // VORIGEN Schritts wären die Seeflächen schon terminal, die Akkumulation
        // käme an der Auslasszelle des Beckens nie an und der gemessene Zufluss
        // hinge an der eigenen Deckelung von gestern (Hysterese, die den Spiegel
        // Schritt für Schritt weiter absenken kann). Pass 1 ist deshalb immer die
        // vollständige, verdunstungs-freie Entwässerung.
        mark("clearEndorheicBasins")
        clearEndorheicBasins()
        mark("computeReceiversAndArea")
        computeReceiversAndArea()
        guard applyBalance else { return }
        mark("capEndorheicBasins")
        if capEndorheicBasins(dt: dt) {
            mark("computeReceiversAndArea")
            computeReceiversAndArea()
        }
    }

    /// Becken-Rollen (und damit alle #11-Sonderpfade) zurücksetzen.
    ///
    /// PERF (Issue #43): Suche und Löschen laufen auf Roh-Puffern. Als Schleife
    /// über die Klassen-Properties kostete der Pass 36 ms/Schritt (9 % des
    /// Schritts) — für drei Feld-Löschungen, die als `update(repeating:)` unter
    /// 1 ms bleiben; die Zeit steckte komplett in Bounds-/COW-/Exclusivity-
    /// Prüfungen je Zelle. Geschriebene WERTE unverändert.
    private func clearEndorheicBasins() {
        let cnt = cfg.count
        let any = endorheicBasin.withUnsafeBufferPointer { eb -> Bool in
            let p = eb.baseAddress!
            for k in 0..<cnt where p[k] != .none { return true }
            return false
        }
        guard any else { return }
        endorheicBasin.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: .none, count: cnt) }
        playaBed.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: false, count: cnt) }
        endorheicInflow.withUnsafeMutableBufferPointer { $0.baseAddress!.update(repeating: 0, count: cnt) }
    }

    /// PERF: der Hot-Loop läuft komplett auf Roh-Puffern (kein Bounds-/COW-Check
    /// je Zugriff), innere Zellen nehmen den Zweig mit 8 FESTEN Offsets ohne
    /// Rand-Checks, und der Spaltenindex reist im Heap-Eintrag mit (kein `c % n`
    /// je Zelle).
    private func priorityFlood() {
        heap.removeAll()
        let cnt = cfg.count, nn = n
        h.withUnsafeBufferPointer { hb in
        hf.withUnsafeMutableBufferPointer { hfb in
        visited.withUnsafeMutableBufferPointer { vb in
        floodParent.withUnsafeMutableBufferPointer { pb in
        order.withUnsafeMutableBufferPointer { ob in
        heap.withRaw { heap in
            let ph = hb.baseAddress!, phf = hfb.baseAddress!
            let pv = vb.baseAddress!, ppar = pb.baseAddress!, pord = ob.baseAddress!
            pv.update(repeating: false, count: cnt)
            // Ränder als Startpunkte (Meer/Weltrand = Basisniveau). Ohne das
            // Array-Literal je i — das war eine Allokation pro Randzelle.
            @inline(__always) func seed(_ b: Int, _ col: Int32) {
                if pv[b] { return }
                pv[b] = true
                phf[b] = ph[b]
                ppar[b] = -1
                heap.push(key: ph[b], cell: Int32(b), col: col)
            }
            for i in 0..<nn {
                seed(i, Int32(i))                      // Nordrand
                seed((nn - 1) * nn + i, Int32(i))      // Südrand
                seed(i * nn, 0)                        // Westrand
                seed(i * nn + nn - 1, Int32(nn - 1))   // Ostrand
            }
            let lastRow = cnt - nn
            var oi = 0
            while heap.size > 0 {
                let e = heap.pop()
                let c = Int(e.cell), col = Int(e.col)
                pord[oi] = e.cell; oi += 1
                // e.key == hf[c]: die Füllhöhe wird beim Push gesetzt und danach
                // nie mehr geändert → ein Random-Read gespart.
                let hc = e.key
                @inline(__always) func visit(_ nb: Int, _ ncol: Int32) {
                    if pv[nb] { return }
                    pv[nb] = true
                    let v = max(ph[nb], hc)
                    phf[nb] = v
                    ppar[nb] = e.cell
                    heap.push(key: v, cell: Int32(nb), col: ncol)
                }
                if col > 0 && col < nn - 1 && c >= nn && c < lastRow {
                    let cm = e.col
                    visit(c - nn - 1, cm - 1); visit(c - nn, cm); visit(c - nn + 1, cm + 1)
                    visit(c - 1, cm - 1); /* Zentrum */         visit(c + 1, cm + 1)
                    visit(c + nn - 1, cm - 1); visit(c + nn, cm); visit(c + nn + 1, cm + 1)
                } else {
                    let cj = c / nn
                    for dj in -1...1 {
                        for di in -1...1 {
                            if di == 0 && dj == 0 { continue }
                            let ni = col + di, nj = cj + dj
                            if ni < 0 || ni >= nn || nj < 0 || nj >= nn { continue }
                            visit(nj * nn + ni, Int32(ni))
                        }
                    }
                }
            }
        }}}}}}
    }

    /// Startwert der Flächen-Akkumulation je Zelle — die EINE Stelle für beide
    /// Netze (D8 in `computeReceiversAndArea`, MFD in `computeMFDArea`), damit sie
    /// nicht auseinanderdriften.
    ///
    /// Ohne `cfg.rainWeightedFlow`: reine Zellfläche (`cellArea` überall) —
    /// bit-identisch zum Zustand vor Issue #9. Mit Schalter: `cellArea ·
    /// flowWeight[k]`, d. h. die Akkumulation trägt ABFLUSS statt Fläche
    /// (Q = ∫P dA), auf das Landmittel normiert (s. `updateRainWeight`) —
    /// Σ über Land bleibt damit exakt `Landzellen · cellArea`.
    /// `flowWeight` ist beim Aufruf frisch (computeFlow ruft computeRain zuerst);
    /// nur der Breach-Spin-up (`breachBasins`) rechnet bewusst auf dem Regen des
    /// letzten `computeFlow` weiter — das Klima ändert sich über eine
    /// Breach-Runde nicht nennenswert.
    /// Seit Issue #36 trägt das Gewicht zusätzlich das SCHMELZWASSER, wenn es
    /// eines gibt (`runoffWeight`); die Regel ist für beide Netze und die
    /// Tropfen-Starts dieselbe — `flowWeight` ist die einzige Quelle.
    /// Per-Zelle unabhängig → parallel bit-identisch zur sequenziellen Schleife.
    private func seedFlowAccumulator(_ pa: UnsafeMutablePointer<Double>, cellArea: Double) {
        let cnt = cfg.count
        let weight = flowWeight
        guard weight.count == cnt else {
            pa.update(repeating: cellArea, count: cnt)
            return
        }
        weight.withUnsafeBufferPointer { rb in
            let pw = rb.baseAddress!
            parallel(cnt) { lo, hi in
                for k in lo..<hi { pa[k] = cellArea * pw[k] }
            }
        }
    }

    /// PERF wie im Flood: Roh-Puffer, i/j aus der Schleife statt `%`/`/` je Zelle,
    /// innere Zellen mit 8 festen Offsets ohne Rand-Checks. Vergleichsreihenfolge
    /// und `/ dist` bleiben unverändert (strict `>` → der erste steilste gewinnt).
    private func computeReceiversAndArea() {
        let cellArea = cfg.cellSize * cfg.cellSize
        let cnt = cfg.count, nn = n, sea = cfg.sea
        let sqrt2 = 2.0.squareRoot()
        hf.withUnsafeBufferPointer { hfb in
        receiver.withUnsafeMutableBufferPointer { rb in
        area.withUnsafeMutableBufferPointer { ab in
        floodParent.withUnsafeBufferPointer { pb in
        order.withUnsafeBufferPointer { ob in
        endorheicBasin.withUnsafeBufferPointer { eb in
            let phf = hfb.baseAddress!, prec = rb.baseAddress!, pa = ab.baseAddress!
            let ppar = pb.baseAddress!, pord = ob.baseAddress!, pend = eb.baseAddress!
            prec.update(repeating: -1, count: cnt)
            seedFlowAccumulator(pa, cellArea: cellArea)
            // Empfänger: steilster Abstieg auf hf; auf Seespiegel-Flächen Richtung Überlauf.
            // Jede Zelle schreibt nur prec[k] → zeilenparallel, bit-identisch.
            parallel(nn) { jLo, jHi in
            for j in jLo..<jHi {
                let row = j * nn
                let innerRow = j > 0 && j < nn - 1
                for i in 0..<nn {
                    let k = row + i
                    let hk = phf[k]
                    if hk <= sea { continue } // Meer = Senke
                    var best: Int32 = -1
                    var bestSlope = 0.0
                    // Division erst nach dem Vorzeichen-Test (Begründung s.
                    // `computeMFDArea`): `bestSlope` startet bei 0 und wächst nur,
                    // ein nicht-positives `s` konnte den Vergleich also nie gewinnen.
                    @inline(__always) func consider(_ nb: Int, _ dist: Double) {
                        let d = hk - phf[nb]
                        if d <= 0 { return }
                        let s = d / dist
                        if s > bestSlope { bestSlope = s; best = Int32(nb) }
                    }
                    if innerRow && i > 0 && i < nn - 1 {
                        consider(k - nn - 1, sqrt2); consider(k - nn, 1.0); consider(k - nn + 1, sqrt2)
                        consider(k - 1, 1.0); /* Zentrum */              consider(k + 1, 1.0)
                        consider(k + nn - 1, sqrt2); consider(k + nn, 1.0); consider(k + nn + 1, sqrt2)
                    } else {
                        for dj in -1...1 {
                            for di in -1...1 {
                                if di == 0 && dj == 0 { continue }
                                let ni = i + di, nj = j + dj
                                if ni < 0 || ni >= nn || nj < 0 || nj >= nn { continue }
                                consider(nj * nn + ni, (di != 0 && dj != 0) ? sqrt2 : 1.0)
                            }
                        }
                    }
                    // Abflussloses Becken (Issue #11): die Wasserfläche ist eine
                    // TERMINALE Senke — das Wasser verlässt sie über die
                    // Verdunstung, nicht über die Sill (deshalb auch dann −1,
                    // wenn die 8er-Nachbarschaft diagonal an einen tieferen
                    // Nachbarsee grenzt). Und im geschlossenen Becken gibt es für
                    // eine flache Bodenzelle keinen Überlauf: der
                    // floodParent-Fallback zeigt zur Sill HINAUS, also genau
                    // dorthin, wo kein Wasser mehr hinkommt.
                    if pend[k] != .none {
                        if pend[k] == .water || best < 0 { best = -1 }
                    } else if best < 0 {
                        best = ppar[k] // flacher Seespiegel → Überlauf
                    }
                    prec[k] = best
                }
            }
            }
            // Einzugsgebiet: von hoch nach tief (order rückwärts) an Empfänger weiterreichen.
            var oi = cnt - 1
            while oi >= 0 {
                let k = Int(pord[oi]); oi -= 1
                let r = prec[k]
                if r >= 0 { pa[Int(r)] += pa[k] }
            }
        }}}}}}
    }

    // MARK: - Wasserhaushalt abflussloser Becken (Verdunstung, Issue #11)

    /// Deckelt den Seespiegel eines geschlossenen Beckens auf den Stand, den sein
    /// **Wasserhaushalt** trägt — Zufluss gegen Verdunstung über der Seefläche —
    /// statt ihn (wie der reine Priority-Flood) immer bis zur Sill zu füllen.
    /// Damit gibt es endorheische Becken, Playas und Salzseen; ein Becken mit
    /// genug Zufluss verhält sich exakt wie vorher (Wächter:
    /// `testBasinsDrainToSea`, `testWellFedBasinIsUnchanged`).
    ///
    /// **Bilanz.** Ein Becken ist die Menge zusammenhängender Zellen (8er) mit
    /// `hf > h` und identischem `hf` — der Priority-Flood füllt eine Senke
    /// exakt flach auf ihr Sill-Niveau, deshalb ist die Gleichheit exakt und
    /// nicht approximativ. Für dieses Becken gilt
    ///
    ///     Zufluss A_zu = max(area) über die Beckenzellen
    ///     Bedarf  D(z) = κ · Σ_{h < z} cellArea · aridity(k)
    ///
    /// `A_zu` ist der Abfluss, den das Becken einsammelt: auf dem VOLLSTAND
    /// zeigen alle Beckenzellen über `floodParent` zur Sill, die Akkumulation
    /// läuft also durchs Becken und ist an seiner Auslasszelle maximal. Weil der
    /// Abfluss seit #10 niederschlagsgewichtet und auf das Regen-Landmittel
    /// normiert ist, ist κ das Verhältnis „Seeverdunstung / mittlere
    /// Abflusshöhe" = das nötige Einzugsgebiet-zu-Seefläche-Verhältnis
    /// (Herleitung und Kalibrier-Logbuch: `SimConfig.endorheicEvapRatio`).
    /// Der Regen, der auf den See selbst fällt, steckt schon in `A_zu` — der
    /// Bedarf ist deshalb die BRUTTO-Verdunstung, nicht „Verdunstung − Regen".
    ///
    /// `D(z)` ist eine TREPPENFUNKTION der Seefläche (die Verdunstung hängt an
    /// der Fläche, nicht an der Tiefe) und wächst monoton mit z → der
    /// Gleichgewichtsstand ist der höchste Stand mit `D ≤ A_zu`, und den findet
    /// man exakt, indem man die Beckenzellen nach Höhe sortiert und den Bedarf
    /// aufsummiert. `D(Sill) ≤ A_zu` heißt „Becken trägt den Vollstand" → gar
    /// kein Eingriff (der schnelle Normalfall; nur dann wird sortiert, wenn
    /// wirklich gedeckelt wird).
    ///
    /// **Ratenbegrenzung.** Übernommen wird nicht der Zielstand, sondern ein
    /// exponentieller Schritt dorthin (`endorheicResponseYears`, dt-invariant wie
    /// `relaxWaterLevel`) — ein See füllt und leert sich mit endlicher Rate, und
    /// der Zielstand SPRINGT, wenn Deposition am Auslass die Sill hebt (dann
    /// gehört plötzlich mehr Fläche zum Becken). Gedächtnis ist `lakeBalance` an
    /// der TIEFSTEN Beckenzelle: sie ist die einzige, die in jedem Stand zum
    /// Becken gehört (und bleibt es auch, wenn das Becken vollständig
    /// trockenfällt — der Priority-Flood füllt es im nächsten Schritt wieder,
    /// die Becken-ERKENNUNG hängt also nicht am Wasserstand).
    ///
    /// **Determinismus:** rein sequenziell, Becken-Reihenfolge = aufsteigender
    /// Zellindex, Sortierung nach (h, Index) → bit-identisch reproduzierbar.
    ///
    /// Rückgabe: `true`, wenn mindestens ein Becken verdunstungs-limitiert ist —
    /// dann muss das D8-Netz auf dem gedeckelten Spiegel neu bestimmt werden.
    private func capEndorheicBasins(dt: Double) -> Bool {
        guard cfg.endorheicEvaporation, cfg.endorheicEvapRatio > 0 else {
            if endorheicBasin.contains(where: { $0 != .none }) {
                for k in 0..<cfg.count { endorheicBasin[k] = .none }
            }
            return false
        }
        let cnt = cfg.count, nn = n, sea = cfg.sea
        let cellArea = cfg.cellSize * cfg.cellSize
        let kappa = cfg.endorheicEvapRatio
        let aridA = cfg.endorheicAridity
        let weighted = rainWeight.count == cnt
        let minBasin = cfg.endorheicMinBasinCells
        let saltMinDepth = cfg.endorheicSaltMinDepth
        // Ratenbegrenzung; dt = 0 (Generierung/Breach/Spieler-Eingriff) snappt.
        let lam = (dt > 0 && cfg.endorheicResponseYears > 0)
            ? Terrain.relaxFraction(dt: dt, tau: cfg.endorheicResponseYears) : 1.0
        // PERF (Issue #43): der Pass war mit 62 ms/Schritt (16 %) der teuerste
        // überhaupt — nicht wegen seiner Arithmetik, sondern weil Initial-Löschung,
        // Becken-Suchlauf und Flutfüllung über KLASSEN-Properties liefen (je
        // Zugriff Bounds-, COW- und Exclusivity-Prüfung). Deshalb hier: alle
        // Felder als Roh-Puffer, die Scratch-Arrays als LOKALE Variablen (aus der
        // Klasse herausgenommen und am Ende zurückgegeben — so bleibt die
        // Kapazität über Schritte erhalten, ohne dass der Hot-Loop auf eine
        // Klassen-Property zugreift), und `k / nn` einmal statt `%` + `/`.
        // Werte, Reihenfolge und Vergleiche sind unverändert.
        var cells = basinCells; basinCells = []
        var slots = basinSlots; basinSlots = []
        defer { basinCells = cells; basinSlots = slots }
        // Ohne Gewichtsfeld ein 1-Element-Dummy (nie indiziert, s. `demand`).
        let rw = weighted ? rainWeight : [1.0]
        var capped = false
        var orderPosBuilt = false
        hf.withUnsafeMutableBufferPointer { hfb in
        h.withUnsafeBufferPointer { hb in
        area.withUnsafeBufferPointer { ab in
        rw.withUnsafeBufferPointer { rwb in
        basinSeen.withUnsafeMutableBufferPointer { bsb in
        endorheicBasin.withUnsafeMutableBufferPointer { ebb in
        playaBed.withUnsafeMutableBufferPointer { pbb in
        endorheicInflow.withUnsafeMutableBufferPointer { eib in
        lakeBalance.withUnsafeMutableBufferPointer { lbb in
            let phf = hfb.baseAddress!, ph = hb.baseAddress!, pa = ab.baseAddress!
            let prw = rwb.baseAddress!, pseen = bsb.baseAddress!
            let pend = ebb.baseAddress!, pplaya = pbb.baseAddress!
            let pinflow = eib.baseAddress!, plake = lbb.baseAddress!
            /// Verdunstungs-Bedarf einer Zelle (Fläche × Klima-Faktor). Ohne
            /// Gewichtsfeld (`rainWeightedFlow` aus) ist er klima-neutral — dann
            /// bilanziert der Pass rein geometrisch.
            @inline(__always) func demand(_ k: Int) -> Double {
                guard weighted, aridA != 0 else { return cellArea * kappa }
                let a = min(4.0, max(0.25, 1 + aridA * (1 - prw[k])))
                return cellArea * kappa * a
            }
            pseen.update(repeating: false, count: cnt)
            pend.update(repeating: .none, count: cnt)
            pplaya.update(repeating: false, count: cnt)
            pinflow.update(repeating: 0, count: cnt)
            for s in 0..<cnt where !pseen[s] && phf[s] > sea && phf[s] > ph[s] {
                let sill = phf[s] // Priority-Flood füllt die Senke flach auf ihr Sill-Niveau
                cells.removeAll(keepingCapacity: true)
                cells.append(Int32(s))
                pseen[s] = true
                var inflow = 0.0, full = 0.0
                var qi = 0
                while qi < cells.count {
                    let k = Int(cells[qi]); qi += 1
                    inflow = max(inflow, pa[k])
                    full += demand(k)
                    let j = k / nn, i = k - j * nn
                    for dj in -1...1 {
                        for di in -1...1 {
                            if di == 0 && dj == 0 { continue }
                            let ni = i + di, nj = j + dj
                            if ni < 0 || ni >= nn || nj < 0 || nj >= nn { continue }
                            let nb = nj * nn + ni
                            if pseen[nb] || phf[nb] != sill || phf[nb] <= ph[nb] { continue }
                            pseen[nb] = true
                            cells.append(Int32(nb))
                        }
                    }
                }
                // Vollstand getragen (oder Becken unter dem Rausch-Gate) → gar kein
                // Eingriff. Der Bilanz-Stand wird trotzdem mitgeführt, damit ein
                // später kippendes Becken beim Deckeln von der SILL aus absinkt und
                // nicht von einem veralteten Wert (das wäre ein Sprung nach unten).
                if full <= inflow || cells.count < minBasin {
                    for kk in cells { plake[Int(kk)] = sill }
                    continue
                }
                // Zielstand: höchster Stand, dessen Seefläche die Verdunstung noch
                // aus dem Zufluss deckt. Sortierung nach (h, Index) ist gleichzeitig
                // die Sortierung nach dem NEUEN hf (= max(h, level), monoton in h) —
                // die braucht das Umsortieren von `order` unten.
                cells.sort { (ph[Int($0)], $0) < (ph[Int($1)], $1) }
                var spent = 0.0, wet = 0
                for kk in cells {
                    let d = demand(Int(kk))
                    if spent + d > inflow { break }
                    spent += d; wet += 1
                }
                let target = wet >= cells.count ? sill : ph[Int(cells[wet])]
                let anchor = Int(cells[0]) // tiefste Zelle = Gedächtnis des Beckens
                var prev = plake[anchor]
                if !prev.isFinite { prev = sill }
                prev = min(max(prev, ph[anchor]), sill)
                let level = prev + (target - prev) * lam
                for kk in cells {
                    let k = Int(kk)
                    plake[k] = level
                    pinflow[k] = inflow
                    if level > ph[k] {
                        phf[k] = level
                        pend[k] = .water
                    } else {
                        phf[k] = ph[k]
                        pend[k] = .dryBed
                        // Salzpfanne nur, wo auch substanziell Wasser stand.
                        pplaya[k] = sill - ph[k] > saltMinDepth
                    }
                }
                capped = true
                // `order` (aufsteigende Füllhöhe) muss der gesenkte Spiegel mitziehen:
                // die Akkumulation läuft rückwärts durch `order` und setzt voraus,
                // dass der Empfänger jeder Zelle FRÜHER darin steht. Innerhalb des
                // Beckens stimmt das nach dem Deckeln nicht mehr (alle Zellen lagen
                // auf dem gemeinsamen Sill-Niveau, jetzt liegt der trockene Boden
                // ÜBER dem Restsee). Repariert wird nur lokal: die Plätze des Beckens
                // in `order` bleiben dieselben, die Zellen ziehen darin nach dem
                // neuen hf aufsteigend um. Global bleibt `order` damit nach hf
                // sortiert — außerhalb des Beckens hat sich kein hf geändert, und
                // eine fremde Zelle mit demselben hf kann nie Empfänger einer
                // Beckenzelle sein, die jetzt HÖHER liegt (Empfänger gehen bergab).
                order.withUnsafeMutableBufferPointer { ob in
                orderPos.withUnsafeMutableBufferPointer { opb in
                    let pord = ob.baseAddress!, ppos = opb.baseAddress!
                    if !orderPosBuilt {
                        parallel(cnt) { lo, hi in
                            for t in lo..<hi { ppos[Int(pord[t])] = Int32(t) }
                        }
                        orderPosBuilt = true
                    }
                    slots.removeAll(keepingCapacity: true)
                    for kk in cells { slots.append(ppos[Int(kk)]) }
                    slots.sort()
                    for t in slots.indices {
                        let slot = Int(slots[t]), c = cells[t]
                        pord[slot] = c
                        ppos[Int(c)] = Int32(slot)
                    }
                }}
            }
        }}}}}}}}}
        return capped
    }

    /// Salzkruste auf trockengefallenem Beckenboden aufbauen bzw. unter Wasser
    /// wieder abbauen (EWMA in Sim-Zeit → dt-invariant, Zeitraffer und
    /// +10.000-Jahre-Sprung landen bei derselben Kruste). Reines Render-/
    /// Vegetations-Signal, keine Erosionsphysik (s. `saltCrust`).
    private func updateSaltCrust(dt: Double) {
        guard cfg.endorheicSaltYears > 0 else { return }
        let lam = Terrain.relaxFraction(dt: dt, tau: cfg.endorheicSaltYears)
        saltCrust.withUnsafeMutableBufferPointer { sb in
        playaBed.withUnsafeBufferPointer { pb in
            let ps = sb.baseAddress!, pp = pb.baseAddress!
            parallel(cfg.count) { lo, hi in
                for k in lo..<hi {
                    let target: Double = pp[k] ? 1 : 0
                    ps[k] += (target - ps[k]) * lam
                }
            }
        }}
    }

    // MARK: - Multi-Flow-Einzugsgebiet (Freeman/Holmgren) — nur Render/Braiding

    /// Verteilt den Abfluss STETIG an ALLE tieferen Nachbarn (Freeman-1991-
    /// Gewichte fᵢ = Sᵢᵖ/ΣSⱼᵖ, p = `cfg.mfdExponent`) statt komplett an den
    /// steilsten wie D8. Ergebnis in `areaMFD`, ausschließlich fürs Rendering und
    /// (später) Braiding — die Erosion nutzt weiter `area` (Single-Flow), damit der
    /// kalibrierte Terrain-Look und die implizite Stabilität unangetastet bleiben.
    ///
    /// Zwei Wirkungen: (1) an einer Mittelbank (lokaler Hoch) bekommen BEIDE
    /// Flanken S>0 → `areaMFD` bleibt links UND rechts hoch → der Lauf teilt sich
    /// und vereint sich unten wieder (mit D8-argmax prinzipiell unmöglich). (2) Die
    /// Gewichte sind stetig in der Topografie → der Lauf gleitet bei kleinen
    /// Änderungen, statt schlagartig auf einen anderen Nachbarn zu kippen (die
    /// gemessene ~27%-Churn je Flow-Update = das „Springen").
    ///
    /// `order` (aufsteigende Füllhöhe) ist auch für MFD ein gültiger topologischer
    /// Order: jeder Ziel-Nachbar liegt tiefer in `hf` → beim Verarbeiten von hoch
    /// nach tief ist `areaMFD[k]` vollständig eingesammelt, bevor es verteilt wird.
    /// Lokale Exponenten-Wahl für die MFD-Verteilung (Quinn 1995: abfluss-
    /// abhängig) — die EINE Stelle für Wasser (computeMFDArea), Sediment
    /// (braidPass) und die Test-Metriken, damit die Fracht exakt dem Wasser
    /// folgt und die Gates nicht auseinanderdriften. Dispersiv (braidDispersion)
    /// nur auf GROSSEN, FLACHEN, SUBAERISCHEN Läufen (= Braid-Plains): Hänge
    /// behalten die Konvergenz (mfdExponent, dendritischer Look), geflutete
    /// Becken-Böden ebenso (Dispersion dort = Sheet-Flow-Konfetti im Render).
    @inline(__always) func mfdLocalExponent(_ k: Int, sMax: Double) -> Double {
        mfdLocalExponent(a: areaMFD[k], sMax: sMax, pond: hf[k] - h[k])
    }
    /// Wert-Variante für die Hot-Loops (die dort auf Roh-Puffern arbeiten und
    /// `self.areaMFD` nicht gleichzeitig lesen dürfen) — EINE Regel, zwei Aufrufer.
    @inline(__always) func mfdLocalExponent(a: Double, sMax: Double, pond: Double) -> Double {
        (a >= mfdMinA && mfdCanDisperse(sMax: sMax, pond: pond))
            ? cfg.braidDispersion : cfg.mfdExponent
    }
    @inline(__always) private func mfdCanDisperse(sMax: Double, pond: Double) -> Bool {
        sMax < mfdFlatCell && pond < 0.005
    }
    // Schwellen einmal je Terrain (waren `lazy var`: das kostet im 700k-Loop je
    // Zugriff eine Initialisierungs-Prüfung auf einer Klassen-Property).
    private let mfdMinA: Double
    private let mfdFlatCell: Double // Weltslope in Zell-Einheiten

    /// Nachbargewichte hängen nur an der unveränderten Topografie. Zwei
    /// Exponenten vorbereiten; die Flächen-Schwelle entscheidet erst während
    /// der weiterhin seriellen Akkumulation in unveränderter `order`.
    ///
    /// PERF (Runde 7): die Route reiste als 256-Byte-Struct (zwei komplette
    /// `SIMD8<Double>`-Gewichtssätze plus Zähler) durch Schreibe- und
    /// Leseschleife — rund 133 MB Schreib- UND Leseverkehr je Schritt allein
    /// für den Zwischenspeicher, obwohl die Mehrheit der Zellen Meer ist und
    /// gar keine Route braucht. Jetzt trägt der Struct nur den dendritischen
    /// Satz (Nachbarn + Gewichte + Summe, 104 Byte) und wird NUR für Land-
    /// zellen mit mindestens einem tieferen Nachbarn geschrieben; der seltene
    /// disbursive Satz liegt in `mfdDispersed` und wird nur für canDisperse-
    /// Zellen geschrieben. Die Klassifikation (Wasser/Becken −1 · flach 0 ·
    /// Land mit c Nachbarn: c, bzw. c+10 mit Dispersionsflag) reist als Int8
    /// in `mfdRouteCounts` — für Meerzellen bleibt vom Zwischenspeicher damit
    /// exakt 1 Byte. Werte, Additionsketten und Vergleichsreihenfolge
    /// unverändert, s. Kommentare im Pass.
    private struct MFDRoute {
        var neighbors = SIMD8<Int32>(repeating: 0)
        var weights = SIMD8<Double>(repeating: 0)
        var sum = 0.0
    }

    /// Disbursive Gewichte (Exponent `braidDispersion`) — getrennt von
    /// `MFDRoute`, weil sie nur für die seltene canDisperse-Minderheit
    /// gebraucht und geschrieben werden.
    private struct MFDDispersion {
        var weights = SIMD8<Double>(repeating: 0)
        var sum = 0.0
    }

    private func computeMFDArea() {
        let cellArea = cfg.cellSize * cfg.cellSize
        let cnt = cfg.count, nn = n, sea = cfg.sea
        let sqrt2 = 2.0.squareRoot()
        let exponent = cfg.mfdExponent, dispersion = cfg.braidDispersion
        if mfdRoutes.count != cnt { mfdRoutes = .init(repeating: MFDRoute(), count: cnt) }
        if mfdRouteCounts.count != cnt { mfdRouteCounts = .init(repeating: 0, count: cnt) }
        if mfdDispersed.count != cnt { mfdDispersed = .init(repeating: MFDDispersion(), count: cnt) }
        hf.withUnsafeBufferPointer { hfb in
        h.withUnsafeBufferPointer { hb in
        areaMFD.withUnsafeMutableBufferPointer { ab in
        floodParent.withUnsafeBufferPointer { pb in
        order.withUnsafeBufferPointer { ob in
        endorheicBasin.withUnsafeBufferPointer { eb in
        let capacity = cnt
        mfdRoutes.withUnsafeMutableBufferPointer { routes in
        mfdRouteCounts.withUnsafeMutableBufferPointer { rcb in
        mfdDispersed.withUnsafeMutableBufferPointer { dsp in
            let phf = hfb.baseAddress!, ph = hb.baseAddress!, pa = ab.baseAddress!
            let ppar = pb.baseAddress!, pord = ob.baseAddress!, pend = eb.baseAddress!
            let pr = routes.baseAddress!, prc = rcb.baseAddress!, pdsp = dsp.baseAddress!
            seedFlowAccumulator(pa, cellArea: cellArea)
            let fastMod = UInt64.max / UInt64(nn) &+ 1
            let lastRow = cnt - nn
            var end = cnt
            while end > 0 {
                let length = min(capacity, end)
                let blockEnd = end
                parallel(length) { lo, hi in
                for t in lo..<hi {
                    let k = Int(pord[blockEnd - 1 - t])
                    let hk = phf[k]
                    if hk <= sea || pend[k] == .water {
                        prc[t] = -1
                        continue
                    }
                    var neighbors = SIMD8<Int32>(repeating: 0)
                    var slopes = SIMD8<Double>(repeating: 0)
                    var c = 0
                    var sMax = 0.0
                    // PERF: die Division erst NACH dem Vorzeichen-Test. `dist` ist
                    // positiv, `s` hat also dasselbe Vorzeichen wie der Zähler —
                    // höhere Nachbarn (die Mehrzahl) kosten damit keine
                    // Fließkomma-Division mehr, und die ist auf dieser Schleife der
                    // Taktgeber (gemessen −0,6 ms/Schritt). Der `s > 0`-Test bleibt
                    // stehen: er fängt den (theoretischen) Unterlauf eines winzigen
                    // positiven Zählers ab ⇒ bit-identisch.
                    @inline(__always) func consider(_ nb: Int, _ dist: Double) {
                        let d = hk - phf[nb]
                        if d <= 0 { return }
                        let s = d / dist
                        if s > 0 { neighbors[c] = Int32(nb); slopes[c] = s; sMax = max(sMax, s); c += 1 }
                    }
                    let i = Int((fastMod &* UInt64(k)).multipliedFullWidth(by: UInt64(nn)).high)
                    if i > 0 && i < nn - 1 && k >= nn && k < lastRow {
                        consider(k - nn - 1, sqrt2); consider(k - nn, 1.0); consider(k - nn + 1, sqrt2)
                        consider(k - 1, 1.0); /* Zentrum */              consider(k + 1, 1.0)
                        consider(k + nn - 1, sqrt2); consider(k + nn, 1.0); consider(k + nn + 1, sqrt2)
                    } else {
                        let j = k / nn
                        for dj in -1...1 {
                            for di in -1...1 {
                                if di == 0 && dj == 0 { continue }
                                let ni = i + di, nj = j + dj
                                if ni < 0 || ni >= nn || nj < 0 || nj >= nn { continue }
                                consider(nj * nn + ni, (di != 0 && dj != 0) ? sqrt2 : 1.0)
                            }
                        }
                    }
                    if c == 0 {
                        // Flache Zelle (Seespiegel/Grat): kein tieferer Nachbar.
                        // Die Route bleibt ungeschrieben, die Akkumulation fällt
                        // unten auf den floodParent-Rückfall (identisch zum
                        // bisherigen `route.count == 0`).
                        prc[t] = 0
                        continue
                    }
                    var route = MFDRoute()
                    for j in 0..<c {
                        route.weights[j] = powFast(slopes[j], exponent)
                        route.sum += route.weights[j]
                    }
                    // Jede Division behält dieselben Operanden. Die
                    // anschließenden Flächensummen bleiben vollständig seriell.
                    // Die Additionskette je Akkumulator ist unverändert
                    // aufsteigend in j — die beiden Akkumulatoren laufen jetzt
                    // nur in getrennten Schleifen, was die Werte nicht ändert.
                    for j in 0..<c {
                        route.weights[j] /= route.sum
                    }
                    route.neighbors = neighbors
                    pr[t] = route
                    if mfdCanDisperse(sMax: sMax, pond: hk - ph[k]) {
                        // Dispersions-Flag im Int8-Zähler: c + 10 (c ≤ 8, der
                        // Wert bleibt Int8-safe). Ohne Flag wird der disbursive
                        // Satz gar nicht erst geschrieben.
                        prc[t] = Int8(c + 10)
                        var disp = MFDDispersion()
                        for j in 0..<c {
                            disp.weights[j] = powFast(slopes[j], dispersion)
                            disp.sum += disp.weights[j]
                        }
                        for j in 0..<c {
                            disp.weights[j] /= disp.sum
                        }
                        pdsp[t] = disp
                    } else {
                        prc[t] = Int8(c)
                    }
                }
                }
                for t in 0..<length {
                    let c8 = prc[t]
                    if c8 < 0 { continue }
                    let k = Int(pord[blockEnd - 1 - t])
                    let a = pa[k]
                    let canD = c8 >= 10
                    let c = canD ? Int(c8) - 10 : Int(c8)
                    if c == 0 {
                        if pend[k] != .none { continue }
                        let fp = ppar[k]
                        if fp >= 0 { pa[Int(fp)] += a }
                        continue
                    }
                    let route = pr[t]
                    // Die Flächen-Schwelle entscheidet wie bisher erst hier, an
                    // der bereits angesammelten Fläche.
                    let disperse = a >= mfdMinA && canD
                    let weights = disperse ? pdsp[t].weights : route.weights
                    let sum = disperse ? pdsp[t].sum : route.sum
                    if sum <= 0 {
                        if pend[k] != .none { continue }
                        let fp = ppar[k]
                        if fp >= 0 { pa[Int(fp)] += a }
                        continue
                    }
                    for j in 0..<c {
                        pa[Int(route.neighbors[j])] += a * weights[j]
                    }
                }
                end -= length
            }
        }}}}}}}}}
    }

    // MARK: - Braiding (zellulärer Bänke-Bau, Murray & Paola 1994)

    /// Baut Mittelbänke und Fäden auf den großen Läufen — die Verflechtung
    /// (braiding). Minimal-Rezept nach Murray & Paola (Nature 371): (a) Wasser,
    /// das sich lateral aufteilen kann (unser MFD-Feld), plus (b) Bedload-Transport
    /// mit SUPER-LINEARER Kapazität qcᵢ = Kb·(fᵢ·Q·Sᵢ)^m, m≈2.5. Wegen m>1
    /// transportiert der stärkere Faden überproportional viel → er scourt sich ein
    /// und fängt beim nächsten computeFlow noch mehr Wasser (positive Rückkopplung),
    /// während unterversorgte Zellen ihre Fracht ABLAGERN → Bänke wachsen bis knapp
    /// über den Wasserspiegel (braidBarHeight) → der Lauf teilt sich sichtbar und
    /// vereint sich stromab wieder. Fracht wird ∝ Kapazität an die MFD-Empfänger
    /// weitergereicht (Sediment folgt dem starken Faden).
    ///
    /// Reach-gated: nur Zellen mit areaMFD ≥ braidMinCells (substanzielle Flüsse);
    /// Vegetation dämpft den Scour wie überall ((1−0.6·veg), kohäsive Ufer
    /// verflechten real nicht). Kapazität UND Fracht skalieren mit dt → das
    /// Regime ist framerate-/chunking-unabhängig. Massenbilanz: bewegt wird nur,
    /// was der Pass selbst scourt; Deckel wie in transportLimited (nicht unter den
    /// tiefsten Empfänger graben, nicht über Seespiegel+barHeight schütten).
    /// Der explizite laterale Sediment-Term aus M&P entfällt bewusst: die radiale
    /// MFD-Verteilung (bis 8 tiefere Nachbarn) übernimmt die Quer-Streuung —
    /// Bänke entstehen nachweislich (testBraidingBuildsBars).
    private func braidPass(dt: Double) {
        let cellArea = cfg.cellSize * cfg.cellSize
        // cellSize 0 (keine definierte Schrittweite): keine Kapazität ohne Zellfläche,
        // sonst Division durch 0 und NaN-Vergiftung im Frachtpuffer qs.
        guard cellArea > 0, cellArea.isFinite else { return }
        let minA = cfg.braidMinCells * cellArea
        let mB = cfg.braidExponent
        let kb = cfg.braidCapacity * dt
        let sqrt2 = 2.0.squareRoot()
        let sea = cfg.sea, nn = n, cnt = cfg.count
        let barHeight = cfg.braidBarHeight, deltaCeiling = cfg.braidDeltaCeiling
        fill(&qs, 0)
        // PERF (Runde 7): Der Pass läuft über ALLE Zellen (der Reihe nach durch
        // `order`), auch wenn nur wenige ein Braid-Reach sind — der active-Test
        // zahlte seine vier verstreuten Lesezugriffe (areaMFD/hf/h ×2) 518k-fach
        // je Schritt. Er lässt sich VORAB und PARALLEL entscheiden, weil seine
        // Operanden bei der Zelle `k` bis zu k's eigenem Besuch unverändert
        // bleiben: `hf` und `areaMFD` schreibt der Pass gar nicht, und `h[k]`
        // ändert sich ausschließlich im Funnel von k's EIGENem Besuch
        // (`erodeCell`/`depositCell` schreiben nur die Zelle `k` selbst, s.
        // Bed-Funnel) — die serialisierten Besuche laufen also auf exakt den
        // Pass-Startwerten. Bit-identisch: der Test selbst, seine
        // Operanden und die Reihenfolge der Zweige sind unverändert.
        if braidStatus.count != cnt { braidStatus = .init(repeating: 0, count: cnt) }
        hf.withUnsafeBufferPointer { hfb in
        areaMFD.withUnsafeBufferPointer { amb in
        h.withUnsafeBufferPointer { hb in
        braidStatus.withUnsafeMutableBufferPointer { stb in
            let phf = hfb.baseAddress!, pamf = amb.baseAddress!, ph0 = hb.baseAddress!
            let pst = stb.baseAddress!
            parallel(cnt) { lo, hi in
                for k in lo..<hi {
                    if phf[k] <= sea {
                        pst[k] = 0
                        continue
                    }
                    // Seicht überströmte Reaches (< 0.015) sind aktiv — dort
                    // schütten Braid-Deltas Bänke bis über den Wasserspiegel.
                    // Tiefere Ponds/Seen NICHT: Bänke-Bau dort macht die
                    // Becken-Böden rau um die See-Render-Schwelle (0.03) herum
                    // → sichtbares Speckle statt Verflechtung.
                    let active = pamf[k] >= minA && ph0[k] > sea
                              && phf[k] - ph0[k] < 0.015
                    pst[k] = active ? 2 : 1
                }
            }
        }}}}
        // PERF (Issue #43): die Nachbar-Puffer des aktiven Zweigs als temporäre
        // Roh-Allokation, `h`/`sed`/`rock` über `withBed`: dieselbe Roh-Puffer-
        // Sicht, die auch der Funnel `erodeCell`/`depositCell` bekommt (er
        // trägt das Gletscher-Gate, AGENTS.md).
        order.withUnsafeBufferPointer { ob in
        qs.withUnsafeMutableBufferPointer { qb in
        areaMFD.withUnsafeBufferPointer { amb in
        hf.withUnsafeBufferPointer { hfb in
        floodParent.withUnsafeBufferPointer { fpb in
        braidStatus.withUnsafeBufferPointer { stb in
        withUnsafeTemporaryAllocation(of: Int.self, capacity: 8) { nbK in
        withUnsafeTemporaryAllocation(of: Double.self, capacity: 8) { nbW in
        withUnsafeTemporaryAllocation(of: Double.self, capacity: 8) { nbS in
        withUnsafeTemporaryAllocation(of: Double.self, capacity: 8) { nbQc in
        let pord = ob.baseAddress!, pqs = qb.baseAddress!, pamf = amb.baseAddress!
        let phf = hfb.baseAddress!, pfp = fpb.baseAddress!
        let pst = stb.baseAddress!
        withBed { bed in
        var oi = cfg.count - 1
        while oi >= 0 {
            let k = Int(pord[oi]); oi -= 1
            let st = pst[k]
            if st == 0 { continue }
            let qin = pqs[k]
            if st == 1 {
                // Kein Braid-Reach: Fracht landet hier ab (Delta/Seerand), Überschuss
                // über den Stauraum hinaus gilt als exportiert (wie transportLimited).
                //
                // Depositions-Deckel als GEOMETRISCHE OBERGRENZE über dem
                // Wasserspiegel statt als Zugabe JE SCHRITT (Issue #2). Vorher
                // stand hier `max(0, hf−h) + 0.005` — das `max` INNEN, der
                // Aufschlag also über dem aktuellen h statt über dem Spiegel:
                // sobald die Schüttung den Spiegel erreicht hatte, durfte jeder
                // weitere Schritt nochmal 0.005 draufsetzen, der Uferaufbau
                // wuchs mit der SCHRITTZAHL statt mit der Zeit. Als Obergrenze
                // `hf + braidDeltaCeiling` addiert er sich nicht mehr auf:
                // viele kleine Schritte laufen gegen dieselbe Kante wie ein
                // großer. Warum die Höhe 0.05 und nicht `braidBarHeight` ist —
                // und was bei zu engem Deckel kippt — steht im Kalibrier-Logbuch
                // bei `SimConfig.braidDeltaCeiling`.
                if qin > 0 {
                    let ceil = max(0, phf[k] + deltaCeiling - bed.h[k])
                    depositCell(k, min(qin, ceil), bed)
                }
                continue
            }
            // MFD-Empfänger, Gewichte und Gefälle (identisch zu computeMFDArea,
            // inkl. abfluss-abhängigem Exponent — die Fracht folgt dem Wasser).
            let j = k / nn, i = k - j * nn
            var cnt = 0
            var sMax = 0.0
            @inline(__always) func consider(_ nb: Int, _ dist: Double) {
                let d = phf[k] - phf[nb]
                if d <= 0 { return }
                let s = d / dist
                if s > 0 {
                    nbK[cnt] = nb; nbS[cnt] = s; sMax = max(sMax, s)
                    cnt += 1
                }
            }
            if i > 0 && i < nn - 1 && j > 0 && j < nn - 1 {
                consider(k - nn - 1, sqrt2); consider(k - nn, 1.0); consider(k - nn + 1, sqrt2)
                consider(k - 1, 1.0);                               consider(k + 1, 1.0)
                consider(k + nn - 1, sqrt2); consider(k + nn, 1.0); consider(k + nn + 1, sqrt2)
            } else {
                for dj in -1...1 {
                    for di in -1...1 {
                        if di == 0 && dj == 0 { continue }
                        let ni = i + di, nj = j + dj
                        if ni < 0 || ni >= nn || nj < 0 || nj >= nn { continue }
                        let nb = nj * nn + ni
                        consider(nb, (di != 0 && dj != 0) ? sqrt2 : 1.0)
                    }
                }
            }
            let p = mfdLocalExponent(a: pamf[k], sMax: sMax, pond: phf[k] - bed.h[k])
            var wsum = 0.0
            for t in 0..<cnt { nbW[t] = powFast(nbS[t], p); wsum += nbW[t] }
            if cnt == 0 || wsum <= 0 {
                // Seespiegel-Fläche: Fracht sedimentiert im See (bis Spiegel), Rest
                // wandert über den Überlauf weiter.
                let dep = min(qin, max(0, phf[k] - bed.h[k]))
                depositCell(k, dep, bed)
                let fp = pfp[k]
                if fp >= 0 { pqs[Int(fp)] += qin - dep }
                continue
            }
            // Kapazität je Route: qcᵢ = Kb·dt · Q·Sᵢ · fᵢ^m  (Q in Zell-Einheiten).
            // Die Super-Linearität liegt bewusst auf der lateralen PARTITION fᵢ
            // (nicht auf dem absoluten Q, das über das Netz 3 Dekaden spannt): für
            // festes Q trägt EIN Faden (f=1) mehr als zwei halbe (2·0.5^m ≈ 0.35) —
            // die Konzentrations-Instabilität, die Fäden schärft. Und wo der Lauf
            // sich aufspreizt (viele kleine fᵢ → Σfᵢ^m ≪ 1) KOLLABIERT die
            // Kapazität → Deposition genau in den breiten, flachen Reaches → Bänke.
            let q = pamf[k] / cellArea
            var qcTot = 0.0
            for t in 0..<cnt {
                nbQc[t] = kb * q * nbS[t] * pow(nbW[t] / wsum, mB)
                qcTot += nbQc[t]
            }
            var qout = qin
            if qin > qcTot {
                // Überlast → Bank bauen: bis knapp über den Wasserspiegel (Insel!).
                let dep = min(qin - qcTot, max(0, phf[k] + barHeight - bed.h[k]))
                depositCell(k, dep, bed)
                qout -= dep
            } else {
                // Unterlast → Faden scourt (Vegetation bremst, nie unter den
                // tiefsten Empfänger — halber Weg wie transportLimited).
                var lowest = bed.h[k]
                for t in 0..<cnt { lowest = min(lowest, bed.h[nbK[t]]) }
                // Der SCOUR-Deckel bleibt bewusst bei festen 0.5 je Schritt und
                // wird NICHT auf `stepCapFraction` umgestellt (Issue #2 nennt
                // die DEPOSITIONS-Deckel; dies ist die Erosionsseite): mit der
                // Rate darf ein 200-Jahr-Schritt 0.75 statt 0.5 der lokalen
                // Differenz ausräumen, und der Braid-Scour gräbt damit den
                // Boden der abflusslosen Becken tiefer — gemessen fiel die
                // trockengefallene, verkrustete Playa-Fläche von >100 auf 35
                // Zellen und die #11-Wächter `testDriedBedIsRenderedAsPlaya`
                // und `testBasinLevelIsRateLimited` kippten. Damit bleibt hier
                // eine bekannte (kleine) Schrittweiten-Abhängigkeit stehen;
                // sie ist in docs/dt-invariance-measurements.md §5 vermerkt.
                let want = (qcTot - qin) * vegDamp(k)
                let er = erodeCell(k, min(want, max(0, bed.h[k] - lowest) * 0.5), bed)
                qout += er
            }
            // Fracht folgt der Kapazität (∝ qcᵢ): der starke Faden trägt sie weiter.
            if qout > 0 && qcTot > 1e-30 {
                for t in 0..<cnt { pqs[nbK[t]] += qout * (nbQc[t] / qcTot) }
            }
        }
        }}}}}}}}}}}
    }

    // MARK: - Transport-limitierte Fluss-Erosion (SPACE-artig) — TESTPFAD

    /// **Nur im Nicht-Droplet-Zweig** (`cfg.hydraulicEnabled = false`), den die
    /// isolierten Mäander-Kopplungstests (`meanderCfg()` in `SimCoreTests.swift`)
    /// bewusst nutzen: Carve/Altarm/Altern ohne Droplet-Rauschen. Produktion
    /// erodiert fluvial über `outletIncision` + `Hydraulic.erode`.
    ///
    /// Massenerhaltender Sedimenttransport: der Fluss trägt eine Fracht `qs` und
    /// gleicht sie an die Transportkapazität Qc = Kt·Aᵐ·S an. Über Kapazität →
    /// Ablagerung (Deltas an Küsten, Schwemmebenen, Beckenfüllung); unter Kapazität
    /// → Erosion (detachment-begrenzt). Löste seinerzeit die reine detachment-
    /// limitierte Grid-Inzision ab (Commit „B (M3)").
    /// Verarbeitung stromauf→stromab (order rückwärts), sodass
    /// die Fracht jeder Zelle bei ihren Zuflüssen schon angekommen ist.
    ///
    /// Bewegt das Bett ausschließlich über `erodeCell`/`depositCell` und ist
    /// damit unter Eis stillgelegt wie jeder andere fluviale Pass (#35) — der
    /// Testpfad braucht dasselbe Gate wie die Produktion, sonst hinge die
    /// Zusicherung „unter Eis kein fluvialer Abtrag" am Erosionszweig.
    /// Vergletscherte Zellen halten ihre Fracht nicht auf: was sie weder
    /// abgeben noch annehmen, zieht unverändert zum Empfänger weiter.
    private func transportLimited(dt: Double) {
        let cs = cfg.cellSize
        // cellSize 0 (keine definierte Schrittweite): kein Gefälle ohne Distanz,
        // sonst Division durch 0 und NaN-Vergiftung von Fracht und Betthöhen.
        guard cs > 0, cs.isFinite else { return }
        let sqrt2 = 2.0.squareRoot()
        let kt = cfg.transportCap
        let m = cfg.mExp
        fill(&qs, 0)
        var oi = cfg.count - 1
        while oi >= 0 {
            let k = Int(order[oi]); oi -= 1
            let r = receiver[k]
            let qin = qs[k]
            if r < 0 {
                // Meer/Rand: Delta bis Meereshöhe aufbauen, Überschuss geht ins tiefe Meer.
                let room = max(0, cfg.sea - h[k])
                depositCell(k, min(qin, room))
                continue
            }
            let ri = Int(r)
            let ki = k % n, kj = k / n
            let rii = ri % n, rjj = ri / n
            let dist = (ki != rii && kj != rjj) ? cs * sqrt2 : cs
            let a = area[k]
            let s = max(0, (hf[k] - hf[ri]) / dist)
            let qc = kt * pow(a, m) * s
            if qin > qc {
                // über Kapazität → ablagern (aber nicht über den Empfänger hinaus stauen)
                var dep = qin - qc
                let room = max(0, (hf[k] - h[k])) + 0.02 // bis Seespiegel/etwas darüber
                dep = min(dep, room)
                // Unter Eis nimmt der Funnel nichts an (#35); die Fracht zieht
                // dann ungeschmälert weiter talwärts.
                qs[ri] += qin - depositCell(k, dep)
            } else {
                // unter Kapazität → erodieren (detachment-begrenzt, Fels widerstandsfähiger).
                // Auf Kanalzellen gedämpft: dort inzidiert der Mäander-Carve (Reconciliation).
                let damp = isChannel[k] ? cfg.channelErodeDamp : 1.0
                // Lithologie (Issue #12) skaliert NUR den Fels-Zweig: `kSed` ist
                // lockeres Material und weiß nichts vom Gestein darunter.
                let kBed = lithErodeK.count == cfg.count ? cfg.kRock * lithErodeK[k] : cfg.kRock
                let kErode = (sed[k] > cfg.sedCoverThresh ? cfg.kSed : kBed) * vegDamp(k)
                let want = min(qc - qin, kErode * pow(a, m) * s * dt) * damp
                let removable = max(0, h[k] - h[ri]) * 0.5
                // Unter Eis trägt der Funnel nichts ab (#35) und gibt 0 zurück —
                // die Zelle liefert dann auch keine Fracht nach unten.
                let er = erodeCell(k, min(want, removable))
                qs[ri] += qin + er
            }
        }
    }

    // MARK: - Auslass-Inzision (Seen entwässern zum Meer)

    /// Tieft die **Auslass-Sille** abflussloser Becken ein, sodass der See zum Meer
    /// entwässert statt vollzulaufen (Droplet-Pfad) oder zur Flach-Ebene zu verlanden
    /// (basinFill). Der Priority-Flood liefert die Zutaten: an einer Sill-Zelle steht
    /// gestautes Wasser an (hf>h in der Nachbarschaft), und ihr `receiver` zeigt über
    /// den Rand aus dem Becken heraus bergab. Stream-Power-Inzision entlang dieser
    /// Zellen senkt die Sill; der nächste computeFlow senkt den Seespiegel (hf) nach —
    /// self-reinforcing, bis das Becken entwässert ist (dann kein Ponding → Stopp).
    /// So entstehen dendritische Grau-Täler statt Kuppeln/Ebenen (nickmcd-Look).
    /// `minAreaCells > 0` beschränkt die Inzision aufs Trunk-Netz (Einzugsgebiet
    /// ≥ so viele Zellen) — für den Generierungs-Breach: Becken-Sillen/Talwege
    /// haben riesige Einzugsgebiete und werden durchschnitten, Hänge und Grate
    /// bleiben unberührt (junges Relief bleibt erhalten).
    /// PERF wie in priorityFlood: der Hot-Loop läuft auf Roh-Puffern (kein
    /// Bounds-/Exclusivity-Check je Zugriff). Sequenziell MUSS er bleiben: der
    /// implizite Solver liest h[Empfänger], der weiter vorn in `order` schon
    /// aktualisiert wurde. pow bleibt pow (s. powFast-Kommentar: 0.5→sqrt wäre
    /// nicht bit-identisch).
    ///
    /// PERF (Runde 7): Alle ENTSCHEIDUNGEN, die während des Passes NICHT vom
    /// laufend veränderten Bett abhängen, laufen vorab und parallel: die
    /// Gate-Kette (Meer/Breack-Fläche/Beckenwasser/Weltrand) als Int8 in
    /// `incisionGate` und der Vegetations-/Lithologie-Faktor `kErode` in
    /// `incisionKErode`. Bit-identisch, weil der Pass nur je BESUCHTER Zelle
    /// schreibt (`h`/`sed`/`rock` an `k` selbst) — jede Zelle sieht also bei
    /// ihrem Besuch noch exakt die Werte des Pass-Starts — und weil
    /// `underIce`/`area`/`receiver`/`endorheicBasin`/`veg*`/`lith*` im Pass
    /// überhaupt nicht geschrieben werden. Was übrig bleibt, ist die
    /// serielle Abhängigkeit selbst: `ph[Empfänger]` frisch lesen, Formel —
    /// den Sediment/Fels-Split samt Eis-Gate trägt seit Issue #96 der
    /// Bett-Funnel (`erodeCellTo`), und die respektiert der Loop unverändert.
    private func outletIncision(dt: Double, minAreaCells: Double = 0) {
        let cs = cfg.cellSize
        // cellSize 0 (keine definierte Schrittweite): keine Inzision ohne Distanz,
        // sonst Division durch 0 und NaN-Vergiftung der Höhen.
        guard cs > 0, cs.isFinite else { return }
        let sqrt2 = 2.0.squareRoot()
        let minA = minAreaCells * cs * cs
        let m = cfg.mExp
        let cnt = cfg.count, nn = n, sea = cfg.sea, kOut = cfg.outletErode
        // Lithologie (Issue #12): die fluviale Makro-Rate der Produktion ist DIESE
        // — hier entstehen die lithologischen Knickpunkte. Ohne Feld ein
        // 1-Element-Dummy und Faktor exakt 1.0 → bit-identische Arithmetik.
        let lithOn = lithErodeK.count == cnt
        let lithArr = lithOn ? lithErodeK : [1.0]
        // PERF (Issue #43): `pow(A, m)` je Zelle war mit ~16 ms/Schritt der
        // größte Einzelposten des Passes (Messung: mit einer Multiplikation
        // statt pow fiel er von 41 auf 25 ms). `area` ändert sich WÄHREND des
        // Passes nicht — nur `h`/`sed`/`rock` tun das —, also wird die Potenz
        // vorab und PARALLEL berechnet (per-Zelle unabhängig, dieselben
        // libm-Aufrufe mit denselben Argumenten ⇒ bit-identisch) und die
        // serielle Schleife liest sie nur noch nach.
        if areaPow.count != cnt { areaPow = .init(repeating: 0, count: cnt) }
        if incisionGate.count != cnt { incisionGate = .init(repeating: 0, count: cnt) }
        if incisionKErode.count != cnt { incisionKErode = .init(repeating: 0, count: cnt) }
        areaPow.withUnsafeMutableBufferPointer { apb in
        incisionGate.withUnsafeMutableBufferPointer { gb in
        incisionKErode.withUnsafeMutableBufferPointer { kb in
        area.withUnsafeBufferPointer { ab in
        h.withUnsafeBufferPointer { hb in
        lithArr.withUnsafeBufferPointer { lkb in
        veg.withUnsafeBufferPointer { vb in
        vegClass.withUnsafeBufferPointer { vcb in
        vegTypeFactor.withUnsafeBufferPointer { tfb in
        receiver.withUnsafeBufferPointer { rb in
        endorheicBasin.withUnsafeBufferPointer { eb in
            let pap = apb.baseAddress!, pa = ab.baseAddress!, ph0 = hb.baseAddress!
            let pgate = gb.baseAddress!, pker = kb.baseAddress!
            let pveg = vb.baseAddress!, pcls = vcb.baseAddress!, ptf = tfb.baseAddress!
            let prec0 = rb.baseAddress!, pend = eb.baseAddress!
            let plith = lkb.baseAddress!
            parallel(cnt) { lo, hi in
                for k in lo..<hi {
                    // Gate-Kette — dieselbe Reihenfolge wie bisher seriell
                    // (jedes Glied ist ein reiner `continue`-Filter, und alle
                    // gelesenen Felder ändern sich im Pass nicht).
                    // Gletscher (Issue #35) steht hier seit #96 bewusst NICHT
                    // mehr in der Kette: das Eis-Gate trägt der Funnel
                    // (`erodeCellTo` → `Bed.erode`), EINMAL für alle
                    // Bett-Schreiber. Eis-Zellen laufen durch die Kette und
                    // bekommen ein normales `g` — die serielle Schleife rechnet
                    // ihre Formel, und der Funnel verwirft den Abtrag.
                    // Ergebnis bit-identisch (nur Formel-Arbeit mehr auf
                    // vergletscherten Zellen); das Gate kann in künftigem
                    // Pass-Code nicht mehr vergessen werden.
                    var g: Int8 = 1
                    if ph0[k] <= sea { g = 0 }
                    else if minA > 0 && pa[k] < minA { g = 0 }
                    // Abflussloses Becken (Issue #11): die Seefläche hat keinen
                    // Auslass, also gibt es dort nichts einzuschneiden. Die SILL
                    // bleibt dabei ganz ohne Sonderfall stehen — sie sammelt den
                    // Beckenabfluss nicht mehr ein (terminale Senke), ihr A^m ist
                    // winzig, die Inzision versandet von selbst. Genau so hört ein
                    // endorheisches Becken auf, sich selbst zu entwässern.
                    // (Das `minA > 0` davor ist kein zusätzliches Kriterium,
                    // sondern spart im Produktionsfall (`minAreaCells = 0`) den
                    // Zugriff ins große `area`-Feld — `area` ist nie negativ,
                    // der Vergleich konnte dort also nie zutreffen.)
                    else if pend[k] == .water { g = 0 }
                    else if prec0[k] < 0 {
                        // Trockengefallener Beckenboden ohne Empfänger (flache
                        // Zelle im geschlossenen Becken): das virtuelle Basis-
                        // niveau MEER unten gilt nur am Weltrand — im Becken
                        // würde es den Boden Richtung Meeresspiegel ausgraben.
                        // Weltrand (Priority-Flood-Seed) = 2: Wasser verlässt
                        // hier die Welt → virtuelles Basisniveau MEER, s. Loop.
                        g = pend[k] != .none ? 0 : 2
                    }
                    pgate[k] = g
                    // Inaktive Zellen (g == 0: Meer, See) übergeht die
                    // serielle Schleife; pow(A, m) und kErode werden dort nie
                    // gelesen und müssen gar nicht erst berechnet werden.
                    // (Eis-Zellen rechnen mit — der Funnel verwirft.)
                    guard g != 0 else { continue }
                    pap[k] = pow(pa[k], m)
                    pker[k] = kOut * max(0, 1 - 0.6 * ptf[Int(pcls[k])] * pveg[k])
                                  * (lithOn ? plith[k] : 1.0)
                }
            }
        }}}}}}}}}}}
        // `h`/`sed`/`rock` kommen über `withBed` dazu — dieselbe Sicht, über
        // die der Funnel schreibt (Issue #96); die Ziel-Fassung `erodeCellTo`
        // trägt Zerlegung UND Eis-Gate und setzt die Zielhöhe exakt (s. dort).
        withBed { bed in
        areaPow.withUnsafeBufferPointer { apb in
        incisionGate.withUnsafeBufferPointer { gb in
        incisionKErode.withUnsafeBufferPointer { kb in
        order.withUnsafeBufferPointer { ob in
        receiver.withUnsafeBufferPointer { rb in
            let ph = bed.h, pap = apb.baseAddress!
            let pgate = gb.baseAddress!, pker = kb.baseAddress!
            let pord = ob.baseAddress!, prec = rb.baseAddress!
        // Stromabwärts→aufwärts (order = aufsteigende Füllhöhe): der Empfänger ist
        // schon aktualisiert, die Inzision propagiert sill-erhaltend flussaufwärts.
        for oi in 0..<cnt {
            let k = Int(pord[oi])
            let g = pgate[k]
            if g == 0 { continue }
            let hr: Double
            let dist: Double
            if g == 2 {
                // Land-Zelle ohne Empfänger = Weltrand (Priority-Flood-Seed):
                // Wasser verlässt hier die Welt → virtuelles Basisniveau MEER.
                // Ohne das wirkt der Rand als unerodierbarer Pegel und Becken,
                // die über den Rand entwässern, können nie tiefer ausschneiden
                // (gemessen: See blieb 28 Breach-Runden bei exakt 2656 Zellen).
                hr = sea
                dist = cs
            } else {
                let ri = Int(prec[k])
                if ph[k] <= ph[ri] { continue }     // See/Ebene: kein Gefälle → keine Inzision
                hr = ph[ri]
                // PERF (Issue #43): Diagonale über die INDEX-DIFFERENZ statt über
                // zwei i/j-Paare — das spart zwei Integer-Divisionen je Zelle
                // (692k Zellen/Schritt, gemessen der größte Posten des Passes).
                // Der Empfänger ist immer einer der 8 Nachbarn:
                // `computeReceiversAndArea` vergibt ausschließlich Nachbarn, und
                // sein Rückfall `floodParent` ist die Zelle, von der aus der
                // Priority-Flood die Senke besucht hat — ebenfalls ein Nachbar.
                // Für einen 8-Nachbarn gilt |k − r| ∈ {1, nn−1, nn, nn+1}, und
                // genau nn±1 sind die diagonalen Schritte (bei 1 ändert sich nur
                // die Spalte, bei nn nur die Zeile). Ergebnis-identisch zum
                // früheren `i != rii && j != rjj`.
                let dIdx = k > ri ? k - ri : ri - k
                dist = (dIdx == nn - 1 || dIdx == nn + 1) ? cs * sqrt2 : cs
            }
            // Reine Flächen-Stream-Power: die Inzision konzentriert sich auf Zellen mit
            // großem Einzugsgebiet (Täler/Auslässe) und lässt Grate in Ruhe → dendritisch
            // statt verrauscht. Ein Becken-Auslass sammelt das ganze Becken → tieft zügig
            // ein → See entwässert zum Meer.
            // Vegetation bremst — klassen-gewichtet wie vegDamp; der Faktor stand
            // schon vor dem Pass fest (kein Bett-Feld geht in ihn ein) und
            // reist deshalb vorab berechnet in `incisionKErode`.
            let f = pker[k] * dt * pap[k] / dist
            let hNew = (ph[k] + f * hr) / (1 + f)
            // Bett-Regel (erst Sediment, dann Fels) UND Gletscher-Gate: der
            // Funnel (Issue #96). Die Ziel-Fassung setzt `hNew` EXAKT —
            // `erodeCell(k, ph[k] - hNew)` wäre nicht bit-gleich zu `hNew`
            // (s. `erodeCellTo(_:_:_:)`).
            erodeCellTo(k, hNew, bed)
        }
        }}}}}}
    }

    // MARK: - Hydraulische Bett-Inzision (Gleichgewichtstiefe)

    /// Hält auf ausreichend feinen Gittern die Betten des Abflussnetzes auf
    /// hydraulischer Gleichgewichtstiefe (Issue #108, Ansatz 2). Ein aktiver
    /// Fluss verlandet im Alter nicht, sondern räumt sein Bett gegenüber den
    /// Talflanken auf eine definierte Tiefe aus, abgestimmt auf RIVER_LIFT
    /// (0.35 Welt-Y). Die Auflösungsgrenze steht bei `channelTargetDepth`.
    private func channelCarve(dt: Double) {
        let cs = cfg.cellSize
        let cellArea = cs * cs
        let minA = cfg.channelFlowMinCells * cellArea
        let fullA = cfg.channelFlowFullCells * cellArea
        let targetDepth = cfg.channelTargetDepth
        // Feste Kalibrierung des feinen Querprofils, Messreihe und Grenzen:
        // docs/channel-incision-measurements.md §G. Keine neuen Spielstand-Felder.
        let maximumCellSize = 0.25
        let depthMultiplier = 1.5
        let relaxationYears = 3000.0
        let bankDepthFraction = 0.45
        let bankRelaxationFraction = 0.45
        guard cs <= maximumCellSize, targetDepth > 0, minA > 0, fullA > minA else { return }
        let nn = n, cnt = cfg.count, sea = cfg.sea
        let capF = Terrain.relaxFraction(dt: dt, tau: relaxationYears)
        // Bis 0.026 darf der Lauf seinen flachen Anschluss an den See räumen.
        // 0.020 ließ am Raster-Übergang nur 0.00482 Band-Deckkraft übrig,
        // 0.025 noch 0.01241. 0.026 ergibt 0.02483 und liegt damit im
        // gemessenen Bereich unter der Obergrenze 0.045. 0.030 öffnete auch tiefe
        // Seezellen und erzeugte mit 0.15744 echtes Doppelwasser.
        let lakeMarginDepth = 0.026
        
        let beltOn = cfg.meanderEnabled && cfg.meanderBelt
        let beltMinA = cfg.meanderBeltMinCells * cellArea, beltFlat = cfg.meanderFlatSlope
        // PERF (Runde 7): `area` und `inBelt` sind die einzigen zwei Gates des
        // Passes, deren Operanden sich WÄHREND des Passes nicht ändern — und
        // sie scheiden fast alle Zellen aus (nur wasserführende Läufe ab
        // `channelFlowMinCells` kommen überhaupt in Betracht). Der Vorfilter
        // läuft deshalb vorab und parallel; alle übrigen Gates (Meer, See-
        // Rand, Gürtel-Flachheit) lesen frisches `h` — die Ufer-Erosion
        // schreibt FREMDE Zellen, `h[k]` ist zum Besuchzeitpunkt also nicht
        // der Pass-Startwert — und bleiben unverändert im seriellen Loop.
        // Reine `continue`-Filter darf man vorziehen: ihr Ergebnis ist für
        // jede Zelle dasselbe, egal in welcher Reihenfolge sie geprüft
        // werden.
        if carveStatus.count != cnt { carveStatus = .init(repeating: false, count: cnt) }
        area.withUnsafeBufferPointer { ab in
        inBelt.withUnsafeBufferPointer { beltb in
        carveStatus.withUnsafeMutableBufferPointer { stb in
            let pa0 = ab.baseAddress!, pbelt0 = beltb.baseAddress!
            let pst = stb.baseAddress!
            parallel(cnt) { lo, hi in
                for k in lo..<hi {
                    pst[k] = pa0[k] >= minA && !(beltOn && pbelt0[k])
                }
            }
        }}}
        hf.withUnsafeBufferPointer { hfb in
        receiver.withUnsafeBufferPointer { recb in
        area.withUnsafeBufferPointer { ab in
        order.withUnsafeBufferPointer { ob in
        inBelt.withUnsafeBufferPointer { beltb in
        carveStatus.withUnsafeBufferPointer { stb in
        withBed { bed in
            let ph = bed.h, prec = recb.baseAddress!, pa = ab.baseAddress!, pord = ob.baseAddress!
            let phf = hfb.baseAddress!, pbelt = beltb.baseAddress!
            let pst = stb.baseAddress!
            for oi in 0..<cnt {
                let k = Int(pord[oi])
                // Vorfilter (vorab parallel): area/Gürtel-Gate, s. oben.
                if !pst[k] { continue }
                if ph[k] <= sea { continue }
                if phf[k] - ph[k] > lakeMarginDepth { continue }
                if beltOn && pbelt[k] { continue } // Sohle gehört dem Gürtel-Stempel (#174)
                let a = pa[k]
                if a < minA { continue }
                // Tiefland-Lauf mit Gürtel (#174): keine Rinne von
                // `channelTargetDepth` (≈ 35 m) — ein Mäanderfluss liegt bankfull
                // in seiner Aue. In der Rinne hielt die Querneigung jede Schlinge
                // fest, der Lauf blieb gemessen gerade und konnte die Rinne auch
                // nicht seitlich ausräumen.
                if beltOn && a >= beltMinA {
                    let ki0 = k % nn, kj0 = k / nn
                    if ki0 >= 2, kj0 >= 2, ki0 <= nn - 3, kj0 <= nn - 3,
                       Terrain.macroSlope(ph, k, nn) / cs < beltFlat { continue }
                }
                let r = Int(prec[k])
                if r < 0 || r == k { continue }
                if ph[r] <= sea { continue }
                
                let rj = r / nn, ri = r % nn
                let kj = k / nn, ki = k % nn
                
                // Auslass-Schwelle eines Sees wird von outletIncision geschnitten, nicht hier
                var touchesLake = false
                for dj in -1...1 {
                    for di in -1...1 {
                        let ni = ki + di, nj = kj + dj
                        if ni < 0 || ni >= nn || nj < 0 || nj >= nn { continue }
                        if phf[nj * nn + ni] - ph[nj * nn + ni] > lakeMarginDepth { touchesLake = true; break }
                    }
                    if touchesLake { break }
                }
                if touchesLake { continue }
                let qi = -(rj - kj)
                let qj = ri - ki
                
                // Flanken-Sampling bei Distanz 2..3 (wie ChannelIncision.measure):
                var acc = 0.0, m = 0
                for s in [-3, -2, 2, 3] {
                    let xi = ki + qi * s, xj = kj + qj * s
                    if xi < 0 || xi >= nn || xj < 0 || xj >= nn { continue }
                    acc += ph[xj * nn + xi]; m += 1
                }
                guard m >= 2 else { continue }
                let flankH = acc / Double(m)
                
                let x = min(1.0, (a - minA) / (fullA - minA))
                let s = x * x * (3.0 - 2.0 * x)
                let dEq = targetDepth * depthMultiplier * s
                
                let targetH = flankH - dEq
                let minAllowed = ph[r] + 1e-4
                let finalTarget = max(targetH, minAllowed)
                
                if ph[k] > finalTarget {
                    let delta = (ph[k] - finalTarget) * capF
                    _ = erodeCell(k, delta, bed)
                }
                
                // Bei n=720 (dx=0.156) ist das Wasserband 3..6 Zellen breit.
                // Das Querprofil stützt das Band an den Flanken ab. Grobe Gitter
                // sind bereits am Einstieg ausgeschlossen.
                let bankTarget = max(flankH - bankDepthFraction * dEq, finalTarget)
                for side in [-1, 1] {
                    let bi = ki + qi * side, bj = kj + qj * side
                    if bi < 0 || bi >= nn || bj < 0 || bj >= nn { continue }
                    let bk = bj * nn + bi
                    if phf[bk] - ph[bk] > 0.005 { continue }
                    var bTouchesLake = false
                    for dj in -1...1 {
                        for di in -1...1 {
                            let bni = bi + di, bnj = bj + dj
                            if bni < 0 || bni >= nn || bnj < 0 || bnj >= nn { continue }
                            if phf[bnj * nn + bni] - ph[bnj * nn + bni] > 0.005 { bTouchesLake = true; break }
                        }
                        if bTouchesLake { break }
                    }
                    if bTouchesLake { continue }
                    if ph[bk] > bankTarget && ph[bk] > sea {
                        let bDelta = (ph[bk] - bankTarget) * capF * bankRelaxationFraction
                        _ = erodeCell(bk, bDelta, bed)
                    }
                }
            }
        }}}}}}}
    }

    // MARK: - Seen-Verfüllung

    /// Füllt Senken (hf > h) langsam mit Sediment auf — Näherung an den
    /// Sediment-Transport (den detachment-limited Stream-Power nicht leistet):
    /// große geschlossene Becken werden über die Zeit zu flachen Schwemmebenen
    /// statt riesiger Seen. Volle SPACE-Physik (Deltas/Mäander) folgt in M3.
    private func fillLakes(dt: Double) {
        // Exponentiell statt linear gedeckelt (Issue #2): 1 − e^(−dt/τ)
        // teleskopiert über beliebig viele Teilschritte exakt zum Ergebnis EINES
        // Sprungs (wie `relaxWaterLevel`), `min(0.5, dt/τ)` tat das nicht.
        let rate = Terrain.relaxFraction(dt: dt, tau: 3000.0) // Zeitkonstante ~3000 Jahre
        for k in 0..<cfg.count where hf[k] > cfg.sea {
            let deficit = hf[k] - h[k]
            if deficit > 0.001 {
                let add = deficit * rate
                h[k] += add
                sed[k] += add
            }
        }
    }

    /// Pfützen-Verlandung: SEICHTES Ponding (≤ puddleFillDepth) auf Land füllt
    /// sich mit Sediment auf — die Auen trugen sonst dauerhafte Flachwasser-
    /// Sprenkel knapp über der Render-Schwelle (zerfetzte Blob-Felder). Anders
    /// als `fillLakes` tiefen-GEDECKELT: echte Seen (tieferes Becken) bleiben.
    /// Mäander-Betten (isChannel) sind ausgenommen (Reconciliation: das
    /// gecarvte Bett nicht zuschütten).
    ///
    /// NUR Komponenten OHNE SEE-KERN (4er-BFS über zusammenhängendes Ponding):
    /// die Pauschal-Verfüllung hob sonst auch die kilometerbreiten Sub-0.06-
    /// Ufersäume der großen Seen als Ganzes an — sichtbar „wachsender Boden
    /// ohne Wasser" (User-Beobachtung; gemessen: 90% der Tiefland-Hebung,
    /// +0.03/6000 J. auf den Säumen). Ein SEE ist eine Komponente mit tiefem
    /// Kern (max-Tiefe > puddleFillDepth — dieselbe „echte Seen bleiben"-
    /// Semantik wie der Tiefen-Deckel); sein Ufersaum verlandet nur noch
    /// physisch über die Droplet-Deltas (Sediment-ZUFUHR von den Mündungen,
    /// gerichtet). Braid-/Auen-Pfützennetze sind überall seicht → verlanden
    /// weiter komplett, egal wie ausgedehnt (eine Größen-Schwelle traf je nach
    /// Seed auch Bank-Pfützen: Braid-Insel-Guard kippte bei 64 UND 400 Zellen).
    /// Ziel bewusst das volle hf, NICHT der geglättete waterLevel (über 3 Seeds
    /// ohne messbaren Volumen-Effekt, drückte aber die Braid-Bänke 9→2).
    ///
    /// Vergletscherte Zellen (`underIce`) sind ebenfalls ausgenommen: unter dem
    /// Eis steht kein Wasser, in dem Sediment absinken könnte. Und `hf` stammt
    /// vom Schrittanfang, `updateIce` hat das Bett danach schon geschliffen —
    /// jede Zelle, die der Gletscher in diesem Schritt um mehr als 0,001 tiefer
    /// legt, sähe hier wie eine Pfütze aus und bekäme den Schliff zum Teil
    /// wieder aufgefüllt. Das traf nur große Schritte (bei dt = 1000 schleift
    /// ein Schritt fast überall mehr als 0,001, bei dt = 100 kaum eine Zelle)
    /// und machte die Gletscher-Erosion damit schrittweitenabhängig: am Gipfel
    /// gemessen +0,017 Wiederauffüllung in 4000 Jahren bei dt = 1000 gegen
    /// +0,002 bei dt = 100 (`docs/glacier-measurements.md` §L). Ohne Eis ist die
    /// Maske leer und der Pass rechnet bit-identisch zu vorher.
    private func fillShallowPonds(dt: Double) {
        // Exponentielle Relaxation (Issue #2, s. fillLakes): die lineare Form
        // verlandete den Zeitraffer (viele kleine dt) und den Sprung
        // unterschiedlich schnell — mit `puddleFillYears = 800` deckelte
        // `min(0.5, dt/τ)` schon ab dt = 400 und ließ große Schritte
        // systematisch zu viel Ponding stehen.
        let rate = Terrain.relaxFraction(dt: dt, tau: cfg.puddleFillYears)
        let sea = cfg.sea, nn = n, cnt = cfg.count
        let deepThresh = cfg.puddleFillDepth, coreCells = cfg.puddleLakeCoreCells
        // Persistente Puffer (Hot-Loop, keine Allokation je Schritt).
        fill(&pondSeen, false)
        // PERF: der Suchlauf tastet ALLE 692k Zellen ab und las dabei
        // `pondSeen`/`hf`/`h`/`endorheicBasin` über die Klassen-Property (je
        // Zugriff Bounds-, COW- und Exklusivitäts-Prüfung — gemessen steckte
        // rund ein Drittel des Passes in der Swift-Laufzeit). Jetzt liegen alle
        // Felder als Roh-Puffer offen; der BFS-Schritt ist als lokales `push`
        // darauf ausgeschrieben (er hatte keinen zweiten Aufrufer). Werte,
        // Reihenfolge und Vergleiche unverändert;
        // `h`/`sed` schreibt der Pass bewusst DIREKT (kein Gletscher-Gate — das
        // war schon vorher so, die Verlandung ist kein fluvialer Bett-Pass).
        var comp: [Int32] = []
        var stack: [Int32] = []
        // Wasserführende Läufe bleiben aus der Verlandung heraus (Issue #108),
        // dieselbe Regel wie für die Mäander-Betten (`isChannel`) darunter — nur
        // über den Abfluss statt über eine Maske, weil die dendritischen Läufe
        // keine haben. Begründung und Messwerte: `cfg.puddleFillSkipsFlowCells`.
        let flowLimit = cfg.puddleFillSkipsFlowCells && area.count == cnt
            ? cfg.channelFlowMinCells * cfg.cellSize * cfg.cellSize
            : .infinity
        // Gletscher-Maske: leer, solange nirgends Eis über der Schwelle liegt.
        let iceGate = underIce.count == cnt
        let iceArr = iceGate ? underIce : [false]
        hf.withUnsafeBufferPointer { hfb in
        h.withUnsafeMutableBufferPointer { hb in
        sed.withUnsafeMutableBufferPointer { sb in
        pondSeen.withUnsafeMutableBufferPointer { psb in
        endorheicBasin.withUnsafeBufferPointer { ebb in
        isChannel.withUnsafeBufferPointer { icb in
        regenPending.withUnsafeBufferPointer { rpb in
        area.withUnsafeBufferPointer { arb in
        iceArr.withUnsafeBufferPointer { iab in
        let phf = hfb.baseAddress!, ph = hb.baseAddress!, psed = sb.baseAddress!
        let punder = iab.baseAddress!
        let pseen = psb.baseAddress!, pend = ebb.baseAddress!
        let pchan = icb.baseAddress!, pregen = rpb.baseAddress!
        let parea = arb.baseAddress!
        /// BFS-Schritt der Pfützen-Komponentensuche (4er-Nachbarschaft).
        /// Die Wasserfläche eines abflusslosen Beckens (Issue #11) ist hier
        /// bewusst KEINE Pfütze: ihren Spiegel setzt der Wasserhaushalt, und
        /// eine verdunstungs-gedeckelte Playa ist per Konstruktion seicht — die
        /// Pfützen-Verlandung würde also genau die Fläche zuschütten, die #11
        /// gerade freigelegt hat (und der Beckenboden trocknet ohnehin aus,
        /// statt zu verlanden). Der trockengefallene Boden hat hf = h und fällt
        /// schon durchs Tiefen-Gate.
        @inline(__always) func push(_ k: Int, _ stack: inout [Int32]) {
            if !pseen[k] && phf[k] > sea && phf[k] - ph[k] > 0.001
                && pend[k] != .water {
                pseen[k] = true
                stack.append(Int32(k))
            }
        }
        for s in 0..<cnt where !pseen[s] && phf[s] > sea && phf[s] - ph[s] > 0.001
                                     && pend[s] != .water {
            comp.removeAll(keepingCapacity: true)
            stack.removeAll(keepingCapacity: true)
            stack.append(Int32(s)); pseen[s] = true
            var deepCells = 0
            while let kk = stack.popLast() {
                let k = Int(kk)
                comp.append(kk)
                if phf[k] - ph[k] > deepThresh { deepCells += 1 }
                let i = k % nn, j = k / nn
                if i > 0 { push(k - 1, &stack) }
                if i < nn - 1 { push(k + 1, &stack) }
                if j > 0 { push(k - nn, &stack) }
                if j < nn - 1 { push(k + nn, &stack) }
            }
            // See = Komponente mit SUBSTANZIELLEM tiefen Kern (absolute Zellzahl):
            // deren Ufersaum bleibt. Zwei verworfene Kriterien (beide gemessen):
            // „berührt irgendeinen tiefen Pool" nahm auch Braid-/Auen-Netze aus,
            // die fast immer an einem Einzelpool hängen (Braid-Insel-Guard kippte
            // 3 vs 4); ein RELATIVER Kern-Anteil (≥20%) ließ genau den Problemfall
            // durch — riesiger seichter Saum um kompakten tiefen Kern (Seed 1337:
            // nur −45% Saum-Hebung statt −100%).
            if deepCells >= coreCells { continue }
            for kk in comp {
                let k = Int(kk)
                if pchan[k] { continue }
                if parea[k] > flowLimit { continue }  // Flussbett, keine Pfütze (#108)
                if iceGate && punder[k] { continue }  // Gletscherbett, keine Pfütze (s. o.)
                // Frische Baustelle (Issue #26): solange an dieser Zelle noch
                // Regeneration aussteht, NICHT verlanden. Die Pfützen-Verlandung
                // ist ein Aufräum-Pass gegen Flachwasser-Sprenkel in reifen Auen
                // — auf einer eben erst planierten Fläche würde sie genau das
                // Mikro-Relief wieder zuschütten, aus dem sich die neue
                // Entwässerung organisiert (junge Grundmoränen-Landschaften sind
                // Seen-Mosaike, keine trockenen Platten).
                //
                // Kriterium ist bewusst das OFFENE BUDGET und keine eigene
                // Störungs-Schwelle: eine Schwelle (probiert: 5 % Reststörung
                // ≈ 3 τ) öffnet ein Fenster, in dem der Boden noch steigt/sinkt,
                // die Verlandung aber schon wieder zuschüttet — und zwar mit bis
                // zu `puddleFillDepth` (0.06) gegen einen Rest von wenigen
                // Tausendsteln. So endet die Aussetzung exakt dann, wenn sich
                // das Gelände nicht mehr bewegt (`regenerateDisturbed` schaltet
                // ab und nullt das Budget).
                if disturbActive && pregen[k] != 0 { continue }
                let deficit = phf[k] - ph[k]
                if deficit > 0.001 && deficit <= deepThresh {
                    let add = deficit * rate
                    ph[k] += add
                    psed[k] += add
                }
            }
        }
        }}}}}}}}}
    }

    // MARK: - Auen-Aggradation (Overbank-Deposition → flache Schwemmebenen)

    /// Baut flache Auenböden entlang der Flüsse: für jede Fluss-Zelle (großes
    /// Einzugsgebiet) werden die tal-nahen *tieferen* Zellen mit Sediment bis knapp
    /// über das Bett-Niveau (bankfull) aufgefüllt. Ergebnis: breite Niedrig-Gradient-
    /// Reaches, in denen ein Fluss lateral wandern kann (mäandern/verflechten) —
    /// ohne sie sind die gecarvten V-Täler zu schmal dafür (gemessen: nur ~1500
    /// Zellen größte zusammenhängende Aue).
    ///
    /// NUR tal-nahe Zellen UNTER `bett+Auenhöhe` werden gefüllt → steile Talwände
    /// und Berge (darüber) bleiben unberührt. Deposition-only und auf die Auenhöhe
    /// gedeckelt → konvergiert. Größere Flüsse → höhere & breitere Auen (∝ log
    /// Abfluss). Physisch = Overbank-/Schwemm-Deposition.
    ///
    /// STABILITÄT (wichtig): die **Kanalzellen sind die Referenz und werden NIE
    /// angehoben** — nur *Nicht*-Kanal-Zellen werden aggradiert. Sonst pumpen sich
    /// auf flachen Reaches benachbarte Kanalzellen (Slope < depth) gegenseitig hoch
    /// (A hebt B→A+depth, B hebt A→B+depth) → Runaway (gemessen: maxH 0.95→10.7).
    /// Da Nicht-Kanal-Zellen ihrerseits nichts anheben, gibt es keine Rückkopplung:
    /// jede Aue-Zelle konvergiert gegen max(Kanalbett+Auenhöhe) in ihrer Nähe.
    private func floodplainAggradation(dt: Double) {
        let cellArea = cfg.cellSize * cfg.cellSize
        // cellSize 0 (keine definierte Schrittweite): keine D8-Fläche ohne Zellfläche.
        guard cellArea > 0, cellArea.isFinite else { return }
        let minA = cfg.floodplainMinArea
        // Exponentiell (Issue #2, s. fillLakes) — der Pass ist zwar geparkt
        // (`floodplainEnabled = false`), soll aber nicht mit einer bekannt
        // dt-abhängigen Relaxation als Referenz liegenbleiben.
        let rate = Terrain.relaxFraction(dt: dt, tau: cfg.floodplainFillYears)
        if rate <= 0 { return }
        for k in 0..<cfg.count {
            if hf[k] <= cfg.sea || h[k] <= cfg.sea { continue }
            if h[k] > cfg.floodplainMaxElev { continue }      // nur Tiefland-Reaches (Auen sind Tiefland)
            let cu = area[k] / cellArea
            if cu < minA { continue }                         // nur Hauptflüsse bauen Auen
            let mag = log(cu / minA + 1)
            let level = h[k] + cfg.floodplainDepth + cfg.floodplainDepthK * mag // bankfull-Referenz
            let w = min(9, max(1, Int((cfg.floodplainWidthK * mag).rounded())))
            let i = k % n, j = k / n
            let jLo = max(0, j - w), jHi = min(n - 1, j + w)
            let iLo = max(0, i - w), iHi = min(n - 1, i + w)
            for nj in jLo...jHi {
                for ni in iLo...iHi {
                    let nb = nj * n + ni
                    if nb == k { continue }
                    if area[nb] / cellArea >= minA { continue } // andere Kanalzelle = Referenz, NIE anheben
                    if h[nb] <= cfg.sea { continue }            // Meer nicht auffüllen
                    if h[nb] >= level { continue }              // Talwand/über Aue → unberührt
                    let add = (level - h[nb]) * rate
                    // Aggradation (Sediment) über den gemeinsamen Funnel — der
                    // trägt das Gletscher-Gate (#35). `add` ist hier immer > 0
                    // (h < level, rate > 0), der Pass rechnet also unverändert.
                    depositCell(nb, add)
                }
            }
        }
    }

    // MARK: - Hangdiffusion (linear, uniformes kappa) — TESTPFAD

    /// **Nur im Nicht-Droplet-Zweig** (`cfg.hydraulicEnabled = false`) — dort
    /// zusammen mit `transportLimited` der Grid-Pfad der isolierten Mäander-
    /// Kopplungstests. Der Produktionspfad diffundiert über
    /// `hillslopeDiffusion` (räumlich variables kappa, dt-invariant sub-getaktet).
    ///
    /// Lineare Diffusion dh/dt = D·∇²h — glatte, natürliche Hänge (konkav/konvex)
    /// statt der planaren Facetten/Terrassen der Schwellen-Talus-Methode.
    /// kappa uniform und fix (≪ 0.25 → explizit stabil), `passes`-mal pro Sim-Schritt.
    private func diffusionPass(kappa: Double = 0.0025) {
        if kappa <= 0 { return }
        for j in 0..<n {
            for i in 0..<n {
                let k = idx(i, j)
                let hl = i > 0 ? h[k - 1] : h[k]
                let hr = i < n - 1 ? h[k + 1] : h[k]
                let hd = j > 0 ? h[k - n] : h[k]
                let hu = j < n - 1 ? h[k + n] : h[k]
                scratch[k] = kappa * (hl + hr + hd + hu - 4 * h[k])
            }
        }
        for k in 0..<cfg.count {
            let dh = scratch[k]
            if dh == 0 { continue }
            if dh >= 0 {
                sed[k] += dh
            } else {
                let ds = min(-dh, sed[k])
                sed[k] -= ds
                rock[k] -= (-dh - ds)
            }
            h[k] += dh
        }
    }

    /// Hangdiffusion mit RÄUMLICH VARIABLEM kappa. Bodenkriechen braucht Boden:
    /// soil-mantled/sanfte/bewachsene Hänge runden voll aus, aber **hoher, steiler,
    /// kahler Fels kriecht kaum** → dort bleiben spitze Gipfel/Grate stehen (die
    /// Ausnahme, nicht die Regel). So altert die Landschaft ungleichmäßig-natürlich
    /// statt uniform-rund. `base` = kappa auf voll diffundierenden Zellen.
    /// PERF: beide Pässe sind per-Zelle unabhängig (Pass 1 liest h/sed/veg,
    /// schreibt nur scratch[k]; Pass 2 liest scratch, schreibt nur h/sed/rock[k])
    /// → datenparallel auf Roh-Puffern, bit-identisch zur sequenziellen Schleife.
    private func hillslopeDiffusion(base: Double) {
        if base <= 0 { return }
        let nn = n, cnt = cfg.count
        // Lithologie (Issue #12): harte Bänke kriechen langsamer. OHNE das gibt es
        // keinen dauerhaften Hangknick — die Diffusion rundet die Kante der harten
        // Bank weg, egal wie langsam der Fluss sie einschneidet (Wächter:
        // `Lithology.testDiffusionContrastEffectIsMeasured`). Faktor exakt 1.0, wenn
        // das Feld fehlt oder der Kontrast 0 ist → bit-identische Arithmetik.
        let lithDC = lithHardness.count == cnt ? cfg.lithDiffusionContrast : 0
        let lithArr = lithDC != 0 ? lithHardness : [0.0]
        // Kanal-Schutz (Issue #108): im aktiven Kanal räumt die Strömung das
        // einkriechende Material ab, also kriecht dort effektiv weniger Boden
        // ins Bett. Ohne das schmiert die Diffusion die Rinnen zu, in denen die
        // Flüsse laufen — der gemeldete „Wasser liegt ohne Taleinschnitt auf dem
        // Hang". Größe ist das D8-Einzugsgebiet in Zellen. AUS (damp ≥ 1) oder
        // ohne `area`-Feld fällt der ganze Zweig weg → bit-identisch; und auch
        // AN ist der Faktor unterhalb der Schwelle exakt 1.0, also nur die
        // Kanalzellen rechnen anders (Kalibrierung: s. `channelDiffusionDamp`).
        let chDamp = cfg.channelDiffusionDamp
        let chOn = chDamp < 1 && area.count == cnt
        let chCellArea = cfg.cellSize * cfg.cellSize
        let chLo = cfg.channelFlowMinCells * chCellArea
        let chHi = max(chLo + 1e-12, cfg.channelFlowFullCells * chCellArea)
        let chArr = chOn ? area : [0.0]
        h.withUnsafeMutableBufferPointer { hb in
        sed.withUnsafeMutableBufferPointer { sb in
        rock.withUnsafeMutableBufferPointer { rkb in
        veg.withUnsafeBufferPointer { vb in
        lithArr.withUnsafeBufferPointer { ldb in
        chArr.withUnsafeBufferPointer { cab in
        scratch.withUnsafeMutableBufferPointer { scb in
            let ph = hb.baseAddress!, psed = sb.baseAddress!, prock = rkb.baseAddress!
            let pveg = vb.baseAddress!, psc = scb.baseAddress!
            let phard = ldb.baseAddress!, parea = cab.baseAddress!
            parallel(nn) { jLo, jHi in
            for j in jLo..<jHi {
                let row = j * nn
                let innerRow = j > 0 && j < nn - 1
                for i in 0..<nn {
                    let k = row + i
                    let hl: Double, hr: Double, hd: Double, hu: Double
                    if innerRow && i > 0 && i < nn - 1 {
                        hl = ph[k - 1]; hr = ph[k + 1]
                        hd = ph[k - nn]; hu = ph[k + nn]
                    } else {
                        hl = i > 0 ? ph[k - 1] : ph[k]
                        hr = i < nn - 1 ? ph[k + 1] : ph[k]
                        hd = j > 0 ? ph[k - nn] : ph[k]
                        hu = j < nn - 1 ? ph[k + nn] : ph[k]
                    }
                    let lap = hl + hr + hd + hu - 4 * ph[k]
                    if lap == 0 {
                        psc[k] = 0
                        continue
                    }
                    // Kahler-Fels-Faktor: hoch (h>0.42), steil und unbewachsen → wenig
                    // Kriechen. Sediment/Vegetation heben das Kriechen wieder an.
                    // Unter 0.42 ist `high = 0` und damit `bare = 0` exakt; die Ableitung,
                    // Wurzel und Zugriffe auf `sed` und `veg` entfallen dort vollständig.
                    var localK = base
                    if ph[k] > 0.42 {
                        let gx = (hr - hl) * 0.5, gy = (hu - hd) * 0.5
                        let slope = (gx * gx + gy * gy).squareRoot()
                        let steep = min(1, slope * 26)               // etwas früher „steil" → mehr Grate bleiben scharf
                        let high = min(1, (ph[k] - 0.42) / 0.35)     // Schutz schon ab mittlerer Höhe
                        let soil = min(1, psed[k] / 0.02 + pveg[k])  // Boden ODER Bewuchs → Kriechen
                        let bare = steep * high * max(0, 1 - soil)   // 1 = kahler steiler Hochfels
                        localK = base * (1 - 0.92 * bare)            // dort bis auf 8% gedrosselt (Gipfel bleiben spitz)
                    }
                    // Gesteinshärte: D = 1 − c·hard, Untergrenze 0.05 (kein
                    // vollständig eingefrorener Hang, auch bei c > 1).
                    if lithDC != 0 { localK *= max(0.05, 1 - lithDC * phard[k]) }
                    // Kanal-Schutz: kappa → damp, sanft über das Einzugsgebiet
                    // (smoothstep, damit im Gelände keine Kante entsteht).
                    if chOn && parea[k] > chLo {
                        let x = min(1, (parea[k] - chLo) / (chHi - chLo))
                        let s = x * x * (3 - 2 * x)
                        localK *= 1 - (1 - chDamp) * s
                    }
                    psc[k] = localK * lap
                }
            }
            }
            parallel(cnt) { lo, hi in
            for k in lo..<hi {
                let dh = psc[k]
                if dh == 0 { continue }
                if dh >= 0 {
                    psed[k] += dh
                } else {
                    let ds = min(-dh, psed[k])
                    psed[k] -= ds
                    prock[k] -= (-dh - ds)
                }
                ph[k] += dh
            }
            }
        }}}}}}}
    }

    // MARK: - Wellenerosion (Küstenzone)

    /// EIN Teilschritt der Küstenerosion. `relax` ist die Stärke DIESES
    /// Teilschritts; wie viele Teilschritte ein Zeitschritt bekommt und wie stark
    /// jeder ist, legt `waveSchedule(dt:)` fest — die Gesamtwirkung ist damit
    /// ∝ dt (Issue #2), genau wie bei der Hangdiffusion.
    private func wavePass(relax: Double) {
        if relax <= 0 { return }
        // PERF (Issue #43): Roh-Puffer. Der Pass verschiebt Material zum
        // NACHBARN, ist also nicht per-Zelle unabhängig und bleibt seriell —
        // dafür läuft er bei großem dt vielfach (ein Teilschritt je 100 Jahre,
        // s. `waveSchedule`), und jeder Durchlauf zahlte seine Zugriffe auf
        // `h`/`sed`/`rock` über die Klassen-Property. Gemessen 5,7 → 1,6 ms.
        let nn = n, sea = cfg.sea, band = cfg.waveBand, talus = cfg.waveTalus
        h.withUnsafeMutableBufferPointer { hb in
        sed.withUnsafeMutableBufferPointer { sb in
        rock.withUnsafeMutableBufferPointer { rb in
        let ph = hb.baseAddress!, psed = sb.baseAddress!, prock = rb.baseAddress!
        for j in 1..<(nn - 1) {
            for i in 1..<(nn - 1) {
                let k = j * nn + i
                if abs(ph[k] - sea) > band { continue }
                var best = -1
                var bestDrop = talus
                for nb in [k - 1, k + 1, k - nn, k + nn] {
                    let d = ph[k] - ph[nb]
                    if d > bestDrop { bestDrop = d; best = nb }
                }
                if best >= 0 {
                    let move = (bestDrop - talus) * 0.5 * relax
                    let ms = min(move, psed[k])
                    let mr = (move - ms) * 0.5
                    psed[k] -= ms
                    prock[k] -= mr
                    ph[k] -= ms + mr
                    psed[best] += ms + mr
                    ph[best] += ms + mr
                }
            }
        }
        }}}
    }

    /// Teilschritt-Takt der Küstenerosion (Issue #2). Dieselbe Bauart wie beim
    /// Diffusions-Substepping: die STÄRKE eines Teilschritts ist fest
    /// (`waveRelax` je 100 Jahre — der kalibrierte Wert), die ANZAHL wächst
    /// mit `dt`. Vorher war `wavePass` eine reine ZÄHLSCHLEIFE
    /// (`max(1, min(24, dt/100))`) mit voller Stärke je Durchlauf: ein
    /// Zeitraffer-Schritt (dt ≈ 9 J.) bekam damit die volle 100-Jahr-Relaxation
    /// → bis zu 11× zu viel Küstenerosion, und ab dt > 2400 sättigte der Deckel
    /// 24 → große Sprünge erodierten zu wenig. Gemessen (n=192, 20k J., Seed
    /// 1337): Küstenzone 5943 Zellen bei dt=10 gegen 4314 bei dt=240.
    /// Bei dt = k·100 ist der Takt identisch zu vorher (k Teilschritte voller
    /// Stärke) — die Kalibrierung von `waveRelax` bleibt damit unangetastet.
    ///
    /// KOSTEN: der Wegfall des 24er-Deckels macht einen +10.000-Jahre-Sprung
    /// zu 100 Küsten-Teilschritten (vorher 24). Das ist die minimale Zahl, mit
    /// der die Teilschritt-Stärke unter `waveRelax` bleibt — und der Pass ist
    /// ein reiner O(n²)-Scan über das Höhenfeld ohne Nachbarschafts-Suche,
    /// also die billigste Sorte Pass in `step()`.
    private func waveSchedule(dt: Double) -> (count: Int, relax: Double) {
        let total = cfg.waveRelax * dt / 100          // Gesamt-Relaxation dieses Schritts
        // Aufrunden, nicht runden: kein Teilschritt darf STÄRKER als der
        // kalibrierte 100-Jahr-Schritt werden (Stabilität wie subK ≤ 0.2).
        let count = max(1, Int((dt / 100).rounded(.up)))
        return (count, total / Double(count))
    }

    // MARK: - Delta-Schüttung (Issue #174)

    /// Summe der Höhen und Zahl der Landzellen für die Delta-Fracht (s.
    /// `deltaDeposit`), in festen 64 Blöcken summiert: unabhängig von der
    /// Kernzahl, also bit-gleich bei jedem Aufruf. Mit `collectMouths`
    /// sammelt derselbe Durchlauf die Mündungen (`deltaMouthCells`):
    /// Landzelle ohne See (`hf − h ≤ poolDepth`) mit Meeres-Empfänger ab
    /// `deltaMinCells` Einzugsgebiet, je Block in Zellreihenfolge und in
    /// Blockfolge zusammengesetzt (dieselbe Liste wie sequenziell). Als
    /// eigener sequenzieller Scan kostete die Suche 0,29 ms je Schritt.
    private func deltaHeightSum(collectMouths: Bool = false) -> (sum: Double, land: Int) {
        let cnt = cfg.count, sea = cfg.sea, blocks = 64
        let depth = cfg.hydraulic.poolDepth
        let minA = cfg.deltaMinCells * cfg.cellSize * cfg.cellSize
        var sums = [Double](repeating: 0, count: blocks), lands = [Int](repeating: 0, count: blocks)
        var found = [[Int]](repeating: [], count: collectMouths ? blocks : 0)
        h.withUnsafeBufferPointer { hb in
        hf.withUnsafeBufferPointer { fb in
        area.withUnsafeBufferPointer { ab in
        receiver.withUnsafeBufferPointer { rb in
        sums.withUnsafeMutableBufferPointer { sb in
        lands.withUnsafeMutableBufferPointer { lb in
        found.withUnsafeMutableBufferPointer { out in
            let ph = hb.baseAddress!, ps = sb.baseAddress!, pl = lb.baseAddress!
            let phf = fb.baseAddress!, pa = ab.baseAddress!, prb = rb.baseAddress!
            // Leeres Feld: `baseAddress` ist dann nicht sicher nil — der
            // Schalter entscheidet, nicht der Zeiger.
            let pout = out.baseAddress
            DispatchQueue.concurrentPerform(iterations: blocks) { c in
                // Vier Teilsummen je Block (feste Reihenfolge): so
                // vektorisiert der Compiler die Schleife.
                var a0 = 0.0, a1 = 0.0, a2 = 0.0, a3 = 0.0, land = 0
                let lo = cnt * c / blocks, hi = cnt * (c + 1) / blocks
                var k = lo
                while k + 4 <= hi {
                    a0 += ph[k]; a1 += ph[k + 1]; a2 += ph[k + 2]; a3 += ph[k + 3]
                    land += (ph[k] > sea ? 1 : 0) + (ph[k + 1] > sea ? 1 : 0)
                        + (ph[k + 2] > sea ? 1 : 0) + (ph[k + 3] > sea ? 1 : 0)
                    k += 4
                }
                while k < hi { a0 += ph[k]; land += ph[k] > sea ? 1 : 0; k += 1 }
                ps[c] = (a0 + a1) + (a2 + a3); pl[c] = land
                guard collectMouths, let pout else { return }
                var local: [Int] = []
                for m in lo..<hi where pa[m] >= minA {
                    guard phf[m] > sea, phf[m] - ph[m] <= depth else { continue }
                    let r = Int(prb[m])
                    if r >= 0 && phf[r] <= sea { local.append(m) }
                }
                pout[c] = local
            }
        }}}}}}}
        if collectMouths {
            deltaMouthCells.removeAll(keepingCapacity: true)
            for list in found { deltaMouthCells.append(contentsOf: list) }
        }
        return (sums.reduce(0, +), lands.reduce(0, +))
    }

    /// Ein Mündungsstrahl des Delta-Baums (s. `deltaDeposit`), in Zellen.
    private struct DeltaJet {
        /// Anfang und Richtung (Einheitsvektor) des Strahls.
        var ox: Double, oz: Double, ux: Double, uz: Double
        /// Halbbreite der Rinne.
        var w: Double
        /// Barrenmitte, Inselradius quer und stromauf (Barre über dem Meer
        /// bis `r`, Fuß bei 2r) und Streckung stromab (`r · elong`).
        var cx: Double, cz: Double, r: Double, elong: Double
        /// Umriss-Rauschen: Phasen der 2. und 3. Harmonischen.
        var p2: Double, p3: Double
        /// Beginn der Rinne vor dem Strahl: bei Töchtern das Ende der
        /// Elternrinne vor der Barre, bei der Wurzel der Strahlanfang selbst.
        var lx: Double, lz: Double
        /// Anteil am Abfluss der Mündung (Fracht-Verteilung an die Töchter).
        var share: Double
        /// Index der beiden Töchter in der Strahl-Liste (−1 = keine).
        var left = -1, right = -1
    }

    /// Deterministisches Rauschen 0 ≤ ξ < 1 für die Delta-Geometrie (reine
    /// Ganzzahl-Arithmetik, plattformgleich): hängt am Mündungs-Block, an der
    /// Nummer des Strahls und an einem Kanal.
    @inline(__always) private static func deltaNoise(_ block: Int, _ jet: Int, _ salt: Int) -> Double {
        var v = UInt64(truncatingIfNeeded: block) &* 0x9E37_79B9_7F4A_7C15
        v ^= UInt64(truncatingIfNeeded: jet &+ 1) &* 0xC2B2_AE3D_27D4_EB4F
        v ^= UInt64(truncatingIfNeeded: salt &+ 7) &* 0x1656_67B1_9E37_79F9
        v ^= v >> 33; v = v &* 0xFF51_AFD7_ED55_8CCD
        v ^= v >> 33; v = v &* 0xC4CE_B9FE_1A85_EC53
        v ^= v >> 33
        return Double(v >> 11) / 9_007_199_254_740_992.0
    }

    /// Legt die Fracht der Flüsse als Delta vor ihrer Mündung ab.
    ///
    /// **Warum es den Pass gibt.** Die fluviale Erosion der Produktion ist
    /// detachment-begrenzt: `outletIncision` (Stream-Power) und `channelCarve`
    /// tragen Material ab, das danach NIRGENDS mehr liegt, und die Tropfen
    /// laden ihre Fracht am Eintritt ins tiefe Wasser bzw. beim Verdunsten ab.
    /// Gemessen (`RiverDelta.swift`, `testDeltaBudgetDiagnostic`, Seed 1337,
    /// Jahr 20.000, größte Mündung): das Einzugsgebiet verliert über die
    /// Stream-Power-Inzision 7,9 Zellen·Höhe je 1000 Jahre, ins Meer davor
    /// kommt fluvial −0,1…+0,1. Ohne Fracht an der Küste gibt es keinen
    /// Ablagerungskörper und damit kein Delta (Messreihe
    /// `docs/zielbild-measurements.md` § Delta).
    ///
    /// **Fracht.** Was `outletIncision` und `channelCarve` in diesem Schritt
    /// abtragen (Höhensumme davor minus danach, `deltaHeightSum`), je
    /// Landzelle gemittelt, mal dem Einzugsgebiet der Mündung: jede Mündung ab
    /// `deltaMinCells` bekommt den Abtrag ihres Einzugsgebiets bei mittlerer
    /// Abtragsrate, davon bleibt `deltaTrapFraction` liegen. Bis zur Messung
    /// der Kosten lief die echte D8-Summe des Abtrags je Zelle bis zur Mündung
    /// (ein See hielt seinen Anteil fest): 1,3–1,5 ms je Schritt, eigen wie in
    /// der Braid-Schleife mitgeführt (verstreute Zugriffe auf drei Felder je
    /// Landzelle, `braidPass` 2,2 → 3,6 ms), bei einem Ziel von 0,5 ms für das
    /// ganze Delta. Was dabei verloren geht: Relief und Klima des einzelnen
    /// Einzugsgebiets (ein steiles liefert so viel je Zelle wie ein flaches)
    /// und der Rückhalt in Seen; die Summe über alle Mündungen bleibt unter
    /// dem Abtrag der Insel. Gürtel und Tropfen zählen nicht
    /// mit: der Gürtel ist laterale Umlagerung, die Tropfen tragen ihre eigene
    /// Fracht.
    ///
    /// **Ablagerung: Mündungsbarren.** Ein Fluss, der ins Meer tritt, behält
    /// seinen Strahl einige Rinnenbreiten weit, verliert dann Tempo und legt
    /// eine Mündungsbarre ab; ist sie bis zum Wasserspiegel gewachsen, teilt
    /// sich der Strom links und rechts um sie, und jeder Arm baut vor sich die
    /// nächste Barre (Wright 1977; Edmonds & Slingerland 2007, JGR 112, F02034).
    /// Die Sim rechnet Wasser im Meer nicht (Meer = Senke), deshalb steht
    /// diese Hydrodynamik hier als Ablage-Regel: ein Baum aus Strahlen ab der
    /// Mündung, Rinnenbreite b aus dem Abfluss (dieselbe Kurve wie Band und
    /// Gürtel), Barre `deltaBarDistanceWidths`·b voraus, Insel mit Radius
    /// `deltaBarRadiusWidths`·b quer und `deltaBarElongation`-fach längs
    /// gestreckt (Mündungsbarren sind tropfenförmig in Fließrichtung), Scheitel
    /// `deltaTopset` über dem Meer, Fuß beim doppelten Radius gleich tief
    /// darunter. Erst wenn eine Barre voll ist, geht die Fracht nach
    /// Abflussanteil an ihre zwei Töchter (Winkel um ±`deltaBifurcationAngle`/2,
    /// Breite wie b ∝ √Q), bis `deltaGenerations` oder bis eine Tochter
    /// schmaler als `deltaMinHalfWidth` würde; der Rest geht ins offene Meer.
    /// Teilung, Winkel, Abstände und Umriss schwanken um `deltaJitter`
    /// (Rauschen am Mündungs-Block, also fest, solange die Mündung steht); der
    /// stärkere Ast läuft gerader. Vor jeder Barre baut ein Strahl seine
    /// Uferwälle (eine Halbbreite neben der Rinne, Krone `deltaTopset`) von der
    /// Wurzel seewärts — die subaerische Deltaebene entlang der Arme. Die
    /// Rinnen der Strahlen bleiben frei: sie sind die Distributäre, Meerwasser
    /// zwischen den Inseln. Inseln und Wälle sind echtes Gelände, die Rinnen
    /// echtes Wasser — der Render malt beides nur ab (Ozean-Ebene über
    /// `h ≤ sea`, Sand über `CoastMaterial`).
    ///
    /// dt: die Fracht ist die Änderung des Schritts (∝ dt), die Barren-
    /// Oberflächen sind geometrische Obergrenzen, die Füllreihenfolge ist fest
    /// — viele kleine Schritte laufen gegen dieselbe Form wie ein großer.
    private func deltaDeposit(yieldPerCell: Double) {
        let nn = n, sea = cfg.sea
        let cs = cfg.cellSize
        guard cs > 0, cs.isFinite, yieldPerCell > 0, yieldPerCell.isFinite else { return }
        let cellArea = cs * cs
        let mouths = deltaMouthCells.map { k -> (land: Int, load: Double) in
            (k, area[k] / cellArea * yieldPerCell * cfg.deltaTrapFraction)
        }
        guard !mouths.isEmpty else { return }
        // (2) Je Mündung den Strahl-Baum aufspannen und Barre für Barre füllen.
        // `visited` gehört dem Priority-Flood (er setzt es zu Schrittbeginn
        // selbst zurück und markiert am Ende jede Zelle), `pondSeen` der
        // Pfützen-Verlandung — beide hier nur geliehen und sauber hinterlassen.
        fill(&visited, false)
        fill(&pondSeen, false)
        let topset = cfg.deltaTopset
        let barDist = cfg.deltaBarDistanceWidths, barRad = cfg.deltaBarRadiusWidths
        let elong = max(1, cfg.deltaBarElongation)
        let half = cfg.deltaBifurcationAngle / 2, jitter = cfg.deltaJitter
        let wMin = cfg.deltaMinHalfWidth
        let generations = max(0, cfg.deltaGenerations)
        var jets: [DeltaJet] = []
        var corridor: [Int32] = []
        var touched: [Int32] = []
        var levee: [(k: Int32, t: Double, ceil: Double)] = []
        hf.withUnsafeBufferPointer { hfb in
        receiver.withUnsafeBufferPointer { rb in
        area.withUnsafeBufferPointer { ab in
        visited.withUnsafeMutableBufferPointer { vb in
        pondSeen.withUnsafeMutableBufferPointer { nb in
        withBed { bed in
            let phf = hfb.baseAddress!, prec = rb.baseAddress!, pa = ab.baseAddress!
            let pv = vb.baseAddress!, pno = nb.baseAddress!
            /// Rinne als Strecke mit Halbbreite `w` in die Sperrmaske.
            func markCorridor(_ ax: Double, _ az: Double, _ bx: Double, _ bz: Double, _ w: Double) {
                let dx = bx - ax, dz = bz - az
                let len2 = max(1e-12, dx * dx + dz * dz)
                let pad = w + 1
                let i0 = max(1, Int((min(ax, bx) - pad).rounded(.down)))
                let i1 = min(nn - 2, Int((max(ax, bx) + pad).rounded(.up)))
                let j0 = max(1, Int((min(az, bz) - pad).rounded(.down)))
                let j1 = min(nn - 2, Int((max(az, bz) + pad).rounded(.up)))
                if i0 > i1 || j0 > j1 { return }
                for j in j0...j1 {
                    for i in i0...i1 {
                        let px = Double(i) - ax, pz = Double(j) - az
                        let t = min(1, max(0, (px * dx + pz * dz) / len2))
                        let ex = px - t * dx, ez = pz - t * dz
                        if ex * ex + ez * ez <= w * w {
                            let k = j * nn + i
                            if !pno[k] { pno[k] = true; corridor.append(Int32(k)) }
                        }
                    }
                }
            }
            /// Uferwall-Zellen neben der Strecke a→b (Abstand w…2w zur Achse),
            /// mit Lauflänge `t0 + t` für die Füllreihenfolge und Kronenhöhe.
            func leveeCells(_ ax: Double, _ az: Double, _ bx: Double, _ bz: Double,
                            _ w: Double, _ t0: Double) {
                let dx = bx - ax, dz = bz - az
                let len2 = dx * dx + dz * dz
                if len2 < 1e-12 { return }
                let len = len2.squareRoot()
                let pad = 2 * w + 1
                let i0 = max(1, Int((min(ax, bx) - pad).rounded(.down)))
                let i1 = min(nn - 2, Int((max(ax, bx) + pad).rounded(.up)))
                let j0 = max(1, Int((min(az, bz) - pad).rounded(.down)))
                let j1 = min(nn - 2, Int((max(az, bz) + pad).rounded(.up)))
                if i0 > i1 || j0 > j1 { return }
                for j in j0...j1 {
                    for i in i0...i1 {
                        let px = Double(i) - ax, pz = Double(j) - az
                        let along = (px * dx + pz * dz) / len2
                        if along < 0 || along > 1 { continue }
                        let ex = px - along * dx, ez = pz - along * dz
                        let e = (ex * ex + ez * ez).squareRoot()
                        if e <= w || e > 2 * w { continue }
                        levee.append((k: Int32(j * nn + i), t: t0 + along * len,
                                      ceil: sea + topset * (1 - (e - w) / w)))
                    }
                }
            }
            for mouth in mouths {
                let k0 = mouth.land
                let mi = k0 % nn, mj = k0 / nn
                guard mi >= 2, mi < nn - 2, mj >= 2, mj < nn - 2 else { continue }
                // Richtung: Lauf (8 Zellen stromauf → Meereszelle) und
                // Küstennormale (Meeresschwerpunkt im Fenster ±8) zu gleichen
                // Teilen. Der Lauf allein springt mit der D8-Kette um 45°, und
                // die Mündung selbst wandert je 1000 Jahre bei zwei Dritteln
                // der großen Mündungen um 0–2 Zellen (Seed 1337, Jahr
                // 10.000–20.000): jeder Schritt hätte einen anderen Baum
                // gepflanzt.
                var up = k0
                for _ in 0..<8 {
                    var best = -1, bestA = 0.0
                    let ui = up % nn, uj = up / nn
                    for dj in -1...1 { for di in -1...1 where di != 0 || dj != 0 {
                        let ii = ui + di, jj = uj + dj
                        if ii < 0 || ii >= nn || jj < 0 || jj >= nn { continue }
                        let c = jj * nn + ii
                        if Int(prec[c]) == up && pa[c] > bestA { bestA = pa[c]; best = c }
                    } }
                    if best < 0 { break }
                    up = best
                }
                let r0 = Int(prec[k0])
                var rx = Double(r0 % nn - up % nn), rz = Double(r0 / nn - up / nn)
                let rl = (rx * rx + rz * rz).squareRoot()
                guard rl > 1e-9 else { continue }
                rx /= rl; rz /= rl
                // Flaches Delta-Land (bis zum doppelten Scheitel) zählt als
                // Meer: sonst drehte das wachsende Delta seinen eigenen Baum,
                // und dieselbe Fracht in anderen Schritten gäbe eine andere
                // Form (Wächter `testSameLoadInFewerStepsBuildsTheSameDelta`).
                var sx = 0.0, sz = 0.0
                let win = 8, low = sea + 2 * topset
                for dj in -win...win { for di in -win...win {
                    let ii = mi + di, jj = mj + dj
                    if ii < 0 || ii >= nn || jj < 0 || jj >= nn { continue }
                    let c = jj * nn + ii
                    if phf[c] <= sea || bed.h[c] <= low { sx += Double(di); sz += Double(dj) }
                } }
                let sl = (sx * sx + sz * sz).squareRoot()
                if sl > 1e-9 { sx /= sl; sz /= sl } else { sx = rx; sz = rz }
                var ux = rx + sx, uz = rz + sz
                let ul = (ux * ux + uz * uz).squareRoot()
                if ul > 1e-9 { ux /= ul; uz /= ul } else { ux = sx; uz = sz }
                // Rauschen am 8×8-Block der Mündung: wandert die Mündung um
                // ein, zwei Zellen, bleibt der Baum derselbe.
                let block = (mj >> 3) * nn + (mi >> 3)
                func noise(_ jet: Int, _ salt: Int) -> Double {
                    2 * Terrain.deltaNoise(block, jet, salt) - 1
                }
                // Strahl-Baum (Geometrie fest, Generation für Generation).
                jets.removeAll(keepingCapacity: true)
                let w0 = WaterRender.ribbonHalfWidthCells(dischargeCells: pa[k0] / cellArea,
                                                          referenceCells: cfg.renderMinCells)
                func makeJet(_ index: Int, _ ox: Double, _ oz: Double, _ dx: Double, _ dz: Double,
                             _ w: Double, share: Double, from lx: Double, _ lz: Double) -> DeltaJet {
                    let b = 2 * w
                    let dist = barDist * b * (1 + jitter * noise(index, 10))
                    let r = barRad * b * (1 + 0.5 * jitter * noise(index, 11))
                    let tau = 2 * Double.pi
                    return DeltaJet(ox: ox, oz: oz, ux: dx, uz: dz, w: w,
                                    cx: ox + dist * dx, cz: oz + dist * dz, r: r, elong: elong,
                                    p2: tau * Terrain.deltaNoise(block, index, 12),
                                    p3: tau * Terrain.deltaNoise(block, index, 13),
                                    lx: lx, lz: lz, share: share)
                }
                jets.append(makeJet(0, Double(mi), Double(mj), ux, uz, w0, share: 1,
                                    from: Double(mi), Double(mj)))
                var genStart = 0
                for _ in 0..<generations {
                    let genEnd = jets.count
                    for p in genStart..<genEnd {
                        let pj = jets[p]
                        // Zu schmal zum Teilen: der Strahl endet mit seiner Barre.
                        if pj.w * 0.5.squareRoot() < wMin * (1 - 1e-9) { continue }
                        // Abflussanteil der linken Tochter um ½ ± jitter/2.
                        let f = 0.5 + 0.5 * jitter * noise(p, 1)
                        for side in [-1.0, 1.0] {
                            let s = side < 0 ? f : 1 - f
                            let wd = max(wMin, pj.w * s.squareRoot())
                            // Flanke der Elternbarre; der stärkere Ast läuft
                            // gerader (bei s = ½ genau der halbe Winkel).
                            let ang = half * 2 * (1 - s) * (1 + 0.5 * jitter * noise(p, side < 0 ? 2 : 3))
                            let ca = cos(ang), sa = sin(ang) * side
                            let px = -pj.uz * side, pz = pj.ux * side
                            let fx = pj.cx + (pj.r + wd) * px, fz = pj.cz + (pj.r + wd) * pz
                            let dx = pj.ux * ca - pj.uz * sa
                            let dz = pj.uz * ca + pj.ux * sa
                            let child = makeJet(jets.count, fx, fz, dx, dz, wd, share: pj.share * s,
                                                from: pj.cx - (pj.r + pj.w) * pj.ux,
                                                pj.cz - (pj.r + pj.w) * pj.uz)
                            let ci = Int(child.cx.rounded()), cj = Int(child.cz.rounded())
                            if ci < 2 || ci > nn - 3 || cj < 2 || cj > nn - 3 { continue }
                            // Barre läge an Land; flaches Delta-Land (bis zum
                            // doppelten Scheitel) zählt nicht, über die eigenen
                            // Inseln wächst der Baum weiter.
                            let cc = cj * nn + ci
                            if phf[cc] > sea && bed.h[cc] > sea + 2 * topset { continue }
                            jets.append(child)
                            if side < 0 { jets[p].left = jets.count - 1 } else { jets[p].right = jets.count - 1 }
                        }
                    }
                    genStart = genEnd
                }
                // Rinnen sperren: Strahl bis vor die Barre, von dort zu den
                // Flanken (Ansatz der Töchter).
                for j in jets {
                    let sx = j.cx - (j.r + j.w) * j.ux, sz = j.cz - (j.r + j.w) * j.uz
                    markCorridor(j.lx, j.lz, j.ox, j.oz, j.w)
                    markCorridor(j.ox, j.oz, sx, sz, j.w)
                }
                // Abgeschnürte Lagunen im Bereich des Baums verlanden zuerst
                // (bis 0,3 Scheitel über das Meer): sonst schlossen Barren und
                // Wälle Meer ein, das Raster malte es als dunklen See (Seed
                // 1337 Jahr 20.000: 160 Zellen an drei großen Mündungen).
                var load = mouth.load
                var reachTree = 0.0
                for j in jets {
                    let dx = j.cx - Double(mi), dz = j.cz - Double(mj)
                    reachTree = max(reachTree, (dx * dx + dz * dz).squareRoot() + 2 * j.r * j.elong)
                }
                let rt = Int(reachTree.rounded(.up)), marsh = sea + 0.3 * topset
                for jj in max(1, mj - rt)...min(nn - 2, mj + rt) where load > 0 {
                    for ii in max(1, mi - rt)...min(nn - 2, mi + rt) where load > 0 {
                        let c = jj * nn + ii
                        guard phf[c] > sea, bed.h[c] < sea else { continue }
                        let dx = Double(ii - mi), dz = Double(jj - mj)
                        if dx * dx + dz * dz > reachTree * reachTree { continue }
                        load -= depositCell(c, min(marsh - bed.h[c], load), bed)
                    }
                }
                // Barren füllen: Fracht an die Wurzel, volle Barre gibt weiter.
                var pending: [(jet: Int, load: Double)] = [(0, load)]
                var head = 0
                while head < pending.count {
                    let (ji, load) = pending[head]; head += 1
                    let j = jets[ji]
                    var remaining = load
                    // Uferwälle zuerst, von der Wurzel des Strahls seewärts:
                    // ein Streifen von einer Halbbreite neben der Rinne, Krone
                    // `deltaTopset` an der Rinnenkante, außen auf den Spiegel.
                    let sx = j.cx - (j.r + j.w) * j.ux, sz = j.cz - (j.r + j.w) * j.uz
                    levee.removeAll(keepingCapacity: true)
                    leveeCells(j.lx, j.lz, j.ox, j.oz, j.w, 0)
                    let lead = ((j.ox - j.lx) * (j.ox - j.lx) + (j.oz - j.lz) * (j.oz - j.lz)).squareRoot()
                    leveeCells(j.ox, j.oz, sx, sz, j.w, lead)
                    levee.sort { $0.t < $1.t || ($0.t == $1.t && $0.k < $1.k) }
                    // Gefüllt wird bis zur Krone, auch über eigener Schüttung
                    // früherer Schritte, die schon Land ist: sonst stand eine
                    // halb gefüllte Zelle nach einem kleinen Schritt still, und
                    // dieselbe Fracht in kleineren Schritten legte weniger ab.
                    // Eine Rinne bleibt frei, solange sie zum Meer offen ist; ist
                    // sie abgeschnürt (Lagune, `hf > sea`), verlandet sie wie
                    // der Rest: das Raster malte sie sonst als dunklen See
                    // neben dem Türkis des Meers.
                    for c in levee where remaining > 0 {
                        let k = Int(c.k)
                        if (pno[k] && phf[k] <= sea) || bed.h[k] >= c.ceil { continue }
                        let room = c.ceil - bed.h[k]
                        if room > 0 { remaining -= depositCell(k, min(room, remaining), bed) }
                    }
                    if remaining <= 0 { break }
                    // Barre: Tropfen in Fließrichtung, Umriss mit 2. und 3.
                    // Harmonischer gebrochen. `key` = normierter Abstand² im
                    // gestreckten, verrauschten Maß, in Einheiten von r.
                    // sin(mθ + p) über Mehrfachwinkel aus cos θ / sin θ statt
                    // atan2 und sin je Zelle (gleiche Werte bis auf Rundung,
                    // ein Drittel der Kosten des Passes).
                    let wobble = 0.5 * jitter
                    let c2 = cos(j.p2), s2 = sin(j.p2), c3 = cos(j.p3), s3 = sin(j.p3)
                    func barKey(_ x: Int, _ z: Int) -> Double {
                        let ex = Double(x) - j.cx, ez = Double(z) - j.cz
                        let along = ex * j.ux + ez * j.uz, across = -ex * j.uz + ez * j.ux
                        // Tropfen: stromauf rund (Radius r), stromab um
                        // `elong` gestreckt — die Barre reicht nicht in die
                        // Mündungsrinne zurück.
                        let a = along > 0 ? along / j.elong : along
                        let d2 = a * a + across * across
                        if d2 < 1e-12 { return 0 }
                        let rl = (along * along + across * across).squareRoot()
                        let co = along / rl, si = across / rl
                        let sin2 = 2 * si * co, cos2 = co * co - si * si
                        let sin3 = si * (3 - 4 * si * si), cos3 = co * (4 * co * co - 3)
                        let rr = 1 + wobble * (0.6 * (sin2 * c2 + cos2 * s2) + 0.4 * (sin3 * c3 + cos3 * s3))
                        return d2 / (rr * rr)
                    }
                    let toe2 = 4 * j.r * j.r
                    let ci = Int(j.cx.rounded()), cj = Int(j.cz.rounded())
                    guard ci >= 1, ci < nn - 1, cj >= 1, cj < nn - 1 else { continue }
                    touched.removeAll(keepingCapacity: true)
                    heap.removeAll()
                    heap.withRaw { ref in
                        let c0 = cj * nn + ci
                        pv[c0] = true; touched.append(Int32(c0))
                        ref.push(key: barKey(ci, cj), cell: Int32(c0), col: 0)
                        while ref.size > 0 && remaining > 0 {
                            let e = ref.pop()
                            let c = Int(e.cell)
                            if !pno[c] || phf[c] > sea {
                                let room = sea + topset * (1 - e.key.squareRoot() / j.r) - bed.h[c]
                                if room > 0 {
                                    let add = min(room, remaining)
                                    remaining -= depositCell(c, add, bed)
                                    if add < room { break }
                                }
                            }
                            let i = c % nn, jj = c / nn
                            for dj in -1...1 {
                                for di in -1...1 where di != 0 || dj != 0 {
                                    let ni = i + di, nj = jj + dj
                                    if ni < 1 || ni >= nn - 1 || nj < 1 || nj >= nn - 1 { continue }
                                    let nbk = nj * nn + ni
                                    // Durch Meer und flaches Land unter dem
                                    // Scheitel (eigene Schüttung, Lagunen),
                                    // nie über höheres Land.
                                    if pv[nbk] || bed.h[nbk] >= sea + topset { continue }
                                    let d2 = barKey(ni, nj)
                                    if d2 > toe2 { continue }
                                    pv[nbk] = true; touched.append(Int32(nbk))
                                    ref.push(key: d2, cell: Int32(nbk), col: 0)
                                }
                            }
                        }
                    }
                    for c in touched { pv[Int(c)] = false }
                    // Volle Barre: Rest nach Abflussanteil an die Töchter.
                    if remaining > 0 {
                        let kids = [j.left, j.right].filter { $0 >= 0 }
                        let total = kids.reduce(0.0) { $0 + jets[$1].share }
                        if total > 0 {
                            for c in kids { pending.append((c, remaining * jets[c].share / total)) }
                        }
                    }
                }
                for c in corridor { pno[Int(c)] = false }
                corridor.removeAll(keepingCapacity: true)
            }
        }}}}}}
        heap.removeAll()
    }

    // MARK: - Tektonik / Isostasie

    /// `gatedAmount` ist die bereits über den Schritt INTEGRIERTE Hebung (Höhen-
    /// einheiten bei `upliftBase == 1`) der abklingenden Tektonik bzw. des
    /// Servo-Bodens; `cfg.upliftPer100y` ist die Alt-Konstante (Produktion 0, nur
    /// noch von Testkonfigs gesetzt) und wirkt weiter über das VOLLE Feld.
    private func applyUplift(dt: Double, gatedAmount us: Double = 0) {
        let uf = cfg.upliftPer100y * dt / 100
        // Die abklingende Hebung wirkt NUR über den POSITIVEN Teil des Tektonik-
        // Felds und NUR auf LAND: sie soll Grate tragen. Mit vollem upliftBase
        // (Täler negativ) SENKTE sie die Täler unter den Meeresspiegel (halbe
        // Insel geflutet); ohne Land-Gate hob sie den SCHELF in Tektonik-Ringen
        // über die Wasserlinie (grüne Kratersäume vor der Küste — beides gemessen).
        if uf == 0 && us <= 0 { return }
        // PERF (Issue #43): Roh-Puffer + zeilenweise Parallelität. Der Pass ist
        // rein per-Zelle (jede Zelle liest und schreibt nur ihren eigenen Index)
        // → bit-identisch zur sequenziellen Schleife, s. `parallel`. Als
        // Klassen-Property-Schleife kostete er 27 ms/Schritt (7 %), fast alles
        // Exclusivity-Enforcement auf `h`/`rock`/`upliftBase`. Arithmetik und
        // Reihenfolge der Operationen unverändert.
        let sea = cfg.sea, floor = cfg.floor
        let isoHigh = cfg.isoHighClamp, isoLow = cfg.isoLowRange
        h.withUnsafeMutableBufferPointer { hb in
        rock.withUnsafeMutableBufferPointer { rb in
        upliftBase.withUnsafeBufferPointer { ub in
            let ph = hb.baseAddress!, prock = rb.baseAddress!, pu = ub.baseAddress!
            parallel(cfg.count) { lo, hi in
                for k in lo..<hi {
                    let gated = (us > 0 && ph[k] > sea) ? max(0, pu[k]) * us : 0
                    let du0 = pu[k] * uf + gated
                    var du: Double
                    if du0 > 0 {
                        du = du0 * max(0, 1 - ph[k] / isoHigh)
                    } else {
                        du = du0 * min(1, (ph[k] - floor) / isoLow)
                    }
                    if ph[k] + du < floor { du = floor - ph[k] }
                    prock[k] += du
                    ph[k] += du
                }
            }
        }}}
    }

    // MARK: - Sculpting (Spieler-Eingriff)

    /// Zieht nach einem Geländeeingriff alles nach, was UNMITTELBAR an der Höhe
    /// hängt — die feste Reihenfolge dahinter (Issue #93: sie stand bis dahin in
    /// der GDExtension, also bei einem Aufrufer statt beim Besitzer):
    ///
    /// 1. `computeFlow` — Entwässerung neu, damit Flüsse dem Strich folgen.
    /// 2. `snapWaterLevel` — der Darstellungs-Seespiegel snappt mit:
    ///    Spieler-Feedback soll instantan sein, nur die Sim-Dynamik (Plug/Breach
    ///    am Auslass) ist träge.
    /// 3. `updateClimate(dt: 0)` — die Temperatur hängt direkt an der Höhe und
    ///    muss im selben Frame mitwandern. `dt = 0` lässt die Schnee-BILANZ
    ///    exakt unverändert (e⁰ = 1): die ist Zustand und darf an der Sim-Zeit
    ///    hängen, nicht am Pinsel.
    /// 4. `updateHeightBands` — ein Strich verschiebt die Landhöhen-Verteilung,
    ///    und die Färbung liest die Bänder im selben Frame.
    ///
    /// Kein Zeitschritt: `years` bleibt stehen. Wer einen fünften Pass anhängt,
    /// tut es hier — nicht beim Aufrufer (Wächter:
    /// `SimCoreTests/TerrainAPITests.swift`).
    public func recomputeFlowAfterEdit() {
        computeFlow()
        snapWaterLevel()
        updateClimate(dt: 0)
        updateHeightBands()
    }

    /// Hebt (`dir` > 0) bzw. senkt (`dir` < 0) das Terrain in einem weichen Pinsel
    /// um das Gitterzentrum (`gx`, `gz`), Radius in Welteinheiten. Koppelt in die
    /// Tektonik (angehobene Zonen werden Hebungszonen), damit Eingriffe langfristig
    /// erhalten bleiben statt von der Erosion ausradiert zu werden.
    /// Null-Richtung (`dir == 0`) oder Null-Stärke (`strength == 0`) führen zum sofortigen No-op.
    public func sculpt(gx: Double, gz: Double, radiusWorld: Double, dir: Double,
                       strength: Double = 1.0) {
        guard dir.isFinite && strength.isFinite,
              abs(dir) < 1e9, abs(strength) < 1e9,
              dir != 0, strength != 0 else { return }
        forEachBrushCell(gx: gx, gz: gz, radiusWorld: radiusWorld) { k, w in
            // Kopplung in die Tektonik: angehobene Zonen werden Hebungszonen,
            // damit Eingriffe langfristig erhalten bleiben statt wegzuerodieren.
            // Nur, wo der Hieb das Bett bewegt hat — unter Eis bleibt er
            // wirkungslos (Issue #96).
            if applyDelta(k, dir * 0.006 * strength * w, asRock: true) {
                upliftBase[k] = min(2.0, max(-2.0, upliftBase[k] + dir * 0.006 * strength * w * 1.5))
            }
        }
    }

    /// Glättet das Terrain im Pinsel Richtung 3×3-Mittel (aus einem Schnappschuss,
    /// damit die Zellreihenfolge das Ergebnis nicht verfälscht).
    /// Negativer oder Null-`strength` sowie nicht-positiver Radius führen zum sofortigen
    /// No-op (keine Zell-Iteration).
    public func smooth(gx: Double, gz: Double, radiusWorld: Double, strength: Double = 1.0) {
        guard strength.isFinite, abs(strength) < 1e9 else { return }
        let pull = min(1.0, max(0.0, 0.30 * strength))
        guard pull > 0 else { return }
        guard radiusWorld.isFinite, radiusWorld > 0,
              radiusWorld <= Double(n) * cfg.cellSize else { return }
        let snap = h
        forEachBrushCell(gx: gx, gz: gz, radiusWorld: radiusWorld) { k, w in
            let i = k % n, j = k / n
            var s = 0.0, c = 0.0
            for dj in max(0, j - 1)...min(n - 1, j + 1) {
                for di in max(0, i - 1)...min(n - 1, i + 1) {
                    s += snap[dj * n + di]; c += 1
                }
            }
            applyDelta(k, (s / c - snap[k]) * pull * w, asRock: false)
        }
    }

    /// Zieht das Terrain im Pinsel Richtung Zielhöhe (Plateau/Terrasse) —
    /// die Zielhöhe sampelt der Aufrufer beim Strich-Beginn.
    /// Negativer oder Null-`strength` führt zum sofortigen No-op (keine Zell-Iteration).
    public func flatten(gx: Double, gz: Double, radiusWorld: Double,
                        targetHeight: Double, strength: Double = 1.0) {
        guard targetHeight.isFinite && strength.isFinite,
              abs(targetHeight) < 1e9, abs(strength) < 1e9 else { return }
        let pull = min(1.0, max(0.0, 0.18 * strength))
        guard pull > 0 else { return }
        let target = min(1.4, max(cfg.floor, targetHeight))
        forEachBrushCell(gx: gx, gz: gz, radiusWorld: radiusWorld) { k, w in
            applyDelta(k, (target - h[k]) * pull * w, asRock: false)
        }
    }

    /// Prägt fraktales Rauschen ins Terrain (zerklüftete Details). Nutzt das
    /// terrain-eigene Noise-Feld → wiederholte Striche vertiefen dasselbe Muster.
    /// Null-Stärke (`strength == 0`) führt zum sofortigen No-op.
    public func roughen(gx: Double, gz: Double, radiusWorld: Double, strength: Double = 1.0) {
        guard strength.isFinite, abs(strength) < 1e9, strength != 0 else { return }
        forEachBrushCell(gx: gx, gz: gz, radiusWorld: radiusWorld) { k, w in
            let i = k % n, j = k / n
            let nz = noise.fbm01(Double(i) * 0.11, Double(j) * 0.11, octaves: 4) * 2 - 1
            applyDelta(k, nz * 0.005 * strength * w, asRock: true)
        }
    }

    /// Spitzhacke: schmaler, spitzer Hieb, der schnell durch Sediment UND Fels
    /// schlägt — so lassen sich Flüsse gezielt umleiten (Durchbruchstal).
    /// BEWUSST ohne Tektonik-Kopplung (anders als sculpt): nach dem Hieb übernimmt
    /// die Natur — ein gekaperter Fluss hält sich die Rinne per Erosion selbst
    /// offen, und übertiefte Löcher füllen sich über die Zeit mit Sediment.
    /// Der Radius ist auf wenige Zellen GEDECKELT, unabhängig vom Pinsel-Slider:
    /// mit dessen Standardbreite (~64 Zellen) riss der „spitze Hieb" in unter
    /// einer Sekunde einen Krater bis unters Meer, statt eine Kerbe zu schlagen.
    /// Negativer oder Null-`strength` (`strength <= 0`) führt zum sofortigen No-op (keine Zell-Iteration).
    public func pickaxe(gx: Double, gz: Double, radiusWorld: Double, strength: Double = 1.0) {
        guard radiusWorld.isFinite && strength.isFinite,
              abs(strength) < 1e9, strength > 0,
              radiusWorld <= Double(n) * cfg.cellSize else { return }
        let radius = min(radiusWorld, Terrain.pickaxeMaxCells * cfg.cellSize)
        forEachBrushCell(gx: gx, gz: gz, radiusWorld: radius) { k, w in
            let spike = w * w // (1-d²)⁴ — deutlich spitzer als der weiche Pinsel
            applyDelta(k, -0.02 * strength * spike, asRock: true)
        }
    }

    /// Maximale Spitzhacken-Breite in Zellen (auch fürs Ring-Visual im Frontend).
    public static let pickaxeMaxCells = 3.0

    /// Gemeinsame Pinsel-Iteration: ruft `body(k, w)` für jede Zelle im Pinsel
    /// mit weichem Abfall-Gewicht w ∈ (0..1] auf.
    private func forEachBrushCell(gx: Double, gz: Double, radiusWorld: Double,
                                  _ body: (Int, Double) -> Void) {
        // cellSize 0 (z. B. 1×1-Gitter): sonst 0/0 = NaN und Int(NaN) bricht ab.
        guard gx.isFinite && gz.isFinite && radiusWorld.isFinite,
              abs(gx) < 1e9, abs(gz) < 1e9, cfg.cellSize > 0 else { return }
        let rCells = radiusWorld / cfg.cellSize
        if rCells <= 0 || rCells > Double(n) { return }
        let r = Int(rCells.rounded(.up))
        let cx = Int(gx.rounded()), cz = Int(gz.rounded())
        let jLo = max(0, cz - r), jHi = min(n - 1, cz + r)
        let iLo = max(0, cx - r), iHi = min(n - 1, cx + r)
        if jLo > jHi || iLo > iHi { return }
        for j in jLo...jHi {
            for i in iLo...iHi {
                let d = (Double(i) - gx).magnitudeHypot(Double(j) - gz) / rCells
                if d > 1 { continue }
                body(idx(i, j), (1 - d * d) * (1 - d * d))
            }
        }
    }

    /// Höhenänderung mit Fels/Sediment-Buchhaltung (hält h = rock + sed):
    /// Absenken räumt erst Sediment, dann Fels; Anheben schiebt Fels hoch
    /// (`asRock`) oder lagert lockeres Sediment ab (Glätten/Einebnen).
    /// Seit Issue #96 schreibt JEDE dieser Bewegungen über den Bett-Funnel
    /// (`erodeCell`/`depositCell`/`raiseRockCell`) — Zerlegung und
    /// Gletscher-Gate stehen dort, einmal für alle Schreiber. Der Pinsel ist
    /// bewusst KEINE Ausnahme: ein Hieb auf vergletschertem Grund bleibt
    /// wirkungslos (unter dem Eis gehört das Tal dem Gletscher).
    ///
    /// Rückgabe: ob die Zelle für den Funnel OFFEN war — `true` auch für den
    /// Deckel-Fall `dh == 0` (nichts zu bewegen heißt nicht gesperrt). Nur
    /// dann bucht `registerDisturbance`, und nur dann koppelt `sculpt` in die
    /// Tektonik: eine Störung ohne Bett-Änderung wäre ein Budget ohne
    /// Gegenstück, das beim Abschalten der Störung trotzdem oder nie
    /// einträte.
    @discardableResult
    private func applyDelta(_ k: Int, _ dhRaw: Double, asRock: Bool) -> Bool {
        guard dhRaw.isFinite, abs(dhRaw) < 1e9, dhRaw != 0 else { return false }
        let dh = min(1.4, max(cfg.floor, h[k] + dhRaw)) - h[k]
        let moved: Double
        if dh >= 0 {
            moved = asRock ? raiseRockCell(k, dh) : depositCell(k, dh)
        } else {
            moved = erodeCell(k, -dh)
        }
        // Offen = der Funnel hat bewegt, oder es gab nichts zu bewegen.
        // Gesperrt heißt: kein Bett-Umzug und keine Störungs-Buchung.
        let open = moved > 0 || dh == 0
        if open {
            registerDisturbance(k, dh, settles: !asRock)
        }
        return open
    }

    // MARK: - Störung & Regeneration (Issue #26)

    /// Bucht die Höhenänderung `dh` (mit Vorzeichen) als **Störung** der Zelle
    /// `k`: nimmt ihr sofort den Zustand, der an der ALTEN Topografie hing, und
    /// legt das Regenerations-Budget an, das die kommenden Jahrhunderte
    /// eintragen.
    ///
    /// Warum hier und nicht je Werkzeug: `applyDelta` ist der gemeinsame
    /// Trichter aller Pinsel (Anheben, Absenken, Glätten, Einebnen, Aufrauen,
    /// Spitzhacke) — die Doktrin „ein Geländeeingriff stört den gekoppelten
    /// Zustand" gilt für jeden davon, nicht nur fürs Einebnen.
    ///
    /// Zurückgesetzt wird ANTEILIG (`raw`), nicht hart: ein zaghafter Strich
    /// lichtet den Wald, ein Bagger-Zug räumt ihn ab. `vegClass` und das
    /// Kronendach im Frontend (Waldmaske, Issue #152) leiten sich aus `veg` ab
    /// und folgen von selbst; Mäanderlinien/Altarme hängen an Geometrie und werden erst im
    /// Schritt darauf gesäubert (`regenerateDisturbed`), weil das ein Sweep
    /// über die Linien ist und kein Per-Zell-Effekt.
    ///
    /// Das Budget hat zwei Anteile:
    /// * **Setzung/Rebound** `−dh·disturbanceSettle`: ein Teil des bewegten
    ///   Materials kommt zurück. Frische Auffüllung setzt sich (differentielle
    ///   Kompaktion — über begrabenen Hochlagen weniger als über begrabenen
    ///   Tälern, weshalb die alte Struktur gedämpft wieder durchschlägt),
    ///   entlastetes Gelände hebt sich. Genau dieser Anteil bringt die
    ///   Entwässerung wieder in Gang: die begrabenen Täler werden wieder zu
    ///   Tiefenlinien, statt dass die Fläche auf einen Zufallsgradienten warten
    ///   muss. Er ist STRUKTURTREU (folgt der Eingriffs-Geometrie), nicht
    ///   global — das Werkzeug bleibt wirksam, es bleibt nur nicht steril.
    /// * **Mikro-Relief** `raw·disturbanceReliefAmp·fBm`: der Symmetriebruch
    ///   für Flächen, die schon vorher eben waren (dort ist die Setzung
    ///   uniform und erzeugt kein Gefälle).
    ///
    /// Beide Anteile landen im gleichen Budget und werden über das Abklingfenster
    /// verteilt — der SOFORTeffekt des Werkzeugs bleibt exakt so, wie der Spieler
    /// ihn gezogen hat (Wächter `testFlattenIsExactlyFlatImmediately`).
    @inline(__always) private func registerDisturbance(_ k: Int, _ dh: Double, settles: Bool) {
        guard cfg.disturbanceEnabled, cfg.disturbanceFullChange > 0, dh != 0 else { return }
        let raw = min(1, abs(dh) / cfg.disturbanceFullChange)
        // Nur der Zuwachs, der den Störungsgrad WIRKLICH hebt, darf Mikro-Relief
        // nachlegen — sonst summierten 200 Striche auf derselben Zelle das
        // 200-fache Rauschen auf.
        let old = disturb[k]
        let effInc = min(1, old + raw) - old
        disturb[k] = old + effInc
        disturbActive = true
        if settles { regenPending[k] -= dh * cfg.disturbanceSettle }
        if effInc > 0 && cfg.disturbanceReliefAmp > 0 {
            let i = k % n, j = k / n
            let f = cfg.disturbanceReliefFreq
            // Ortsfestes fBm (terrain-eigener Seed → deterministisch und über
            // wiederholte Eingriffe kohärent: derselbe Fleck bekommt dieselbe
            // Rille, statt bei jedem Strich neu zu würfeln). Versatz 137/91
            // gegen das Aufrau-Werkzeug, damit beide nicht dasselbe Muster prägen.
            let u = noise.fbm01(Double(i) * f + 137, Double(j) * f + 91, octaves: 5) * 2 - 1
            regenPending[k] += effInc * cfg.disturbanceReliefAmp * u
        }
        // Übrig bleibt vom alten Zustand exakt der Anteil `1 − Störungsgrad`
        // (die Quotienten-Form teleskopiert über beliebig viele Striche: ein
        // zaghafter Strich lichtet den Wald, ein Bagger-Zug räumt ihn ab).
        let keep = disturb[k] >= 1 ? 0 : (1 - disturb[k]) / (1 - old)
        veg[k] *= keep          // frisch bewegter Boden trägt keinen alten Bestand
        streamRate[k] *= keep   // …und kein Gedächtnis an den alten Lauf
        streamMap[k] *= keep
    }

    /// Regenerations-Pass für gestörte Zellen — der Kern von Issue #26.
    ///
    /// Drei Wirkungen, alle **räumlich** auf `disturb > 0` und **zeitlich** auf
    /// das Abklingfenster `disturbanceRecoveryYears` begrenzt:
    ///
    /// 1. **Gelände**: je Schritt wird der Anteil `1 − e^(−dt/τ)` des offenen
    ///    Budgets (`regenPending`: Setzung/Rebound + Mikro-Relief) eingetragen
    ///    und abgezogen. Damit teleskopiert die Summe über beliebig viele
    ///    Teilschritte exakt zum Ergebnis EINES Sprungs (Framerate-Invariante,
    ///    Wächter `testRegenerationIsFramerateIndependent`), und die exakt
    ///    flache Platte bekommt den Gradienten, den `outletIncision`
    ///    (überspringt gefällelose Zellen) und die Tropfen (enden bei
    ///    verschwindendem Gradienten) zum Arbeiten brauchen.
    /// 2. **Mäander-/Altarm-Zustand** stark gestörter Zellen fällt weg; die
    ///    Läufe werden aus der frischen Entwässerung neu getrasst.
    /// 3. **Vegetation**: das Ziel wird in `updateVegetation` mit
    ///    `1 − disturbanceVegSuppress·disturb` skaliert (Rohboden ist kein
    ///    Standort) — dort, nicht hier, weil es ein Ziel-Effekt ist.
    ///
    /// Dazu kommt ein vierter Effekt, der schlicht ein ausgesetzter Aufräum-Pass
    /// ist, solange die Baustelle offen ist: die Pfützen-Verlandung
    /// (`fillShallowPonds`) schüttet das frische Mikro-Relief nicht wieder zu.
    ///
    /// Bewusst KEIN globaler Servo-Eingriff: die Alterung aus Issue #13 bleibt
    /// unangetastet (`reliefServoPer100y` unverändert).
    private func regenerateDisturbed(dt: Double) {
        guard cfg.disturbanceEnabled, disturbActive, dt > 0 else { return }
        let tau = max(1e-9, cfg.disturbanceRecoveryYears)
        let f = Terrain.relaxFraction(dt: dt, tau: tau) // Anteil des Budgets, der diesen Schritt fällig ist
        var maxLeft = 0.0
        for k in 0..<cfg.count {
            let d = disturb[k]
            if d <= 0 { continue }
            let spend = regenPending[k] * f
            if spend != 0 {
                applyRegenDelta(k, spend)
                regenPending[k] -= spend
            }
            let left = d - d * f
            disturb[k] = left
            maxLeft = max(maxLeft, left)
        }
        if cfg.disturbanceMeanderDrop > 0 { dropDisturbedMeanderState() }
        // Ausgeklungen (< 1 % Reststörung ≈ 4.6 τ) → Pfad abschalten. Der Rest
        // des Budgets wird dabei VOLLSTÄNDIG eingetragen statt verworfen: so ist
        // die insgesamt eingetragene Geländeänderung exakt das gebuchte Budget,
        // egal wann die Abschaltung in einen Zeitschritt fällt.
        if maxLeft < 0.01 {
            for k in 0..<cfg.count {
                if regenPending[k] != 0 { applyRegenDelta(k, regenPending[k]) }
                disturb[k] = 0
                regenPending[k] = 0
            }
            disturbActive = false
        }
    }

    /// Höhenänderung des Regenerations-Passes mit Fels/Sediment-Buchhaltung.
    /// Wie `applyDelta`, aber OHNE erneute Störungs-Buchung (sonst hielte sich
    /// der Pfad selbst am Leben) und ohne den Werkzeug-Deckel bei 1.4.
    /// Schreibt seit Issue #96 über den Bett-Funnel (`raiseRockCell` für die
    /// Hebung, `erodeCell` für den Abtrag) — damit trägt auch der Nachzug das
    /// Gletscher-Gate: Regeneration auf vergletschertem Grund bleibt aus,
    /// das Budget verstreicht, ohne das Bett unter dem Eis zu verstellen.
    @inline(__always) private func applyRegenDelta(_ k: Int, _ dhRaw: Double) {
        let dh = max(h[k] + dhRaw, cfg.floor) - h[k]
        if dh >= 0 {
            raiseRockCell(k, dh)
        } else {
            erodeCell(k, -dh)
        }
    }

    /// Verwirft Mäanderläufe und Altarme, die über stark gestörtes Gelände
    /// laufen: eine Zentrumslinie ist die Geschichte eines Betts, das es unter
    /// dem neuen Gelände nicht mehr gibt. `migrateMeander` sät danach aus der
    /// aktuellen Entwässerung neu — solange die Baustelle offen ist, wird also
    /// je Schritt frisch getrasst statt alter Zustand fortgeschrieben.
    private func dropDisturbedMeanderState() {
        let thr = cfg.disturbanceMeanderDrop
        func disturbed(_ nd: MeanderNode) -> Bool {
            let i = min(max(Int(nd.x.rounded()), 0), n - 1)
            let j = min(max(Int(nd.z.rounded()), 0), n - 1)
            return disturb[j * n + i] >= thr
        }
        let oldCount = meander.channels.count
        meander.channels.removeAll { $0.nodes.contains(where: disturbed) }
        if meander.channels.count != oldCount {
            beltCouplingCarry = max(beltCouplingCarry, cfg.meanderBeltCouplingYears)
        }
        var keptOxbows: [[MeanderNode]] = []
        var keptAges: [Double] = []
        for (oi, ox) in meander.oxbows.enumerated() where !ox.contains(where: disturbed) {
            keptOxbows.append(ox)
            keptAges.append(oi < meander.oxbowAge.count ? meander.oxbowAge[oi] : 0)
        }
        meander.oxbows = keptOxbows
        meander.oxbowAge = keptAges
    }

    // MARK: - Mäander-Migration (Lagrange-Zentrumslinien)

    private func seedMeander() {
        meander.channels = MeanderState.traceChannels(config: cfg, h: h, hf: hf,
                                                       area: area, receiver: receiver)
        meander.oxbows.removeAll()
        meander.oxbowAge.removeAll()
    }

    /// Bilineare Abtastung eines Felds an einer kontinuierlichen Grid-Position.
    /// EINE Formel für Höhe und Einzugsgebiet — und auf dem Roh-Puffer, damit
    /// die Mäander-Pässe sie je Knoten aufrufen können, ohne dafür 28k-mal über
    /// eine Klassen-Property zu gehen (Issue #43).
    @inline(__always) static func bilinear(_ p: UnsafePointer<Double>, _ n: Int,
                                           _ gx: Double, _ gz: Double) -> Double {
        let xi = min(max(Int(gx), 0), n - 2), yi = min(max(Int(gz), 0), n - 2)
        let fx = min(max(gx - Double(xi), 0), 1), fy = min(max(gz - Double(yi), 0), 1)
        let k = yi * n + xi
        return p[k] * (1 - fx) * (1 - fy) + p[k + 1] * fx * (1 - fy)
             + p[k + n] * (1 - fx) * fy + p[k + n + 1] * fx * fy
    }

    /// Mittleres Auwald-veg im Ufer-Streifen (±`r` Zellen) um eine
    /// Knotenposition — Eingang der Mäander-Ufer-Kohäsion. Gemittelt wird
    /// über ALLE Streifen-Zellen (Auwald-fremde zählen 0): eine einzelne
    /// Auwald-Zelle bremst also kaum, ein voll bewachsener Streifen deutlich.
    /// Roh-Puffer-Variante aus demselben Grund wie `bilinear`.
    @inline(__always) static func riparianVeg(_ pveg: UnsafePointer<Double>,
                                              _ pcls: UnsafePointer<UInt8>,
                                              _ n: Int, _ r: Int,
                                              _ gx: Double, _ gz: Double) -> Double {
        let ci = min(max(Int(gx.rounded()), 0), n - 1)
        let cj = min(max(Int(gz.rounded()), 0), n - 1)
        var s = 0.0
        var cnt = 0
        for dj in max(0, cj - r)...min(n - 1, cj + r) {
            let row = dj * n
            for di in max(0, ci - r)...min(n - 1, ci + r) {
                let k = row + di
                cnt += 1
                if pcls[k] == 3 { s += pveg[k] }
            }
        }
        return cnt == 0 ? 0 : s / Double(cnt)
    }

    /// Halbbreite des Ufer-Streifens in Zellen (s. `riparianVeg`).
    private var bankRadius: Int { max(1, Int(cfg.meanderBankWidth.rounded())) }

    func riparianVegAt(_ gx: Double, _ gz: Double) -> Double {
        veg.withUnsafeBufferPointer { vb in
        vegClass.withUnsafeBufferPointer { cb in
            Terrain.riparianVeg(vb.baseAddress!, cb.baseAddress!, n, bankRadius, gx, gz)
        }}
    }

    /// Geländehöhe an einer kontinuierlichen Grid-Position (bilinear).
    @inline(__always) private func bilinearH(_ gx: Double, _ gz: Double) -> Double {
        h.withUnsafeBufferPointer { Terrain.bilinear($0.baseAddress!, n, gx, gz) }
    }

    /// Frischt den Abfluss entlang der Läufe aus dem aktuellen Einzugsgebiet auf
    /// und migriert sie einen Zeitschritt. Mobilität aus der lokalen Steigung:
    /// steile Oberläufe bleiben gerade, nur Flachland wandert. Degenerierte Läufe
    /// werden verworfen; ist nichts mehr da, aus der Entwässerung neu säen.
    private func migrateMeander(dt: Double) {
        if meander.channels.isEmpty { seedMeander(); return }
        let cellArea = cfg.cellSize * cfg.cellSize
        // cellSize 0 (keine definierte Schrittweite): kein Abfluss ohne Zellfläche.
        guard cellArea > 0, cellArea.isFinite else { return }
        let nn = n, bankR = bankRadius
        // PERF (Issue #43): `h`, `area`, `veg` und `vegClass` ändern sich
        // während der Migration nicht (sie ist reine Knoten-Geometrie) — die
        // Felder werden deshalb EINMAL geöffnet, statt sie über die Klassen-
        // Property je Knoten und je Streifenzelle neu zu adressieren. Bei 28k
        // Knoten × 25 Streifenzellen sind das ~700k Zugriffe je Schritt.
        h.withUnsafeBufferPointer { hb in
        area.withUnsafeBufferPointer { ab in
        veg.withUnsafeBufferPointer { vb in
        vegClass.withUnsafeBufferPointer { cb in
            let ph = hb.baseAddress!, pa = ab.baseAddress!
            let pveg = vb.baseAddress!, pcls = cb.baseAddress!
            meander.channels.withUnsafeMutableBufferPointer { chs in
                for ci in chs.indices {
                    chs[ci].refreshDischarge { gx, gz in
                        max(0, Terrain.bilinear(pa, nn, gx, gz) / cellArea)
                    }
                }
            }
            meander.migrate(dt: dt, config: cfg,
                            heightAt: { Terrain.bilinear(ph, nn, $0.x, $0.z) },
                            riparianAt: {
                                Terrain.riparianVeg(pveg, pcls, nn, bankR, $0.x, $0.z)
                            })
        }}}}
        // Sicherheits-Clamp: Knoten dürfen die Welt nicht verlassen.
        let maxc = Double(n - 1)
        meander.channels.withUnsafeMutableBufferPointer { chs in
            for ci in chs.indices { chs[ci].clampToWorld(maxCoord: maxc) }
        }
        meander.channels.removeAll { $0.nodes.count < 3 }
        if meander.channels.isEmpty { seedMeander() }
    }

    // MARK: - Mäander-Kopplung ins Höhenfeld (M3)

    /// **Schritt-Deckel als Rate** (Issue #2). Mehrere Pässe deckeln ihren
    /// Eingriff auf einen Anteil der lokalen Höhendifferenz („nicht unter den
    /// Empfänger graben", „nicht über den Innenhang schütten"). Dieser Anteil
    /// war fest `0.5` JE SCHRITT — also dt-abhängig: viele kleine Schritte
    /// nehmen jedes Mal die Hälfte des Rests und kommen der Grenze beliebig
    /// nahe, ein einziger großer Schritt bleibt bei der Hälfte stehen.
    ///
    /// Wichtig ist dabei, WO der Fehler sitzt: bei KLEINEM dt ist der feste
    /// Deckel richtig. Der Eingriff selbst ist dort ∝ dt und winzig, der Deckel
    /// greift gar nicht, und über viele Schritte nähert sich das Gelände der
    /// Grenze asymptotisch an — genau das Kontinuums-Verhalten. Falsch ist er
    /// nur bei GROSSEM dt: dort bleibt ein einzelner Schritt bei der Hälfte
    /// stehen, wo dieselbe Zeit in Teilschritten fast an die Grenze käme.
    ///
    /// Deshalb `max(0.5, 1 − e^(−dt·ln2/500))`:
    /// - **dt ≤ 500 J. → exakt die alten 0.5.** Die gesamte bestehende
    ///   Kalibrierung (Mäander-, Altarm-, Becken- und Langlauf-Wächter takten
    ///   mit dt ≤ 500) bleibt damit bit-genau unangetastet.
    /// - **dt > 500 J.** wächst der Deckel weiter, statt bei der Hälfte zu
    ///   kleben: 0.75 bei 1000, 0.94 bei 2000, 0.999 bei 5000 — ein
    ///   2000-Jahr-Sprung gibt also praktisch dasselbe frei wie vier
    ///   500-Jahr-Schritte (1 − 0.5⁴ = 0.9375).
    ///
    /// Verworfen: die reine Exponentialform ohne Untergrenze. Sie drosselt
    /// KLEINE Schritte künstlich (bei dt = 20 J. nur 0.027 statt 0.5) und
    /// verschob damit genau die Wächter, die in 20-Jahr-Schritten messen —
    /// `EndorheicEvaporation.testBasinLevelIsRateLimited` (max. Spiegelsprung
    /// 0.0073 gegen die Schranke 0.002) bzw., mit dem zuerst probierten Anker
    /// 100 J., `Lithology.testEndorheicMechanicsSurviveLithology`.
    /// Der Deckel bleibt in jeder Variante ein Deckel: er gibt nie MEHR frei
    /// als die volle Höhendifferenz, der Eingriff kann also nicht überschießen.
    ///
    /// Bewusst NICHT über `Terrain.relaxFraction`: dort ist der Nenner die
    /// Zeitkonstante τ, hier die HALBWERTSZEIT (500 J.). `relaxFraction(dt:,
    /// tau: 500/ln2)` wäre dasselbe in Reellen, aber nicht bitgleich — und
    /// diese Zahl ist auf 0.5 bei dt = 500 kalibriert (s. oben).
    @inline(__always) private func stepCapFraction(_ dt: Double) -> Double {
        max(0.5, 1 - exp(-dt * 0.6931471805599453 / 500))
    }

    /// Zugang für den dt-Wächter (`DtInvariance.testStepCapsAreRates`).
    func stepCapFractionForTests(_ dt: Double) -> Double { stepCapFraction(dt) }

    /// Zugang für den Gletscher-Wächter
    /// (`Glacier.testNoFluvialErosionUnderIceOnTheGridPath`). Der Grid-Pfad
    /// läuft im Schritt zusammen mit `diffusionPass` (festes kappa, kein
    /// Regler) — ein Zwei-Arm-Vergleich über `step()` würde deshalb das
    /// Bodenkriechen messen statt das Gate (§I.1 derselben Messreihe). Der
    /// Wächter ruft den Pass deshalb einzeln auf.
    func transportLimitedForTests(dt: Double) { transportLimited(dt: dt) }

    /// Testfenster auf die Delta-Schüttung (Issue #174): `yieldPerCell` steht
    /// für den mittleren Abtrag eines Schritts je Landzelle, Flussnetz aus dem
    /// letzten `computeFlow`.
    func deltaDepositForTests(yieldPerCell: Double) {
        _ = deltaHeightSum(collectMouths: true)
        deltaDeposit(yieldPerCell: yieldPerCell)
    }

    // MARK: - Testfenster auf den Bett-Funnel (Issue #81)

    /// Setzt Bett und Eismaske direkt — ausschließlich für den Funnel-Wächter
    /// (`SimCoreTests/BedFunnel.swift`). Der Funnel ist die eine Stelle, an der
    /// `h`/`sed`/`rock` und das Gletscher-Gate zusammenkommen; ihn gegen einen
    /// SYNTHETISCHEN Zustand zu prüfen (Zellen ohne Sediment, Zellen mit knapp
    /// zu wenig davon, Eis auf einem Teil des Feldes) trifft die Randfälle, die
    /// ein ausgelaufener Sim-Zustand nur zufällig enthält.
    ///
    /// **Abgeleitete Felder werden NICHT mitgezogen**: `hf`, `area`, `receiver`,
    /// `order`, `isChannel`, `ice`/`snow` und alles Übrige behalten den Stand aus
    /// der Generierung und passen danach nicht mehr zum Bett. Für den Funnel-
    /// Wächter ist das richtig — der Funnel liest ausschließlich `h`, `sed`,
    /// `rock` und `underIce`. Wer hier einen Test aufhängt, der einen PASS
    /// aufruft, baut sich einen inkonsistenten Zustand; solche Tests bauen ihren
    /// Zustand über `Terrain`s eigene Läufe auf (s. `Glacier.swift`) oder über
    /// `restore(_:)`.
    func setBedForTests(h nh: [Double], sed ns: [Double], rock nr: [Double], underIce nu: [Bool]) {
        // Der Funnel HÄLT `h = rock + sed`; ein Aufbau, der das schon verletzt,
        // würde eine Abweichung messen, die nicht vom Funnel kommt. Die Maske
        // darf leer sein (= kein Eis) oder volle Länge haben, nichts dazwischen —
        // dieselbe Bauform wie im Feld selbst.
        // Tests dürfen ungültige Höhenwerte in h simulieren ($0.isNaN); rock und sed
        // müssen endlich und konsistent bleiben. Bei finite h und NaN in rock/sed schlägt
        // die Precondition weiterhin an, da abs(finite - NaN) < 1e-12 false ergibt.
        precondition(nh.count == cfg.count && ns.count == cfg.count && nr.count == cfg.count,
                     "Bett-Felder passen nicht zur Config")
        precondition(nu.isEmpty || nu.count == cfg.count, "Eismaske weder leer noch vollständig")
        precondition(zip(nh, zip(nr, ns)).allSatisfy {
            $0.isNaN || abs($0 - ($1.0 + $1.1)) < 1e-12
        }, "h ≠ rock + sed im Testaufbau")
        h = nh; sed = ns; rock = nr; underIce = nu
    }

    /// Ein Funnel-Aufruf über die Klassen-Property …
    @discardableResult
    func erodeCellViaPropertyForTests(_ k: Int, _ amount: Double) -> Double { erodeCell(k, amount) }

    /// … derselbe Abtrag über die Roh-Puffer-Sicht `Bed`.
    @discardableResult
    func erodeCellViaBedForTests(_ k: Int, _ amount: Double) -> Double {
        withBed { erodeCell(k, amount, $0) }
    }

    /// Ablagerung über die Klassen-Property …
    @discardableResult
    func depositCellViaPropertyForTests(_ k: Int, _ amount: Double) -> Double { depositCell(k, amount) }

    /// … und über die Roh-Puffer-Sicht.
    @discardableResult
    func depositCellViaBedForTests(_ k: Int, _ amount: Double) -> Double {
        withBed { depositCell(k, amount, $0) }
    }

    /// Ziel-Fassung des Abtrags (`erodeCellTo`) über die Roh-Puffer-Sicht —
    /// der dritte Aufruf-Weg des Funnels (Issue #96, Auslass-Inzision).
    @discardableResult
    func erodeCellToViaBedForTests(_ k: Int, _ target: Double) -> Double {
        withBed { erodeCellTo(k, target, $0) }
    }

    /// Fels-Hebung (`raiseRockCell`) über die Roh-Puffer-Sicht — gebraucht
    /// vom Pinsel-Trichter (Issue #96).
    @discardableResult
    func raiseRockCellViaBedForTests(_ k: Int, _ amount: Double) -> Double {
        withBed { raiseRockCell(k, amount, $0) }
    }

    /// Test-Helfer: setzt den Empfängerwert an einer Gitterzelle, um ungültige
    /// Verweise (z. B. Empfänger außerhalb des Gitters) im Test gezielt prüfen zu können.
    func setReceiverForTests(at index: Int, to value: Int32) {
        receiver[index] = value
    }

    /// Roh-Puffer-Sicht auf das Bett: dieselben drei Felder, die der Funnel hält
    /// (`h = rock + sed`), plus die Sperr-Maske — `nil` heißt „keine
    /// Zelle gesperrt", genau wie ein leeres Maskenfeld im Terrain selbst.
    ///
    /// Warum es sie gibt: `meanderStamp`, `braidPass` und die Altarm-Pässe
    /// laufen über 692k Zellen bzw. 30k Knoten und adressierten `h`/`sed`/`rock`
    /// vor der Perf-Runde 3 über die KLASSEN-Property, weil ein Roh-Zeiger mit
    /// dem Funnel kollidiert wäre. Das kostete je Zugriff Bounds-, COW- und
    /// Exklusivitäts-Prüfung — gemessen ~4,5 % des Schritts allein in der
    /// Swift-Laufzeit (`swift_beginAccess`/`AccessSet::insert`, s.
    /// docs/perf-measurements.md).
    /// Mit der Sicht öffnet ein Pass die Felder EINMAL und reicht sie durch.
    /// Seit Issue #96 trägt die Sicht außerdem die Bett-REGEL selbst
    /// (`erode(_:_)`/`deposit(_:_:)` unten): Der Terrain-Funnel
    /// (`erodeCell`/`depositCell`) delegiert hierher, und auch die
    /// Tropfenschleife (`Hydraulic.erode`) schreibt über sie — mit ihrer
    /// eigenen, strengeren Maske.
    struct Bed {
        let h: UnsafeMutablePointer<Double>
        let sed: UnsafeMutablePointer<Double>
        let rock: UnsafeMutablePointer<Double>
        /// Sperr-Maske oder `nil` (= keine Zelle gesperrt). Beim Terrain-Funnel
        /// ist es die Gletscher-Maske `underIce` (Issue #35); die Tropfenschleife
        /// übergibt ihre strengere Vereinigung aus Eis UND Gürtelbett
        /// (`beltDropletGate`, Issues #174/#187) — das Gate selbst steht nur
        /// einmal, hier.
        let locked: UnsafePointer<Bool>?

        /// **Die EINE Bett-Regel** (Issue #96): trägt an Zelle `k` `amount` ab
        /// — ERST SEDIMENT, DANN FELS —, hält `h = rock + sed` und gibt den
        /// tatsächlich abgetragenen Betrag zurück. **Gletscher-Gate**
        /// (Issue #35): auf gesperrten Zellen gehört das Tal dem Gletscher,
        /// es gibt keinen fluvialen Abtrag — Rückgabe 0, nichts bewegt.
        ///
        /// Das steht bewusst HIER und nicht je Pass: ein künftiger Bett-Pass
        /// kann die Regel und das Gate nicht mehr vergessen. Wer sie ändert,
        /// ändert genau diese Stelle (Wächter: `SimCoreTests/BedFunnel.swift`).
        /// Die Regel gilt für JEDE Bett-Schreibung der Simulation (Issue #96);
        /// die zwei begründeten Ausnahmen, die bewusst AUCH auf vergletscherten
        /// Zellen laufen — Hangdiffusion und Brandung, s. `erodeCell(_:_:_:)` —,
        /// schreiben als einzige weiterhin selbst.
        @discardableResult
        @inline(__always) func erode(_ k: Int, _ amount: Double) -> Double {
            let a = max(0, amount)
            if a <= 0 { return 0 }
            if let locked, locked[k] { return 0 }
            let ds = min(a, sed[k]); sed[k] -= ds
            rock[k] -= (a - ds)
            h[k] -= a
            return a
        }

        /// Ablage-Hälfte der Regel (Issue #96): lagert `amount` als Sediment an
        /// Zelle `k` ab und gibt den tatsächlich abgelegten Betrag zurück.
        /// Gesperrte Zellen bleiben unangetastet — was mit der nicht
        /// abgelegten Fracht passiert, entscheidet der Aufrufer (der
        /// Terrain-Funnel verliert sie, `transportLimited` und die Tropfen
        /// führen sie weiter talab, s. `depositCell(_:_:_:)`).
        @discardableResult
        @inline(__always) func deposit(_ k: Int, _ amount: Double) -> Double {
            if amount <= 0 { return 0 }
            if let locked, locked[k] { return 0 }
            sed[k] += amount; h[k] += amount
            return amount
        }
    }

    /// Öffnet `h`/`sed`/`rock`/`underIce` einmal für einen ganzen Pass. Solange
    /// die Sicht offen ist, darf derselbe Pass diese vier Felder NICHT mehr über
    /// die Klassen-Property anfassen — auch nicht lesend (`bilinearH`), das wäre
    /// ein Exklusivitäts-Konflikt.
    ///
    /// Seit Issue #81 gilt das ausdrücklich auch für die Adapter
    /// `erodeCell(_:_:)`/`depositCell(_:_:)`: sie öffnen die Sicht selbst, ein
    /// Aufruf aus einem offenen `withBed` heraus ist also derselbe Doppelzugriff.
    /// Der Compiler sagt dazu nichts (beide Überladungen sind hier sichtbar), die
    /// LAUFZEIT schon: gemessen bricht ein verschachtelter Aufruf mit „Fatal
    /// access conflict detected" ab, auch im `-O`-Build. Laut statt still — aber
    /// nichts, worauf man sich verlässt: wer eine Sicht offen hat, ruft die
    /// Drei-Argument-Fassung.
    @inline(__always) private func withBed<R>(_ body: (Bed) -> R) -> R {
        h.withUnsafeMutableBufferPointer { hb in
        sed.withUnsafeMutableBufferPointer { sb in
        rock.withUnsafeMutableBufferPointer { rb in
        underIce.withUnsafeBufferPointer { ib in
            body(Bed(h: hb.baseAddress!, sed: sb.baseAddress!, rock: rb.baseAddress!,
                     locked: ib.isEmpty ? nil : ib.baseAddress))
        }}}}
    }

    /// **Der Bett-Funnel.** Der EINE Eingang aller Terrain-Pässe ins Bett.
    /// Die Zerlegung (erst Sediment, dann Fels), `h = rock + sed` und das
    /// Gletscher-Gate stehen genau einmal, in `Terrain.Bed.erode(_:_:)`;
    /// diese Fassung reicht den Betrag dorthin durch. Wächter:
    /// `SimCoreTests/BedFunnel.swift`.
    ///
    /// **Aufrufer** (seit Issue #96: jede Bett-Schreibung außer den zwei
    /// benannten Ausnahmen): Mäander-Bett-Carve und laterale Ufer,
    /// Altarm-Pfropf und -Verlandung, Braid-Fracht, Auen-Aggradation,
    /// `channelCarve`, der Testpfad `transportLimited` (über die
    /// Property-Fassung), die Auslass-Inzision (über die Ziel-Fassung
    /// `erodeCellTo(_:_:_:)`, s. dort) und der Pinsel samt Nachzug
    /// (`applyDelta`/`applyRegenDelta`, über die Property-Fassung). Die
    /// Tropfenschleife schreibt dieselbe Regel über `Terrain.Bed.erode(_:_:)`
    /// direkt — mit ihrer STRENGEREN Sperr-Maske aus Eis und Gürtelbett
    /// (`beltDropletGate`, Issues #174/#187), weil ihr Radial-Pinsel auch das
    /// Bett wandernder Mäanderläufe nicht aufreißen darf.
    ///
    /// **Gletscher-Gate (Issue #35).** Unter dem Eis gehört das Tal dem
    /// Gletscher — kein fluvialer Abtrag, keine fluviale Ablage; sonst carvt
    /// dasselbe Tal ein zweites Mal, mit fluvialem statt glazialem
    /// Querschnitt. Das Gate sitzt am Funnel statt in jedem Pass einzeln,
    /// damit ein künftiger Bett-Pass es nicht vergessen kann. Leere Maske
    /// (keine Zelle vergletschert, oder `iceEnabled = false`) →
    /// `bed.locked` ist `nil`, der Zweig fällt weg und alles rechnet
    /// bit-identisch zum Stand vor #35.
    ///
    /// **Die zwei begründeten Ausnahmen**, die bewusst AUCH auf vergletscherten
    /// Zellen laufen, schreiben als einzige weiterhin selbst und sind hier
    /// benannt (statt dass sie die Regel nachbauen): **Hangdiffusion**
    /// (`hillslopeDiffusion`, `diffusionPass`) und **Brandung** (`wavePass`).
    /// Beides ist kein fluvialer Abtrag: Das Bodenkriechen trägt die
    /// Höhenänderung der NACHBARN auch auf die Eiszelle, und ein Abschalten
    /// am Gate ließe den Trog mit unbehandelten Kanten zurück — belegt für
    /// die Diffusion in `docs/glacier-measurements.md` §I.1; dieselbe
    /// Begründung trägt die Brandung an der Fjordküste. Das Eis selbst
    /// schreibt sein Bett über ein EIGENES Erosionsgesetz (`updateIce`,
    /// Flux-Modell `E = K·q^m·S`) — kein fluvialer Bett-Pass, deshalb kein
    /// Funnel-Kandidat.
    @inline(__always) private func erodeCell(_ k: Int, _ amount: Double, _ bed: Bed) -> Double {
        bed.erode(k, amount)
    }

    /// Lagert `amount` als Sediment an Zelle `k` ab und gibt den tatsächlich
    /// abgelegten Betrag zurück — die Ablage-Hälfte des Funnels, gleiche
    /// Zuständigkeit und gleiches Gate wie `erodeCell(_:_:_:)`; die Regel
    /// steht in `Terrain.Bed.deposit(_:_:)`. Vergletscherte Zellen bleiben
    /// unangetastet; die Fracht, die dort abgelegt worden wäre, gilt wie
    /// sonst auch als exportiert (Masse-Erhaltung ist in diesem Repo
    /// keine Invariante, AGENTS.md) — der einzige Pass, der sie mitführt
    /// (`transportLimited`), reicht sie stattdessen talwärts weiter; die
    /// Tropfenschleife führt sie in Suspension weiter (s. `Hydraulic.erode`,
    /// `deposit(_:_:)` dort).
    @discardableResult
    @inline(__always) private func depositCell(_ k: Int, _ amount: Double, _ bed: Bed) -> Double {
        bed.deposit(k, amount)
    }

    /// **Ziel-Fassung des Funnel-Abtrags** — dieselbe Regel und dasselbe Gate
    /// (beide stehen in `Bed.erode(_:_)`, aufgerufen über
    /// `erodeCell(_:_:_:)`), aber mit ZIEL-HÖHE statt Betrag: senkt Zelle `k`
    /// auf `target` ab und gibt den tatsächlich abgetragenen Betrag zurück
    /// (`bed.h[k] − target`; 0, wenn die Zelle schon tiefer liegt oder
    /// gesperrt ist).
    ///
    /// Warum es sie gibt (Issue #96): Relaxations-Pässe rechnen die Zielhöhe
    /// als eigenen gerundeten Wert — die Auslass-Inzision ihre als
    /// `hNew = (h + f·hr)/(1+f)` —, und der naive Funnel-Weg
    /// `h −= (h − hNew)` ist NICHT bit-gleich zu `hNew`: der Rundtrip
    /// `h − fl(h − hNew)` weicht im aggressiven Regime (Schritt trägt mehr als
    /// die halbe Höhe ab — große Becken-Auslässe, Empfänger weit unten) an
    /// der Mehrheit der Fälle um 1 ulp ab. Darum schreibt diese Fassung die
    /// Zielhöhe EXAKT und zieht die Zerlegung über den Betrag
    /// `a = h − target` — bit-identisch zur Ausschreibung, die bis #96 in
    /// der Auslass-Inzision stand. Der Wächter prüft die Ziel-Fassung deshalb
    /// auf exakte Zielhöhe statt auf Parität mit der Betrags-Fassung: ihre
    /// Ergebnisse unterscheiden sich genau um jenen Rundtrip.
    @discardableResult
    @inline(__always) private func erodeCellTo(_ k: Int, _ target: Double, _ bed: Bed) -> Double {
        let a = bed.h[k] - target
        guard a > 0 else { return 0 }
        let moved = bed.erode(k, a)
        if moved > 0 { bed.h[k] = target }
        return moved
    }

    /// **Fels-Hebung des Funnels** — die dritte Bett-Bewegung, die der Pinsel
    /// braucht (`sculpt`/`roughen` heben Fels an, `applyRegenDelta` trägt die
    /// Regeneration als Fels ein): hebt `amount` GESTEIN (kein Sediment, die
    /// Zerlegung greift hier nicht) und gibt den tatsächlich angehobenen
    /// Betrag zurück. Dasselbe Gletscher-Gate wie `erodeCell(_:_:_:)` — auch
    /// der Pinsel schreibt seit Issue #96 ausschließlich über den Funnel, und
    /// ein Eingriff auf vergletschertem Grund bleibt damit wirkungslos: Unter
    /// dem Eis gehört das Tal dem Gletscher, und am Eis-Sicht-Modell änderte
    /// der Hieb am Bett nichts, bis die Zunge schmilzt.
    @discardableResult
    @inline(__always) private func raiseRockCell(_ k: Int, _ amount: Double, _ bed: Bed) -> Double {
        if amount <= 0 { return 0 }
        if let locked = bed.locked, locked[k] { return 0 }
        bed.rock[k] += amount; bed.h[k] += amount
        return amount
    }

    /// Bequemlichkeits-Fassung des Funnels für Pässe, die keine `Bed`-Sicht
    /// offen haben: öffnet sie je Aufruf und reicht durch.
    ///
    /// **Hier steht keine Regel** (Issue #81,#96). Abtrags-Reihenfolge,
    /// `h = rock + sed` und das Gletscher-Gate stehen genau einmal, in
    /// `Terrain.Bed.erode(_:_:)` — erreichbar über `erodeCell(_:_:_:)`.
    /// Bis #81 war das hier eine zweite, von Hand synchron gehaltene
    /// Ausschreibung derselben Regel.
    ///
    /// Aufrufer sind nur der Testpfad `transportLimited` und die geparkte
    /// `floodplainAggradation`; kein Produktionspass läuft hier durch, das
    /// Öffnen je Aufruf kostet die Produktion also nichts
    /// (`docs/perf-measurements.md` §K). Die zwei liegen in GEGENLÄUFIGEN
    /// Zweigen von `step()` — `floodplainAggradation` steht innerhalb des
    /// `hydraulicEnabled`-Zweigs, `transportLimited` im Gegenzweig —, ein
    /// Beleglauf über beide braucht also zwei Konfigurationen. Beide Pässe adressieren `h`/`sed` rings
    /// um den Funnel weiter über die Klassen-Property — sie auf eine offene
    /// Sicht umzustellen wäre möglich, würde aber einen Testpfad-Pass umbauen,
    /// dessen Laufzeit niemanden interessiert.
    ///
    /// Ein Unterschied bleibt und ist beabsichtigt: die Bed-Fassung schreibt
    /// über Roh-Zeiger, die Property-Fassung tat es über `Array`-Subscripts.
    /// Ein `k` außerhalb des Feldes trifft damit keine Bereichsprüfung mehr,
    /// sondern fremden Speicher. Beide Aufrufer beziehen ihr `k` aus `order`
    /// bzw. aus den eigenen Schleifengrenzen, und der Wächter prüft die
    /// Feldlängen beim Aufbau — aber „dünner Adapter" heißt nicht „in jeder
    /// Hinsicht dasselbe".
    ///
    /// **Nur außerhalb von `withBed` aufrufen.** Innerhalb eines offenen Blocks
    /// ist das ein Doppelzugriff auf dieselben Felder (s. `withBed`); der
    /// Compiler wählt diese Überladung klaglos, die Laufzeit bricht ab. Wer eine
    /// Sicht offen hat, ruft `erodeCell(_:_:_:)` — genau dafür gibt es sie.
    @inline(__always) private func erodeCell(_ k: Int, _ amount: Double) -> Double {
        withBed { erodeCell(k, amount, $0) }
    }

    /// Bequemlichkeits-Fassung der Ablagerung, s. `erodeCell(_:_:)`.
    @discardableResult
    @inline(__always) private func depositCell(_ k: Int, _ amount: Double) -> Double {
        withBed { depositCell(k, amount, $0) }
    }

    /// Bequemlichkeits-Fassung der Fels-Hebung, s. `erodeCell(_:_:)`. Aufrufer
    /// sind die Pinsel-Trichter `applyDelta`/`applyRegenDelta` (Issue #96) —
    /// wenige tausend Zellen je Strich, das Öffnen je Aufruf kostet dort nichts.
    @discardableResult
    @inline(__always) private func raiseRockCell(_ k: Int, _ amount: Double) -> Double {
        withBed { raiseRockCell(k, amount, $0) }
    }

    /// Stempelt die Mäander-Läufe ins Höhenfeld:
    /// 1) **Bett-Carve** (Kanal carvt selbst) — senkt die überstrichenen Zellen
    ///    Richtung stromab-Höhe, self-reinforcing mit D8 (nächstes computeFlow
    ///    routet durchs Bett). Gedeckelt aufs halbe lokale Gefälle.
    /// 2) **Laterale Ufer-Verschiebung** — Prallhang (Außenkurve) erodieren,
    ///    Gleithang (Innenkurve) ablagern, massenerhaltend. So wandert das Bett.
    /// 3) **isChannel-Maske** für die Reconciliation mit `transportLimited`.
    private func meanderStamp(dt: Double) {
        fill(&isChannel, false)
        let cs = cfg.cellSize
        // cellSize 0 (keine definierte Schrittweite): kein Bett-Gefälle entlang der Segmente.
        guard cs > 0, cs.isFinite else { return }
        let m = cfg.mExp
        let cellArea = cs * cs
        let width = cfg.meanderBankWidth
        let capF = stepCapFraction(dt)  // war fest 0.5 je Schritt (Issue #2)
        let nn = n
        // PERF (Issue #43): die Felder, die der Stempel selbst liest bzw.
        // schreibt, EINMAL öffnen statt je überstrichener Zelle. `h`, `sed` und
        // `rock` kommen über `withBed` dazu — dieselbe Sicht, die auch der
        // Funnel `erodeCell`/`depositCell` mit seinem Gletscher-Gate bekommt.
        // `bilinearH` darf daneben NICHT mehr laufen (es öffnet `h` selbst);
        // der Stempel ruft deshalb direkt `Terrain.bilinear` auf demselben
        // Zeiger — identische Rechnung, nur ohne zweiten Zugriff.
        // `underIce` liegt hier nur lesend offen, der Funnel liest es ebenfalls
        // nur; zwei Lese-Zugriffe schließen sich nicht aus.
        hf.withUnsafeBufferPointer { hfb in
        underIce.withUnsafeBufferPointer { uib in
        veg.withUnsafeMutableBufferPointer { vb in
        isChannel.withUnsafeMutableBufferPointer { icb in
        withBed { bed in
        let phf = hfb.baseAddress!, pveg = vb.baseAddress!, pchan = icb.baseAddress!
        let pice = uib.baseAddress
        let iceOn = uib.count == cfg.count
        for ch in meander.channels {
            let nodes = ch.nodes
            guard nodes.count >= 2 else { continue }
            // --- 1) Bett-Carve entlang der Segmente ---
            for i in 0..<(nodes.count - 1) {
                let a = nodes[i], b = nodes[i + 1]
                let d = dist(a, b)
                let hb = Terrain.bilinear(bed.h, nn, b.x, b.z)                      // stromab-Zielhöhe
                let ha = Terrain.bilinear(bed.h, nn, a.x, a.z)
                let segSlope = d > 1e-6 ? max(0, ha - hb) / (d * cs) : 0
                let qA = 0.5 * (ch.discharge[i] + ch.discharge[i + 1]) * cellArea // echtes A
                let carveRate = cfg.meanderCarve * pow(max(qA, 0), m) * segSlope * dt
                let steps = max(1, Int(d.rounded(.up)))
                for sIdx in 0...steps {
                    let t = Double(sIdx) / Double(steps)
                    let ci = min(max(Int((a.x + (b.x - a.x) * t).rounded()), 0), nn - 1)
                    let cj = min(max(Int((a.z + (b.z - a.z) * t).rounded()), 0), nn - 1)
                    let k = cj * nn + ci
                    // Unter stehendem Wasser (See/geflutete Ebene) KEIN Bett-Carve und
                    // KEINE Kanal-Maske: dort fließt nichts (Stillwasser), und die Maske
                    // würde die Droplet-Deposition dämpfen — der Kanal grub sonst über
                    // Jahrtausende dunkle Tiefen-Rinnen in Seeböden, die nie verlanden
                    // (gemessen: hf−h > 0.16 nach 24k Jahren, „dunkle Stellen").
                    if phf[k] - bed.h[k] > 0.02 { continue }
                    // Unter dem Eis (Issue #35) ebenso wenig — und zwar VOR der
                    // Maske: `erodeCell` gatet zwar den Carve, aber ein Kanal,
                    // der unter einer Zunge durchläuft, ist auch kein Kanal.
                    // `isChannel` dämpft die Tropfen-Deposition und `veg = 0`
                    // reißt die Ufer-Vegetation weg — beides hat auf einer
                    // vergletscherten Zelle nichts zu suchen.
                    if iceOn && pice![k] { continue }
                    pchan[k] = true
                    // Ufer-Kill (Stufe 3): das überstrichene Bett reißt die
                    // Wurzeln weg — veg hart auf 0 (absorbierend, dt-frei).
                    // Regrünung kommt per Sukzession von den Nachbarn zurück,
                    // sobald der Lauf weiterwandert.
                    pveg[k] = 0
                    let cap = max(0, bed.h[k] - hb) * capF           // nicht unter stromab graben
                    _ = erodeCell(k, min(carveRate, cap), bed)
                }
            }
            // --- 2) laterale Ufer-Verschiebung pro innerem Knoten ---
            for i in 1..<(nodes.count - 1) {
                let a = nodes[i - 1], b = nodes[i], c = nodes[i + 1]
                let v1x = b.x - a.x, v1z = b.z - a.z
                let v2x = c.x - b.x, v2z = c.z - b.z
                let ds = 0.5 * ((v1x * v1x + v1z * v1z).squareRoot()
                              + (v2x * v2x + v2z * v2z).squareRoot())
                if ds < 1e-9 { continue }
                let cross = v1x * v2z - v1z * v2x
                let dot = v1x * v2x + v1z * v2z
                let curv = atan2(cross, dot) / ds
                let tx = c.x - a.x, tz = c.z - a.z
                let tl = (tx * tx + tz * tz).squareRoot()
                if tl < 1e-9 { continue }
                // Außen-Normale = weg vom Krümmungszentrum (−sign(curv) · linke Normale)
                let sgn = curv > 0 ? -1.0 : 1.0
                let ox = sgn * (-tz / tl), oz = sgn * (tx / tl)
                let outI = min(max(Int((b.x + ox * width).rounded()), 0), nn - 1)
                let outJ = min(max(Int((b.z + oz * width).rounded()), 0), nn - 1)
                let inI = min(max(Int((b.x - ox * width).rounded()), 0), nn - 1)
                let inJ = min(max(Int((b.z - oz * width).rounded()), 0), nn - 1)
                let ko = outJ * nn + outI, ki = inJ * nn + inI
                if ko == ki { continue }
                let qA = ch.discharge[i] * cellArea
                let want = cfg.meanderBankErode * pow(max(qA, 0), m) * abs(curv) * dt
                // nur so viel, dass der Prallhang nicht unter den Innenhang fällt
                // (Anteil je Schritt als RATE, s. stepCapFraction)
                let cap = max(0, bed.h[ko] - bed.h[ki]) * capF
                let moved = erodeCell(ko, min(want, cap), bed)
                depositCell(ki, moved, bed)
            }
        }
        }}}}}
        plugOxbows()
        fillOxbows(dt: dt)
    }

    /// Altarm-Verlandung: hebt die Altarm-Betten langsam (Zeitkonstante
    /// `oxbowFillYears`) Richtung Uferrand an (Sediment) — der See verschwindet
    /// allmählich. Vollständig verlandete Altarme fallen aus der Liste.
    /// `byAge` (Mäandergürtel): ein Altarm verlandet im Schritt seiner
    /// Entstehung nur über sein Alter, nicht über den ganzen Schritt (er
    /// entsteht in einem Teilschritt, s. `meanderBeltStep`).
    private func fillOxbows(dt: Double, byAge: Bool = false) {
        // Exponentiell (Issue #2, s. fillLakes): `min(1, dt/τ)` verlandete einen
        // 5500-Jahr-Sprung komplett in EINEM Schritt, dieselbe Zeit in kleinen
        // Schritten dagegen nur zu 63 % (1 − 1/e).
        let rate = Terrain.relaxFraction(dt: dt, tau: cfg.oxbowFillYears)
        // PERF: das `[k-1, k+1, k-n, k+n]`-Literal war eine Array-ALLOKATION je
        // Altarm-Knoten (Messung: der Pass steckte zu zwei Dritteln in der
        // Swift-Laufzeit). Ausgeschriebene `max`-Kette in derselben Reihenfolge
        // ⇒ bit-identisch. Bett über `withBed`, s. `meanderStamp`.
        let nn = n
        withBed { bed in
        let ph = bed.h
        for (oi, loop) in meander.oxbows.enumerated() {
            let rate = byAge && meander.oxbowAge[oi] < dt
                ? Terrain.relaxFraction(dt: meander.oxbowAge[oi], tau: cfg.oxbowFillYears) : rate
            for nd in loop {
                let ci = min(max(Int(nd.x.rounded()), 1), nn - 2)
                let cj = min(max(Int(nd.z.rounded()), 1), nn - 2)
                let k = cj * nn + ci
                var rim = ph[k]
                rim = max(rim, ph[k - 1]); rim = max(rim, ph[k + 1])
                rim = max(rim, ph[k - nn]); rim = max(rim, ph[k + nn])
                let add = (rim - ph[k]) * rate
                if add > 0 { depositCell(k, add, bed) }
            }
        }
        }
        meander.pruneOxbows(maxAge: cfg.oxbowMaxAge)
    }

    /// Verkorkt frisch abgeschnürte Schleifen (Alter 0) an ihren Enden mit
    /// Sediment, sodass D8 nicht mehr hindurchroutet und die eingetiefte Schleife
    /// über den bestehenden `hf>h`-Mechanismus zum Altarm-See wird.
    private func plugOxbows() {
        plugOxbows(indices: meander.oxbows.indices.filter { meander.oxbowAge[$0] == 0 })
    }

    /// Verkorkt die Altarme ab Index `from` — der Gürtel erkennt neue Altarme
    /// am Index, nicht am Alter 0: sie tragen seit #187 ihr Alter am Schrittende.
    private func plugOxbows(from: Int) {
        guard from < meander.oxbows.count else { return }
        plugOxbows(indices: Array(from..<meander.oxbows.count))
    }

    private func plugOxbows(indices: [Int]) {
        let nn = n
        withBed { bed in
        for oi in indices { plugOxbow(meander.oxbows[oi], bed: bed, nn: nn) }
        }
    }

    private func plugOxbow(_ loop: [MeanderNode], bed: Bed, nn: Int) {
        let ph = bed.h
        guard loop.count >= 4 else { return }
        for nd in [loop[1], loop[loop.count - 2]] {
            let ci = min(max(Int(nd.x.rounded()), 1), nn - 2)
            let cj = min(max(Int(nd.z.rounded()), 1), nn - 2)
            let k = cj * nn + ci
            var lip = ph[k]
            lip = max(lip, ph[k - 1]); lip = max(lip, ph[k + 1])
            lip = max(lip, ph[k - nn]); lip = max(lip, ph[k + nn])
            depositCell(k, max(0, lip - ph[k]), bed)
        }
    }

    // MARK: - Mäandergürtel (Issue #174, Paket B)

    /// Abfluss je Knoten für den Gürtel: größtes Einzugsgebiet im 3×3 um den
    /// Knoten, dann entlang des Laufs monoton (laufendes Maximum stromab).
    /// Bilinear auf der einzelligen D8-Rinne fiel der Abfluss eines Knotens,
    /// der eine Zelle neben der Rinne lag, auf ~1 Zelle — gemessen endete der
    /// Hauptlauf in Jahr 100.000 auf 1–50 Zellen Einzugsgebiet.
    private func refreshBeltDischarge(only: Int? = nil) {
        let nn = n, cellArea = cfg.cellSize * cfg.cellSize
        guard cellArea > 0, cellArea.isFinite else { return }
        area.withUnsafeBufferPointer { ab in
            let pa = ab.baseAddress!
            meander.channels.withUnsafeMutableBufferPointer { chs in
                for ci in chs.indices where only == nil || only == ci {
                    var run = 0.0
                    chs[ci].refreshDischarge { gx, gz in
                        let ci0 = min(max(Int(gx.rounded()), 0), nn - 1)
                        let cj0 = min(max(Int(gz.rounded()), 0), nn - 1)
                        var m = 0.0
                        for j in max(0, cj0 - 1)...min(nn - 1, cj0 + 1) {
                            for i in max(0, ci0 - 1)...min(nn - 1, ci0 + 1) { m = max(m, pa[j * nn + i]) }
                        }
                        run = max(run, m / cellArea)
                        return run
                    }
                }
            }
        }
    }

    /// Migration und Gürtel-Stempel, gemeinsam sub-getaktet — JE LAUF: jeder
    /// wandernde Lauf springt je Teilschritt höchstens einen halben
    /// Knotenabstand (seine eigene CFL-Zahl), und hinter ihm bleibt in jedem
    /// Teilschritt die Bank liegen — sonst hinge die Spur der Scroll-Bars an der
    /// Schrittweite. Mit EINER Teilschrittzahl für alle setzte der schnellste
    /// Knoten der Welt den Takt aller (gemessen 13 Teilschritte je 100 Jahre,
    /// Gürtel 36 ms je Schritt). Feste Läufe (unter `meanderBeltMinCells`)
    /// bekommen einen Stempel über den ganzen Schritt.
    ///
    /// **Alter je Teilschritt** (Review #187): eine Bank oder ein Altarm aus
    /// Teilschritt `si` ist am Schrittende `dt − (si+1)·sub` Jahre alt, nicht 0.
    /// Bis dahin alterten Bank- und Altarm-Alter nur einmal je Schritt; nach
    /// einem 1000-Jahr-Schritt trugen gemessen alle 9971 neuen Bankzellen das
    /// Alter 0 (in 100 × 10 Jahren: 269, der Rest über 0–1000 Jahre verteilt).
    /// Die Scroll-Rippen (Isolinien des Alters) fehlten damit nach dem Einlauf
    /// und nach jedem Sprung.
    private func meanderBeltStep(dt: Double) {
        if meander.channels.isEmpty { seedMeander() }
        fill(&isChannel, false)
        fill(&inBelt, false)
        if cfg.meanderBeltCoupling {
            // Tropfen-Sperre nur im Bett WANDERNDER Läufe (s. `beltDropletGate`);
            // `beltStamp` setzt sie je Teilschritt.
            if dropletGateBuf.count != cfg.count { dropletGateBuf = .init(repeating: false, count: cfg.count) }
            fill(&dropletGateBuf, false)
        }
        // Alterung auf dem Roh-Puffer, parallel (Review #187: als Schleife über
        // die Klassen-Property seriell über alle n² Zellen).
        barAge.withUnsafeMutableBufferPointer { ab in
            let pa = ab.baseAddress!
            parallel(cfg.count) { lo, hi in
                for k in lo..<hi where pa[k] >= 0 { pa[k] += dt }
            }
        }
        for oi in meander.oxbowAge.indices { meander.oxbowAge[oi] += dt }
        let nn = n, maxc = Double(n - 1)
        // Teilschritt-Deckel nur als Sicherheitsnetz. Mit 256 riss er bei
        // Einlauf und Sprüngen: gemessen max. Rate 0,21–0,31 Zellen/Jahr →
        // nötig 276–419 Teilschritte bei dt 1000, 551–837 bei dt 2000; schnelle
        // Bögen wuchsen dann nur mit 31–93 % ihrer Rate (Review #187).
        let maxSub = 4096
        // Mit Kopplung (#187) setzt `coupleBeltToDrainage` Läufe und Abfluss
        // im festen Kopplungstakt aus dem D8-Netz; dazwischen reist der
        // Abfluss mit den Knoten (Neuabtastung und Cutoffs interpolieren bzw.
        // schneiden ihn mit). Das Abflussfeld ändert sich im Schritt ohnehin nicht.
        let coupled = cfg.meanderBeltCoupling
        let couplingDt = coupled ? beltCouplingStep(dt: dt) : 0
        if couplingDt > 0 {
            mark("belt.couple")
            let ox0 = meander.oxbows.count
            coupleBeltToDrainage(dt: couplingDt)
            plugOxbows(from: ox0)
        } else if !coupled {
            mark("belt.discharge")
            refreshBeltDischarge()
        }
        var maxSubUsed = 0
        let mobile = meander.channels.indices.filter { MeanderState.migrates(meander.channels[$0], cfg) }
        if coupled, let used = parallelBeltRuns(mobile, dt: dt) {
            maxSubUsed = used
        } else {
            for ci in mobile {
                mark("belt.migrate")
                let plan = h.withUnsafeBufferPointer { hb in
                    let ph = hb.baseAddress!
                    return meander.beltMigrationPlan(channel: ci, config: cfg,
                                                     heightAt: { Terrain.bilinear(ph, nn, $0.x, $0.z) })
                }
                let rate = plan.rate
                let nsub = max(1, min(maxSub, Int((rate * dt / (0.5 * cfg.meanderNodeSpacing)).rounded(.up))))
                maxSubUsed = max(maxSubUsed, nsub)
                let sub = dt / Double(nsub)
                var stampedGeometry: BeltGeometry?
                for si in 0..<nsub {
                    mark("belt.migrate")
                    let ageAtEnd = dt - Double(si + 1) * sub
                    let ox0 = meander.oxbows.count
                    h.withUnsafeBufferPointer { hb in
                        let ph = hb.baseAddress!
                        if si == 0 {
                            meander.applyBeltMigrationPlan(ci, plan: plan, dt: sub, time: years, config: cfg)
                        } else {
                            meander.migrateBeltChannel(ci, dt: sub, time: years + Double(si) * sub, config: cfg,
                                                       heightAt: { Terrain.bilinear(ph, nn, $0.x, $0.z) }, geometry: stampedGeometry)
                        }
                    }
                    for oi in ox0..<meander.oxbowAge.count { meander.oxbowAge[oi] = ageAtEnd }
                    meander.channels[ci].clampToWorld(maxCoord: maxc)
                    if !coupled {
                        mark("belt.discharge")
                        refreshBeltDischarge(only: ci)
                    }
                    mark("belt.stamp")
                    let stampDt = coupled && cfg.meanderBeltSymmetricStamp ? 0.5 * sub : sub
                    stampedGeometry = beltStamp(dt: stampDt, only: ci, ageAtEnd: ageAtEnd)
                    plugOxbows(from: ox0)
                }
            }
        }
        beltSubsteps = maxSubUsed
        mark("belt.attach")
        meander.attachTributaries(config: cfg)
        meander.channels.removeAll { $0.nodes.count < 3 }
        if !coupled { refreshBeltDischarge() }
        mark("belt.fixedStamp")
        beltStamp(dt: dt, only: nil, ageAtEnd: 0)
        mark("belt.fill")
        fillOxbows(dt: dt, byAge: true)
        if meander.channels.isEmpty { seedMeander() }
    }

    private final class BeltRun {
        let channel: Int
        let state = MeanderState()
        let footprint: MeanderState.BeltFootprint
        var substeps = 0

        init(channel: Int, line: RiverChannel, footprint: MeanderState.BeltFootprint) {
            self.channel = channel
            self.footprint = footprint
            state.channels = [line]
        }
    }

    /// Ein gemeinsamer Parallelstart für den Abhängigkeitsgraphen. Ein Lauf
    /// wartet nur auf seine überlappenden Vorgänger, nicht auf unabhängige
    /// langsame Läufe derselben Ebene. Alle Warteschlangen-Zugriffe sind unter
    /// dem Condition-Lock; Sim-Zustand wird hier nie angefasst.
    final class BeltSchedule {
        private let condition = NSCondition()
        private var waiting: [Int]
        private let successors: [[Int]]
        private var ready: [Int]
        private var remaining: Int

        init(_ footprints: [MeanderState.BeltFootprint]) {
            var waiting = [Int](repeating: 0, count: footprints.count)
            var successors = [[Int]](repeating: [], count: footprints.count)
            for j in footprints.indices {
                for i in 0..<j where footprints[i].overlaps(footprints[j]) {
                    waiting[j] += 1
                    successors[i].append(j)
                }
            }
            self.waiting = waiting
            self.successors = successors
            self.ready = waiting.indices.filter { waiting[$0] == 0 }
            self.remaining = footprints.count
        }

        func take() -> Int? {
            condition.lock()
            defer { condition.unlock() }
            while ready.isEmpty && remaining > 0 { condition.wait() }
            return ready.popLast()
        }

        func finish(_ index: Int) {
            condition.lock()
            remaining -= 1
            for j in successors[index] {
                waiting[j] -= 1
                if waiting[j] == 0 { ready.append(j); condition.signal() }
            }
            if remaining == 0 { condition.broadcast() }
            condition.unlock()
        }
    }

    /// Abhängigkeiten behalten für jedes überlappende Paar i < j dessen
    /// Reihenfolge. Gleichzeitig arbeiten nur vollständig unabhängige Läufe.
    /// Gemeinsame Arrays sind währenddessen ausschließlich als Roh-Puffer offen;
    /// jeder Arbeiter besitzt seinen eigenen Cutoff-Index und seine Historie.
    private func parallelBeltRuns(_ mobile: [Int], dt: Double) -> Int? {
        guard mobile.count > 1, cfg.cellSize > 0, cfg.cellSize.isFinite else { return nil }
        mark("belt.schedule")
        var runs: [BeltRun] = []
        for ci in mobile {
            guard let footprint = meander.beltFootprint(meander.channels[ci], dt: dt, config: cfg) else { return nil }
            runs.append(BeltRun(channel: ci, line: meander.channels[ci], footprint: footprint))
        }
        let schedule = BeltSchedule(runs.map(\.footprint))
        mark("belt.parallel")
        let nn = n, maxc = Double(n - 1), config = cfg, time = years
        hf.withUnsafeBufferPointer { hfb in
        veg.withUnsafeMutableBufferPointer { vb in
        isChannel.withUnsafeMutableBufferPointer { icb in
        inBelt.withUnsafeMutableBufferPointer { ibb in
        barAge.withUnsafeMutableBufferPointer { bab in
        dropletGateBuf.withUnsafeMutableBufferPointer { glb in
        withBed { bed in
            let buffers = BeltStampBuffers(bed: bed, hf: hfb.baseAddress!, veg: vb.baseAddress!,
                                           channel: icb.baseAddress!, belt: ibb.baseAddress!, age: bab.baseAddress!,
                                           lock: glb.count == config.count ? glb.baseAddress : nil)
            let heightAt: (MeanderNode) -> Double = { Terrain.bilinear(bed.h, nn, $0.x, $0.z) }
            let work: (Int) -> Void = { index in
                let run = runs[index], state = run.state
                let plan = state.beltMigrationPlan(channel: 0, config: config, heightAt: heightAt)
                let nsub = max(1, min(4096, Int((plan.rate * dt / (0.5 * config.meanderNodeSpacing)).rounded(.up))))
                precondition(nsub <= run.footprint.maxSubsteps)
                run.substeps = nsub
                let sub = dt / Double(nsub)
                var geometry: BeltGeometry?
                for si in 0..<nsub {
                    let ageAtEnd = dt - Double(si + 1) * sub
                    let ox0 = state.oxbows.count
                    if si == 0 {
                        state.applyBeltMigrationPlan(0, plan: plan, dt: sub, time: time, config: config,
                                                     noiseChannel: run.channel)
                    } else {
                        state.migrateBeltChannel(0, dt: sub, time: time + Double(si) * sub, config: config,
                                                  heightAt: heightAt, geometry: geometry, noiseChannel: run.channel)
                    }
                    for oi in ox0..<state.oxbowAge.count { state.oxbowAge[oi] = ageAtEnd }
                    state.channels[0].clampToWorld(maxCoord: maxc)
                    let stampDt = config.meanderBeltSymmetricStamp ? 0.5 * sub : sub
                    geometry = self.beltStampChannel(state.channels[0], dt: stampDt, part: 1, ageAtEnd: ageAtEnd,
                                                     lockHere: true, buffers: buffers)
                    for oi in ox0..<state.oxbows.count { self.plugOxbow(state.oxbows[oi], bed: bed, nn: nn) }
                }
            }
            DispatchQueue.concurrentPerform(iterations: min(Terrain.coreCount, runs.count)) { _ in
                while let index = schedule.take() {
                    work(index)
                    schedule.finish(index)
                }
            }
        }}}}}}}
        for run in runs {
            meander.channels[run.channel] = run.state.channels[0]
            meander.appendBeltHistory(run.state)
        }
        return runs.map(\.substeps).max() ?? 0
    }

    /// Sperrmaske der Tropfen (`Hydraulic.erode`, Parameter `bedLocked`):
    /// Gletscher (#35) und — mit Gürtel — das Bett der Mäanderläufe (`inBelt`).
    /// Dort tragen die Tropfen weder ab noch lagern sie ab, ihre Fracht geht
    /// hindurch. Der Gürtel löst das Bett auf Bankfull-Skala auf (Kolk,
    /// Gleithang, Bank); der radiale Erosions-Pinsel der Tropfen grub jeden
    /// Schritt ein symmetrisches V hinein (gemessen: mittleres Querprofil der
    /// Bögen außen/innen 0,9 / 0,9 Tiefen statt des Kolks außen), und der
    /// Bezug des Stempels sank mit der Sohle. Dieselbe Doktrin wie
    /// `channelCarve` auf Gürtelzellen. Ohne Gürtel: `underIce` unverändert.
    ///
    /// Mit Kopplung (#187) nur das Bett WANDERNDER Läufe: die Tropfen tragen
    /// über gesperrte Zellen ihre volle Fracht und laden sie an der ersten
    /// freien Zelle ab. Seit jeder D8-Abschnitt seine Linie hat, liegen
    /// Profil-Stempel fester Läufe auf viel mehr Wegen, und am Ende eines
    /// solchen Stücks wuchs gemessen ein Schutthügel von 0,40 Höhe in einem
    /// 500-Jahr-Schritt (n = 160, Seed 1337, Zelle (5, 101): 0,318 → 0,722,
    /// über dem höchsten Gipfel; ohne Tropfen keiner). Das Profil, das die
    /// Sperre schützt (Kolk, Gleithang), baut nur der wandernde Gürtel.
    private func beltDropletGate() -> [Bool] {
        guard cfg.meanderEnabled && cfg.meanderBelt else { return underIce }
        let c = cfg.count
        if dropletGateBuf.count != c { dropletGateBuf = .init(repeating: false, count: c) }
        let iceOn = underIce.count == c
        let mobileOnly = cfg.meanderBeltCoupling
        // Roh-Puffer, parallel (Review #187: seriell über die Properties).
        dropletGateBuf.withUnsafeMutableBufferPointer { gb in
        inBelt.withUnsafeBufferPointer { bb in
        underIce.withUnsafeBufferPointer { ib in
            let pg = gb.baseAddress!, pb = bb.baseAddress!, pi = ib.baseAddress
            parallel(c) { lo, hi in
                if mobileOnly {
                    for k in lo..<hi { pg[k] = pg[k] || (iceOn && pi![k]) }
                } else {
                    for k in lo..<hi { pg[k] = pb[k] || (iceOn && pi![k]) }
                }
            }
        }}}
        return dropletGateBuf
    }
    private var dropletGateBuf: [Bool] = []

    /// Größte Teilschrittzahl eines Laufs im letzten Gürtel-Schritt (Diagnose).
    public private(set) var beltSubsteps = 1

    /// Stempelt die Läufe über die volle Kanalbreite ins Höhenfeld:
    ///
    /// - **Sohle**: Ziel `z_bf − D·(1 − η²)(1 + skew·a·η)` mit η = Abstand zur
    ///   Mitte in Halbbreiten (positiv = außen), `a` aus |Krümmung| · Breite —
    ///   im Bogen liegt der Kolk außen, im Wendepunkt (a = 0) ist das Profil
    ///   symmetrisch. Was über dem Ziel liegt, wird abgetragen (Relaxation über
    ///   `meanderBeltRelaxYears`) und geht in das Bank-Budget.
    /// - Im Kanal füllt das Budget jede Zelle unter dem Ziel auf, außen wie
    ///   innen. Bis zur Kalibrierung (#174) nur innen: Kolke außen blieben dann
    ///   tiefer als das über ±2 Knoten gemittelte Ziel, Übergänge wurden
    ///   darauf abgetragen, der Bezug sank je Teilschritt (Sohlen-Ratsche,
    ///   gemessen ~2 Tiefen Eintiefung unter die eigene Aue, Rest-Budget
    ///   29 Tiefen·Zellen je Knoten; danach 13).
    /// - **Bank**: innen neben dem Kanal füllt das Budget bis `z_bf − barTop·D`
    ///   auf — NIE darüber. Die Bank ist damit eben (bankfull), wandernde Läufe
    ///   hinterlassen eine flache Aue: laterale Planation. Was ein Knoten nicht
    ///   unterbringt, wandert zum nächsten stromab.
    /// - `z_bf` (bankfull) = tiefste Sohle des Querschnitts plus Kanaltiefe,
    ///   über ±2 Knoten gemittelt: aus der Sohle, nicht aus den Ufern, sonst
    ///   senkt die eigene Bank (unter bankfull) den Bezug Schritt für Schritt.
    /// - Steile Strecken (Mobilität 0) bekommen den alten Linien-Carve; ihr
    ///   Bett formen `channelCarve` und die Tropfen.
    /// - `only`: genau dieser (wandernde) Lauf, je Teilschritt; `nil` = alle
    ///   festen Läufe, einmal je Schritt (s. `meanderBeltStep`).
    /// - `ageAtEnd`: Alter einer hier frisch abgelegten Bank am Schrittende
    ///   (Teilschritt `si`: `dt − (si+1)·sub`; feste Läufe 0).
    /// - **Frische Bank** nur, wo die Ablage die Zelle bis auf eine Viertel
    ///   Kanaltiefe an die Bank-Oberkante hebt — ein Zustand, keine Menge. Bis
    ///   #187 machte jede Mini-Ablagerung eine frische Bank (Alter 0, Bewuchs
    ///   weg, Tropfen gesperrt), und ihre Menge hing über `rel` an der
    ///   Schrittweite. Eine bestehende Bank verjüngt sich, wenn die Ablage mehr
    ///   als 0,2 Tiefen Lücke bis zur Oberkante schließt.
    @discardableResult
    private func beltStamp(dt: Double, only: Int?, ageAtEnd: Double) -> BeltGeometry? {
        let cs = cfg.cellSize
        guard cs > 0, cs.isFinite else { return nil }
        return hf.withUnsafeBufferPointer { hfb in
        veg.withUnsafeMutableBufferPointer { vb in
        isChannel.withUnsafeMutableBufferPointer { icb in
        inBelt.withUnsafeMutableBufferPointer { ibb in
        barAge.withUnsafeMutableBufferPointer { bab in
        dropletGateBuf.withUnsafeMutableBufferPointer { glb in
        withBed { bed in
        let buffers = BeltStampBuffers(bed: bed, hf: hfb.baseAddress!, veg: vb.baseAddress!,
                                       channel: icb.baseAddress!, belt: ibb.baseAddress!, age: bab.baseAddress!,
                                       lock: glb.count == cfg.count ? glb.baseAddress : nil)
        var geometry: BeltGeometry?
        // Mit Kopplung (#187) stempelt der Teilschritt eines wandernden Laufs
        // nur dessen FLACHE Knoten (Mobilität > 0); seine steilen Strecken
        // bekommen wie die festen Läufe einen Linien-Carve über den ganzen
        // Schritt (`only == nil`). Seit die wandernden Läufe die ganzen Flüsse
        // von der Quelle bis zur Mündung sind, stempelte jeder Teilschritt
        // sonst den ganzen Gebirgsabschnitt mit (gemessen belt.stamp 3,8 →
        // 8,0 ms je Schritt).
        let split = cfg.meanderBeltCoupling
        let channelRange = only.map { $0..<($0 + 1) } ?? meander.channels.indices
        for ci in channelRange {
            let ch = meander.channels[ci]
            guard only != nil || split || !MeanderState.migrates(ch, cfg) else { continue }
            let part = !split ? 0 : (only != nil ? 1 : (MeanderState.migrates(ch, cfg) ? 2 : 0))
            geometry = beltStampChannel(ch, dt: dt, part: part, ageAtEnd: ageAtEnd,
                                        lockHere: split && only != nil, buffers: buffers)
        }
        return geometry
        }}}}}}}
    }

    private struct BeltStampBuffers {
        let bed: Bed
        let hf: UnsafePointer<Double>
        let veg: UnsafeMutablePointer<Double>
        let channel: UnsafeMutablePointer<Bool>
        let belt: UnsafeMutablePointer<Bool>
        let age: UnsafeMutablePointer<Double>
        let lock: UnsafeMutablePointer<Bool>?
    }

    /// Ein Lauf auf offenen Roh-Puffern. Der Aufrufer garantiert disjunkte
    /// Lese- UND Schreibfenster aller gleichzeitig laufenden Stempel.
    private func beltStampChannel(_ ch: RiverChannel, dt: Double, part: Int, ageAtEnd: Double,
                                  lockHere: Bool, buffers: BeltStampBuffers) -> BeltGeometry? {
        let cs = cfg.cellSize, nn = n
        let rel = Terrain.relaxFraction(dt: dt, tau: max(1e-6, cfg.meanderBeltRelaxYears))
        let capF = stepCapFraction(dt)
        let m = cfg.mExp, cellArea = cs * cs
        let skew = cfg.meanderBeltPoolSkew, gain = cfg.meanderBeltPoolGain
        let barTop = cfg.meanderBarTopDepth, barW = cfg.meanderBarWidths
        let depthK = cfg.meanderBeltDepthPerWidth * cs
        let bed = buffers.bed, phf = buffers.hf, pveg = buffers.veg
        let pchan = buffers.channel, pbelt = buffers.belt, page = buffers.age, plock = buffers.lock
        let pice = bed.locked, iceOn = bed.locked != nil
        let split = cfg.meanderBeltCoupling
        @inline(__always) func cell(_ x: Double, _ z: Double) -> Int {
            min(max(Int(z.rounded()), 0), nn - 1) * nn + min(max(Int(x.rounded()), 0), nn - 1)
        }
        @inline(__always) func blocked(_ k: Int) -> Bool {
            phf[k] - bed.h[k] > 0.02 || (iceOn && pice![k])
        }
            let nodes = ch.nodes, c = nodes.count
            guard c >= 3 else { return nil }
            // 0: alle Knoten; 1: nur flache (Teilschritt eines wandernden Laufs);
            // 2: nur steile (wandernder Lauf am Schrittende).
            let g = MeanderState.beltGeometry(ch, config: cfg,
                                              heightAt: { Terrain.bilinear(bed.h, nn, $0.x, $0.z) })
            let firstMob = g.mob.firstIndex(where: { $0 > 0 })
            let lastMob = g.mob.lastIndex(where: { $0 > 0 })
            if part == 1 && firstMob == nil { return g }
            let needsLateral = part != 2 && firstMob != nil
            // Krümmungs-Mittelung nur über dem mobilen Fenster (Teilschritt braucht nur dort Kolk/Gleithang)
            let bendCurv = needsLateral
                ? MeanderState.bendCurvature(g, config: cfg, activeRange: firstMob!...lastMob!)
                : []
            // Bezug: tiefste Sohle des Querschnitts je Knoten, über ±2 Knoten
            // gemittelt — nur gebraucht, wo ein flacher Knoten in ±2 liegt.
            var floorH = needsLateral ? [Double](repeating: 0, count: c) : []
            let fLo = part == 1 ? max(0, firstMob! - 2) : 0
            let fHi = part == 1 ? min(c - 1, lastMob! + 2) : (c - 1)
            if needsLateral && fLo <= fHi {
                for i in fLo...fHi {
                    if part == 1 || split {
                        var flat = false
                        for j in max(0, i - 2)...min(c - 1, i + 2) where g.mob[j] > 0 { flat = true; break }
                        if !flat { continue }
                    }
                    let w = 0.5 * g.width[i]
                    var lo = Double.infinity, s = -w
                    while s <= w + 1e-9 {
                        lo = min(lo, bed.h[cell(nodes[i].x + g.nx[i] * s, nodes[i].z + g.nz[i] * s)])
                        s += 0.5
                    }
                    floorH[i] = lo
                }
            }
            var budget = 0.0
            let sLo = part == 1 ? max(1, firstMob!) : 1
            let sHi = part == 1 ? min(c - 2, lastMob!) : (c - 2)
            if sLo <= sHi {
                for i in sLo...sHi {
                let ck = cell(nodes[i].x, nodes[i].z)
                if blocked(ck) { budget = 0; continue }
                let b = g.width[i], w = 0.5 * b
                if g.mob[i] <= 0 {
                    if part == 1 { budget = 0; continue }
                    // Steile Strecke: Linien-Carve wie `meanderStamp` (Teil 1).
                    let a = nodes[i], bn = nodes[i + 1]
                    let d = dist(a, bn)
                    let hbn = Terrain.bilinear(bed.h, nn, bn.x, bn.z)
                    let ha = Terrain.bilinear(bed.h, nn, a.x, a.z)
                    let segSlope = d > 1e-6 ? max(0, ha - hbn) / (d * cs) : 0
                    let qA = 0.5 * (ch.discharge[i] + ch.discharge[i + 1]) * cellArea
                    let carveRate = cfg.meanderCarve * pow(max(qA, 0), m) * segSlope * dt
                    let steps = max(1, Int(d.rounded(.up)))
                    for sIdx in 0...steps {
                        let t = Double(sIdx) / Double(steps)
                        let k = cell(a.x + (bn.x - a.x) * t, a.z + (bn.z - a.z) * t)
                        if blocked(k) { continue }
                        pchan[k] = true; pveg[k] = 0
                        _ = erodeCell(k, min(carveRate, max(0, bed.h[k] - hbn) * capF), bed)
                    }
                    budget = 0
                    continue
                }
                if part == 2 { budget = 0; continue }
                var ref = 0.0
                let lo = max(0, i - 2), hi = min(c - 1, i + 2)
                for j in lo...hi { ref += floorH[j] }
                ref /= Double(hi - lo + 1)
                let depth = depthK * b
                let a = min(1, abs(bendCurv[i]) * b * gain)
                // Profil-Maximum von (1 − e²)(1 + κe), κ = skew·a: Nullstelle der
                // Ableitung −3κe² − 2e + κ. `z_bf` steht genau so hoch, dass der
                // tiefste Punkt des Zielprofils auf der heutigen Sohle liegt —
                // ein Fixpunkt. Mit einem pauschalen Aufschlag wanderte der Bezug
                // je Teilschritt um die Differenz nach oben (Sohlen-Ratsche).
                let kap = skew * a
                let eMax = kap > 1e-9 ? (-2 + (4 + 12 * kap * kap).squareRoot()) / (6 * kap) : 0
                let zbf = ref + depth * (1 - eMax * eMax) * (1 + kap * eMax)
                let sgn = bendCurv[i] > 0 ? -1.0 : 1.0            // Außen-Normale wie `meanderStamp`
                let ox = sgn * g.nx[i], oz = sgn * g.nz[i]
                let barTarget = zbf - barTop * depth
                // Außen → Mitte → innen: erst abtragen, dann innen ablagern.
                var s = w + 0.5, last = -1
                let inner = -(w + barW * b)
                while s >= inner - 1e-9 {
                    let k = cell(nodes[i].x + ox * s, nodes[i].z + oz * s)
                    s -= 0.5
                    let eta = (s + 0.5) / max(1e-6, w)
                    // Außerhalb des Betts kann nur noch Budget abgelagert werden.
                    if eta < -1 && budget <= 0 { break }
                    if k == last || blocked(k) { continue }
                    last = k
                    if eta >= -1 {
                        let e = max(-1, min(1, eta))
                        // Nie über die Bank-Oberkante: ab κ·η < −1 kippt der Faktor
                        // (1 + κη) ins Negative, das Ziel läge über bankfull.
                        let target = min(barTarget, zbf - depth * (1 - e * e) * (1 + skew * a * e))
                        pchan[k] = true; pbelt[k] = true; pveg[k] = 0
                        if lockHere { plock![k] = true }
                        if eta > -0.5 { page[k] = -1 }
                        if bed.h[k] > target {
                            budget += erodeCell(k, (bed.h[k] - target) * rel, bed)
                        } else if budget > 0 {
                            let dep = min(budget, (target - bed.h[k]) * rel)
                            depositCell(k, dep, bed); budget -= dep
                        }
                    } else if bed.h[k] < barTarget && budget > 0 {
                        let gap = barTarget - bed.h[k]
                        let dep = min(budget, gap * rel)
                        depositCell(k, dep, bed); budget -= dep
                        let atBar = barTarget - bed.h[k] <= 0.25 * depth
                        if atBar && (page[k] < 0 || gap > 0.2 * depth) { page[k] = ageAtEnd; pveg[k] = 0 }
                        if page[k] >= 0 { pbelt[k] = true; if lockHere { plock![k] = true } }
                    }
                }
            }
            }
        return g
    }

    // MARK: - Kopplung Gürtel ↔ Entwässerung (Issue #187)

    /// Ein Abschnitt des D8-Netzes nach dem Hack-Prinzip: von einer Quelle die
    /// Empfänger-Kette entlang, solange der Abschnitt an jedem Zusammenfluss der
    /// größere Zufluss ist; er endet vor Meer oder See oder IN der
    /// Zusammenfluss-Zelle mit einem größeren Fluss (die gehört dann dem).
    struct DrainageSegment {
        var cells: [Int32]
        var endsAtConfluence: Bool
    }

    /// Hack-Abschnitte des großen D8-Netzes (Einzugsgebiet ab `meanderMinCells`,
    /// über dem Meer), in Index-Reihenfolge der Quellen. EINE Regel für die
    /// Trasse (`MeanderState.traceHorton`) und die Kopplung je Schritt.
    static func drainageSegments(config cfg: SimConfig, h: UnsafePointer<Double>, hf: UnsafePointer<Double>,
                                 area: UnsafePointer<Double>, receiver: UnsafePointer<Int32>) -> [DrainageSegment] {
        let nn = cfg.n, cnt = cfg.count, sea = cfg.sea
        let lakeEps = MeanderState.traceLakeDepth
        let minA = cfg.meanderMinCells * cfg.cellSize * cfg.cellSize
        @inline(__always) func big(_ k: Int) -> Bool { hf[k] > sea && area[k] >= minA }
        // Größter großer Zufluss einer Zelle (Gleichstand: kleinerer Index), −1 = keiner.
        @inline(__always) func bestDonor(_ r: Int) -> Int {
            let ri = r % nn, rj = r / nn
            var best = -1
            for dj in -1...1 {
                let j = rj + dj
                guard j >= 0, j < nn else { continue }
                for di in -1...1 where di != 0 || dj != 0 {
                    let i = ri + di
                    guard i >= 0, i < nn else { continue }
                    let d = j * nn + i
                    guard Int(receiver[d]) == r, big(d) else { continue }
                    if best < 0 || area[d] > area[best] || (area[d] == area[best] && d < best) { best = d }
                }
            }
            return best
        }
        // Quellen (große Zellen ohne großen Zufluss) UND je Quelle ihr kompletter
        // Hack-Abschnitt parallel in Blöcken (auf coreCount geklemmt statt 64 Tasks):
        // Jeder Abschnitt liest nur `h`, `hf`, `area`, `receiver` und ist von allen
        // anderen Quellen völlig unabhängig; anschließendes Zusammenfügen in
        // Block-Reihenfolge ist bit-identisch zur seriellen Schleife.
        let chunks = max(1, min(Terrain.coreCount, cnt / 4096))
        var found = [[DrainageSegment]](repeating: [], count: chunks)
        found.withUnsafeMutableBufferPointer { fb in
            let pf = fb.baseAddress!
            DispatchQueue.concurrentPerform(iterations: chunks) { ch in
                var segs: [DrainageSegment] = []
                var cells: [Int32] = []
                cells.reserveCapacity(64)
                for s in (cnt * ch / chunks)..<(cnt * (ch + 1) / chunks) where big(s) && bestDonor(s) < 0 {
                    cells.removeAll(keepingCapacity: true)
                    cells.append(Int32(s))
                    var c = s, confluence = false
                    while cells.count < cnt {
                        let r = Int(receiver[c])
                        if r < 0 || r >= cnt || r == c { break }
                        if hf[r] <= sea || hf[r] - h[r] > lakeEps { break }
                        cells.append(Int32(r))
                        if bestDonor(r) != c { confluence = true; break }
                        c = r
                    }
                    if cells.count >= 3 {
                        segs.append(DrainageSegment(cells: cells, endsAtConfluence: confluence))
                    }
                }
                pf[ch] = segs
            }
        }
        var totalSegs = 0
        for ch in 0..<chunks { totalSegs += found[ch].count }
        var out: [DrainageSegment] = []
        out.reserveCapacity(totalSegs)
        for ch in 0..<chunks { out.append(contentsOf: found[ch]) }
        return out
    }

    /// Kopplung der Gürtel-Linien an die D8-Entwässerung, einmal je Schritt auf
    /// dem frischen Abflussfeld, VOR der Migration (Issue #187). Bis dahin liefen
    /// Linie und Entwässerung getrennt: `refreshBeltDischarge` übernahm über ein
    /// laufendes Maximum den Abfluss jedes größeren Flusses, den eine Linie
    /// einmal berührte, und die Linie wanderte damit breit und beweglich neben
    /// der Rinne den Hang hinauf (`docs/zielbild-measurements.md` § Flüsse
    /// laufen bergauf). Jetzt gilt:
    ///
    /// - **Das D8-Netz bestimmt, WELCHE Flüsse es gibt** (`drainageSegments`):
    ///   je Hack-Abschnitt ein Lauf, der kleinere endet am Zusammenfluss. Der
    ///   Abfluss jedes Knotens ist das Einzugsgebiet der Abschnittszelle, an der
    ///   er liegt, entlang des Laufs monoton — ein Erben über eine Berührung mit
    ///   einem größeren Fluss ist damit ausgeschlossen, ebenso ein Lauf ohne
    ///   Fluss darunter. Ein neuer oder durch einen Pinselstrich verlorener
    ///   Fluss bekommt im nächsten Schritt seine Linie aus D8.
    /// - **Die alte Linie bestimmt, WO er liegt** (Mäander-Gedächtnis): jeder
    ///   Knoten einer alten Linie, der höchstens `0,5 · b +
    ///   meanderBeltCouplingSlackCells` von einer Abschnittszelle liegt, gehört
    ///   dorthin; zusammenhängende Strecken (kurze Abweichungen eingeschlossen)
    ///   werden in den neuen Lauf übernommen.
    /// - **Avulsion:** verlässt eine Linie ihren Abschnitt über mindestens
    ///   `meanderBeltAvulsionWidths` Kanalbreiten, oder liegt das Gelände unter
    ///   dem abgekoppelten Stück im Mittel mehr als `meanderBeltAvulsionDepths`
    ///   Bankfull-Tiefen über dem Abschnitt dazwischen, ersetzen die
    ///   Abschnittszellen das Stück (geglättet); das verlassene Gerinne eines
    ///   wandernden Laufs wird Altarm mit `barAge`-Narbe.
    ///
    /// Geprüft wird am Schrittanfang, auf dem Abflussfeld des Betts, das der
    /// vorige Schritt gestempelt hat. Innerhalb des Schritts ändert sich das
    /// Abflussfeld nicht; nach der Wanderung eines großen Schritts sähe jede
    /// weite Bewegung wie eine Abkopplung aus.
    private func coupleBeltToDrainage(dt: Double) {
        let nn = n, cnt = cfg.count, cs = cfg.cellSize
        let cellArea = cs * cs
        guard cellArea > 0, cellArea.isFinite else { return }
        mark("belt.couple.segments")
        let segs = h.withUnsafeBufferPointer { hb in
            hf.withUnsafeBufferPointer { hfb in
            area.withUnsafeBufferPointer { ab in
            receiver.withUnsafeBufferPointer { rb in
                Terrain.drainageSegments(config: cfg, h: hb.baseAddress!, hf: hfb.baseAddress!,
                                         area: ab.baseAddress!, receiver: rb.baseAddress!)
            }}}
        }
        if segOwner.count != cnt {
            segOwner = [Int32](repeating: -1, count: cnt); segPos = [Int32](repeating: -1, count: cnt)
        }
        // PERF: Über Roh-Zeiger schreiben und zurücksetzen; direkter Zugriff auf
        // `self.segOwner[k]` / `self.segPos[k]` rief je Abschnittszelle (und im
        // `defer`) `swift_beginAccess` / `AccessSet::insert` auf.
        segOwner.withUnsafeMutableBufferPointer { ob in
            segPos.withUnsafeMutableBufferPointer { pb in
                let po = ob.baseAddress!, pp = pb.baseAddress!
                for (s, seg) in segs.enumerated() {
                    let s32 = Int32(s)
                    let own = seg.endsAtConfluence ? seg.cells.count - 1 : seg.cells.count
                    seg.cells.withUnsafeBufferPointer { cb in
                        let pc = cb.baseAddress!
                        for p in 0..<own {
                            let idx = Int(pc[p])
                            po[idx] = s32; pp[idx] = Int32(p)
                        }
                    }
                }
            }
        }
        defer {
            segOwner.withUnsafeMutableBufferPointer { ob in
                segPos.withUnsafeMutableBufferPointer { pb in
                    let po = ob.baseAddress!, pp = pb.baseAddress!
                    for seg in segs {
                        seg.cells.withUnsafeBufferPointer { cb in
                            for p in 0..<cb.count {
                                let idx = Int(cb[p])
                                po[idx] = -1; pp[idx] = -1
                            }
                        }
                    }
                }
            }
        }
        let old = meander.channels
        let slack = cfg.meanderBeltCouplingSlackCells
        let kW = cfg.meanderBeltAvulsionWidths, xD = cfg.meanderBeltAvulsionDepths
        let tAv = cfg.meanderBeltAvulsionYears
        let depthK = cfg.meanderBeltDepthPerWidth * cs
        let sea = cfg.sea, lakeEps = MeanderState.traceLakeDepth

        mark("belt.couple.match")
        // 1. Zuordnung der alten Knoten: nächste Abschnittszelle in Reichweite.
        //    Bleibt der Vorgänger-Abschnitt höchstens eine Zelle weiter als der
        //    nächste, gilt er (keine Flackern an Zusammenflüssen; die
        //    Zusammenfluss-Zelle am Ende zählt dabei zum Vorgänger-Abschnitt).
        // Parallel je Lauf (jeder schreibt nur seine Knoten in die flachen
        // Puffer), danach je Lauf als Array — bit-gleich zur seriellen Schleife.
        var off = [Int](repeating: 0, count: old.count + 1)
        for l in old.indices { off[l + 1] = off[l] + old[l].nodes.count }
        var flatSeg = [Int32](repeating: -1, count: off[old.count]), flatPos = flatSeg
        let cfgL = cfg
        segOwner.withUnsafeBufferPointer { ob in
        segPos.withUnsafeBufferPointer { pb in
        hf.withUnsafeBufferPointer { hfb in
        h.withUnsafeBufferPointer { hb in
        flatSeg.withUnsafeMutableBufferPointer { fsb in
        flatPos.withUnsafeMutableBufferPointer { fpb in
            let po = ob.baseAddress!, pp = pb.baseAddress!, phf = hfb.baseAddress!, ph = hb.baseAddress!
            let fs = fsb.baseAddress, fp = fpb.baseAddress
            let lineChunks = max(1, min(old.count, Terrain.coreCount * 4))
            DispatchQueue.concurrentPerform(iterations: lineChunks) { cc in
            for l in (old.count * cc / lineChunks)..<(old.count * (cc + 1) / lineChunks) {
                let ch = old[l], base = off[l]
                var prev: Int32 = -1
                for (i, p) in ch.nodes.enumerated() {
                    let ci0 = min(max(Int(p.x.rounded()), 0), nn - 1), cj0 = min(max(Int(p.z.rounded()), 0), nn - 1)
                    let k0 = cj0 * nn + ci0
                    if phf[k0] <= sea || phf[k0] - ph[k0] > lakeEps { prev = -1; continue }   // bleibt −1
                    let tol = 0.5 * MeanderState.beltWidthCells(discharge: ch.discharge[i], config: cfgL) + slack
                    let rMax = Int(tol.rounded(.up)) + 1
                    var bS: Int32 = -1, bP: Int32 = -1, bD2 = tol * tol + 1e-9
                    var vS: Int32 = -1, vP: Int32 = -1, vD2 = tol * tol + 1e-9  // Vorgänger-Abschnitt
                    let prevEnd = prev >= 0 && segs[Int(prev)].endsAtConfluence ? Int(segs[Int(prev)].cells.last!) : -1
                    for r in 0...rMax {
                        if bS >= 0, Double(r) - 0.75 > bD2.squareRoot() + 1.0 { break }
                        for dj in -r...r {
                            let j = cj0 + dj
                            guard j >= 0, j < nn else { continue }
                            let edge = abs(dj) == r
                            var di = -r
                            while di <= r {
                                let i2 = ci0 + di
                                if i2 >= 0, i2 < nn {
                                    let k = j * nn + i2
                                    let ow = po[k]
                                    if ow >= 0 || k == prevEnd {
                                        let dx = Double(i2) - p.x, dz = Double(j) - p.z
                                        let d2 = dx * dx + dz * dz
                                        if ow >= 0, d2 < bD2 { bS = ow; bP = pp[k]; bD2 = d2 }
                                        if prev >= 0, ow == prev || k == prevEnd, d2 < vD2 {
                                            vS = prev
                                            vP = k == prevEnd ? Int32(segs[Int(prev)].cells.count - 1) : pp[k]
                                            vD2 = d2
                                        }
                                    }
                                }
                                if r == 0 { break }
                                di += edge ? 1 : 2 * r
                            }
                        }
                    }
                    if vS >= 0, vD2.squareRoot() <= bD2.squareRoot() + 1.0 { bS = vS; bP = vP }
                    fs![base + i] = bS; fp![base + i] = bP
                    prev = bS
                }
            }
            }
        }}}}}}
        let mSeg = old.indices.map { Array(flatSeg[off[$0]..<off[$0 + 1]]) }
        let mPos = old.indices.map { Array(flatPos[off[$0]..<off[$0 + 1]]) }

        mark("belt.couple.runs")
        // 2. Strecken je alter Linie: Anker (gleicher Abschnitt, Position stromab
        //    nicht rückwärts), Anker desselben Abschnitts über kurze
        //    Abweichungen verschmolzen; lange oder überhöhte Abweichungen
        //    zwischen zwei Ankern sind Avulsionen.
        struct Run { var line: Int; var i0: Int; var i1: Int; var pa: Int; var pb: Int }
        struct Gap { var line: Int; var i0: Int; var i1: Int; var runA: Int; var runB: Int; var width: Double }
        var runs: [Run] = [], gaps: [Gap] = []
        var segRuns = [[Int]](repeating: [], count: segs.count)
        for (l, ch) in old.enumerated() {
            let sg = mSeg[l], ps = mPos[l], c = ch.nodes.count
            var anchors: [Run] = []
            var i = 0
            while i < c {
                guard sg[i] >= 0 else { i += 1; continue }
                var a = Run(line: l, i0: i, i1: i, pa: Int(ps[i]), pb: Int(ps[i]))
                var j = i + 1
                while j < c, sg[j] == sg[i], Int(ps[j]) >= a.pb - 3 { a.i1 = j; a.pb = max(a.pb, Int(ps[j])); j += 1 }
                anchors.append(a)
                i = j
            }
            var cum = [Double](repeating: 0, count: c)
            for q in 1..<max(1, c) { cum[q] = cum[q - 1] + dist(ch.nodes[q - 1], ch.nodes[q]) }
            var k = 0
            var gapAtAnchor: [Int: Int] = [:]          // Anker-Index → Avulsion davor
            while k < anchors.count {
                var cur = anchors[k]
                let s = Int(sg[cur.i0])
                var next = k + 1
                var pendingGap: (Int, Int, Double, Int)? = nil
                while true {
                    var b = next
                    while b < anchors.count, Int(sg[anchors[b].i0]) != s { b += 1 }
                    guard b < anchors.count, anchors[b].pa >= cur.pb - 3 else { break }
                    let nb = anchors[b]
                    let bw = MeanderState.beltWidthCells(discharge: ch.discharge[cur.i1], config: cfg)
                    var avulse = cum[nb.i0] - cum[cur.i1] >= kW * bw
                    if !avulse, xD.isFinite, nb.i0 - cur.i1 >= 2, nb.pa > cur.pb {
                        var hl = 0.0, hp = 0.0
                        h.withUnsafeBufferPointer { hb in
                            for q in (cur.i1 + 1)..<nb.i0 { hl += Terrain.bilinear(hb.baseAddress!, nn, ch.nodes[q].x, ch.nodes[q].z) }
                        }
                        hl /= Double(nb.i0 - cur.i1 - 1)
                        for p in cur.pb...nb.pa { hp += h[Int(segs[s].cells[p])] }
                        hp /= Double(nb.pa - cur.pb + 1)
                        avulse = hl - hp > xD * depthK * bw
                    }
                    if avulse, tAv > 0 {
                        // Ereignis mit Rate 1/τ, solange die Abkopplung besteht:
                        // die Prüfung läuft je Schritt auf einem flackernden
                        // Abflussfeld, ohne Rate hing die Zahl der Avulsionen an
                        // der Schrittweite (gemessen dt 100 gegen 1000: 204 gegen
                        // 71 in 8000 Jahren). Deterministisch aus Zeit und Ort.
                        let key = years.bitPattern &* 0x9E37_79B9_7F4A_7C15
                            ^ UInt64(truncatingIfNeeded: segs[s].cells[0]) &* 0xD1B5_4A32_D192_ED03
                        let u = 0.5 * (MeanderState.hashUnit(key, cur.pb) + 1)
                        avulse = u < Terrain.relaxFraction(dt: dt, tau: tAv)
                    }
                    if avulse { pendingGap = (cur.i1, nb.i0, bw, b); break }
                    cur.i1 = nb.i1; cur.pb = max(cur.pb, nb.pb)
                    next = b + 1
                }
                runs.append(cur)
                let rid = runs.count - 1
                segRuns[s].append(rid)
                if let g = gapAtAnchor[k] { gaps[g].runB = rid }
                if let g = pendingGap {
                    // Der Anker danach beginnt die nächste Strecke dieses Abschnitts.
                    gaps.append(Gap(line: l, i0: g.0, i1: g.1, runA: rid, runB: -1, width: g.2))
                    gapAtAnchor[g.3] = gaps.count - 1
                }
                k = next
            }
        }

        mark("belt.couple.build")
        // 3. Je Abschnitt die Strecken ohne Überlappung (längste zuerst), dann
        //    der neue Lauf: Abschnittszellen, wo keine Strecke liegt.
        var selected = [Bool](repeating: false, count: runs.count)
        var newChannels: [RiverChannel] = []
        newChannels.reserveCapacity(segs.count)
        for (s, seg) in segs.enumerated() {
            let cand = segRuns[s].sorted {
                let a = runs[$0], b = runs[$1]
                let la = a.i1 - a.i0, lb = b.i1 - b.i0
                return la != lb ? la > lb : (a.line != b.line ? a.line < b.line : a.i0 < b.i0)
            }
            var acc: [Int] = []
            for r in cand where !acc.contains(where: { runs[$0].pa <= runs[r].pb && runs[r].pa <= runs[$0].pb }) {
                acc.append(r)
            }
            acc.sort { runs[$0].pa < runs[$1].pa }
            for r in acc { selected[r] = true }
            let L = seg.cells.count
            var nodes: [MeanderNode] = [], pos: [Int] = [], inserted: [Bool] = []
            var place: [Int] = [], born: [Double] = []
            func addCells(_ from: Int, _ to: Int, _ where_: Int) {
                guard from < to else { return }
                for p in from..<to {
                    let k = Int(seg.cells[p])
                    nodes.append(MeanderNode(x: Double(k % nn), z: Double(k / nn))); pos.append(p); inserted.append(true)
                    place.append(where_); born.append(years)
                }
            }
            var prevPb = -1, prevLine = -1
            for r in acc {
                let run = runs[r]
                addCells(prevPb + 1, run.pa, prevLine < 0 ? 0 : (prevLine == run.line ? 1 : 2))
                prevLine = run.line
                let ch = old[run.line]
                for i in run.i0...run.i1 {
                    nodes.append(ch.nodes[i])
                    pos.append(mSeg[run.line][i] == Int32(s) ? Int(mPos[run.line][i]) : -1)
                    // Älter als das Einwachsen: für den Render ausgewachsen,
                    // also wieder −∞ (hält `born` meist leer, s. dort).
                    let b = ch.bornAt(i)
                    inserted.append(false); place.append(-1)
                    born.append(b >= years - WaterRender.ribbonGrowYears ? b : -.infinity)
                }
                prevPb = max(prevPb, run.pb)
            }
            addCells(prevPb + 1, L, prevLine < 0 ? 0 : 3)
            guard nodes.count >= 3 else { continue }
            // Eingesetzte D8-Zellen glätten (Treppe aus Achtel-Richtungen), Nachbarn fest.
            for _ in 0..<3 {
                var prevNode = nodes[0]
                for i in 1..<(nodes.count - 1) {
                    let cur = nodes[i]
                    if inserted[i] {
                        nodes[i].x = cur.x + 0.5 * (0.5 * (prevNode.x + nodes[i + 1].x) - cur.x)
                        nodes[i].z = cur.z + 0.5 * (0.5 * (prevNode.z + nodes[i + 1].z) - cur.z)
                    }
                    prevNode = cur
                }
            }
            // Abfluss: Einzugsgebiet der zugeordneten Abschnittszelle, monoton; die
            // Zusammenfluss-Zelle gehört dem größeren Fluss, dort zählt die davor.
            var dis = [Double](repeating: 0, count: nodes.count)
            area.withUnsafeBufferPointer { ab in
                let pa = ab.baseAddress!
                var run = 0.0
                for i in nodes.indices {
                    if pos[i] >= 0 {
                        let p = seg.endsAtConfluence && pos[i] == L - 1 ? L - 2 : pos[i]
                        run = max(run, pa[Int(seg.cells[p])] / cellArea)
                    }
                    dis[i] = run
                }
            }
            for i in nodes.indices where dis[i] >= cfg.meanderBeltMinCells {
                if inserted[i] {
                    meander.coupledInserted += 1
                    if !acc.isEmpty { meander.insertedByPlace[place[i]] += 1 }
                } else { meander.coupledKept += 1 }
            }
            if let log = beltCouplingLog, (dis.last ?? 0) >= cfg.meanderBeltMinCells {
                var line = "SEG \(s) L=\(L) conf=\(seg.endsAtConfluence) Q=\(Int(dis.last ?? 0)) Kandidaten \(cand.count) gewählt:"
                for r in acc { let q = runs[r]; line += " [Lauf \(q.line) Knoten \(q.i0)…\(q.i1)/\(old[q.line].nodes.count) pos \(q.pa)…\(q.pb)]" }
                for r in cand where !acc.contains(r) { let q = runs[r]; line += " verworfen[Lauf \(q.line) \(q.i0)…\(q.i1) pos \(q.pa)…\(q.pb)]" }
                line += " eingesetzt \(inserted.filter { $0 }.count) von \(nodes.count)"
                log(line)
            }
            // Unverändert (eine Strecke = ein ganzer alter Lauf, nichts eingesetzt):
            // nicht neu abtasten.
            if acc.count == 1, runs[acc[0]].i0 == 0, runs[acc[0]].i1 == old[runs[acc[0]].line].nodes.count - 1,
               !inserted.contains(true) {
                newChannels.append(RiverChannel(nodes: nodes, discharge: dis, born: born))
            } else {
                newChannels.append(meander.resampled(RiverChannel(nodes: nodes, discharge: dis, born: born), config: cfg))
            }
        }
        // 4. Verlassene Gerinne: nur zwischen zwei übernommenen Strecken
        //    desselben Abschnitts, und nur wo der Lauf wanderte.
        for g in gaps where g.runB >= 0 && selected[g.runA] && selected[g.runB] {
            let ch = old[g.line]
            guard ch.discharge[g.i0] >= cfg.meanderBeltMinCells else { continue }
            meander.avulsions += 1
            abandonChannel(Array(ch.nodes[g.i0...g.i1]), width: g.width, age: dt)
        }
        meander.retraced += segs.indices.filter { segRuns[$0].isEmpty }.count
        meander.channels = newChannels
    }
    private var segOwner: [Int32] = []
    /// Ein fester Takt der Topologie mit Übertrag, am Schrittanfang geprüft.
    /// Bei dt 1000 bleibt die alte Reihenfolge erhalten. Feine Schritte
    /// verlängern die alte Linie bis zur nächsten Prüfung, statt jedes
    /// Flackern des D8-Netzes in einen neuen Linien-Schnitt zu übersetzen.
    func beltCouplingStep(dt: Double) -> Double {
        let interval = cfg.meanderBeltCouplingYears
        guard interval > 0, interval.isFinite else { return dt }
        let elapsed = floor(beltCouplingCarry / interval) * interval
        // Ein großer Schritt darf seine volle Exposition vorziehen, muss sie
        // dann aber auch abbuchen. Sonst würde der folgende kleine Aufruf
        // dieselben Jahre ein zweites Mal als Übertrag abrechnen.
        let exposure = elapsed > 0 ? max(dt, elapsed) : 0
        beltCouplingCarry = beltCouplingCarry - exposure + dt
        return exposure
    }
    private var segPos: [Int32] = []
    /// Diagnose-Haken (nur Tests): Aufbau der Läufe wandernder Größe je Schritt.
    var beltCouplingLog: ((String) -> Void)?

    /// Gürtelbett-Sperre der Tropfen an Zelle `k` (Diagnose).
    func beltBedLockedForTests(_ k: Int) -> Bool { dropletGateBuf.count > k && dropletGateBuf[k] }

    /// Zugang für die Kopplungs-Wächter (`BeltCouplingTests`): EIN
    /// Kopplungs-Pass auf dem aktuellen Abflussfeld, ohne Migration und Stempel.
    func coupleBeltForTests(dt: Double) {
        let ox0 = meander.oxbows.count
        coupleBeltToDrainage(dt: dt)
        plugOxbows(from: ox0)
    }

    /// Verlassenes Gerinne einer Avulsion: Altarm (wie nach einem Cutoff, s.
    /// `plugOxbows`/`fillOxbows`), wenn es mindestens
    /// `meanderBeltAbandonMinWidths` und höchstens so lang ist wie die längste
    /// abschnürbare Schleife, und `barAge`-Narbe über die Kanalbreite (danach
    /// Pionier-Grün und Wiese, `BarMaterial`). `age`: Alter am Schrittende —
    /// die Avulsion fällt auf den Schrittanfang.
    private func abandonChannel(_ nodes: [MeanderNode], width b: Double, age: Double) {
        guard nodes.count >= 4 else { return }
        var len = 0.0
        for i in 1..<nodes.count { len += dist(nodes[i - 1], nodes[i]) }
        if len >= cfg.meanderBeltAbandonMinWidths * b && len <= cfg.meanderBeltMaxLoopWidths * b {
            meander.abandon(nodes, age: age)
        }
        let nn = n, r = 0.5 * b, ri = Int(r.rounded(.up))
        for p in nodes {
            let ci0 = Int(p.x.rounded()), cj0 = Int(p.z.rounded())
            for j in max(0, cj0 - ri)...min(nn - 1, cj0 + ri) {
                for i in max(0, ci0 - ri)...min(nn - 1, ci0 + ri) {
                    let dx = Double(i) - p.x, dz = Double(j) - p.z
                    guard dx * dx + dz * dz <= r * r else { continue }
                    let k = j * nn + i
                    if barAge[k] < 0 { barAge[k] = age }
                }
            }
        }
    }

    // MARK: - Zeitschritt

    /// Tropfenzahl dieses Zeitschritts. Die Dichte ist auf n = 640 kalibriert
    /// (Tropfen ∝ Zeit × Fläche); der angebrochene Rest wandert über `dropCarry`
    /// in den nächsten Schritt, statt je Schritt auf 1 aufgerundet zu werden
    /// (Issue #2 Ursache 3 — bei dt = 0.2 J./Frame verlangte die Rate 0.09
    /// Tropfen und `max(1, …)` lieferte 1, also über 11× zu viel
    /// Droplet-Erosion gegenüber demselben Zeitraum als Sprung).
    /// Nicht `private`, damit der Wächter die reine Zählung prüfen kann.
    func dropletCount(dtYears dt: Double) -> Int {
        let density = Double(n * n) / (640.0 * 640.0)
        dropCarry += dt * cfg.hydraulicPerYear * density
        let drops = Int(dropCarry)
        dropCarry -= Double(drops)
        return drops
    }

    /// Baut den Faktor der Tropfen-DEPOSITION je Zelle (Issue #108) in
    /// `depositDampBuf`.
    ///
    /// Das gemeldete Problem: auf gealterten Welten liegt das Bett der Flüsse auf
    /// Umgebungsniveau — kein Taleinschnitt, das Wasser scheint auf dem Hang zu
    /// kleben. Gemessen (Kennzahl `ChannelIncision`, Quereinschnitt senkrecht zur
    /// Fließrichtung) kollabiert der Einschnitt in den ersten 25k Jahren um ~70 %,
    /// und die Kanalzellen steigen dabei ABSOLUT schneller als ihre Flanken: die
    /// Betten werden zugeschüttet. Ursache im Modell: im flachen Alters-Profil
    /// verliert der Tropfen Kapazität (`capacity ∝ Steigung·Speed·Wasser`, Boden
    /// `minSlope`) und lädt seine Fracht genau dort ab, wo er sie eben noch
    /// getragen hat — im Bett.
    ///
    /// Physisch fehlt dem Modell an dieser Stelle, dass ein WASSERFÜHRENDER Lauf
    /// Fracht durchtransportiert: Alluvialflüsse exportieren ihr Bettmaterial zur
    /// Mündung, statt ihr eigenes Bett zu verfüllen. Genau dafür gibt es den
    /// Präzedenzfall `HydraulicParams.channelDepositDamp` — nur kennt der bloß
    /// die MÄANDER-Maske (`isChannel`), also die paar großen Hauptläufe. Die
    /// dendritischen Läufe, aus denen der Look besteht, hatten keinen.
    ///
    /// Deshalb hier der Dämpfer über den D8-Abfluss (Erosions-Netz, nicht MFD —
    /// AGENTS.md § Rollentrennung), in Zellen gemessen wie `braidMinCells`, mit
    /// smoothstep-Übergang. Auf Mäanderzellen gewinnt der stärkere der beiden
    /// Dämpfer (s. `Hydraulic.erode`). Der nicht abgelegte Rest bleibt beim
    /// Tropfen in Suspension — die Massenbilanz stimmt, das Material erreicht das
    /// Bett erst weiter unten oder das Meer.
    ///
    /// AUS (`cfg.flowDepositDamp` = 1) → leeres Feld und damit bit-identische
    /// Arithmetik zum Stand vor #108.
    ///
    /// Der Dämpfer wirkt im SIM-SCHRITT, nicht im Tropfen-Spin-up der
    /// Generierung (`spinUpStreamMap`): dessen Charge bildet keine Zeit ab,
    /// sondern legt die erste Stream-Map auf das rohe Noise-Relief, in dem es
    /// noch kein etabliertes Lauf-Netz gibt, das etwas durchtransportieren
    /// könnte. Sie behält damit ihre kalibrierte Realisierung (dieselbe
    /// Begründung wie `firstDrop: nil` dort).
    private func buildDepositDamp() {
        let damp = cfg.flowDepositDamp
        guard damp < 1 else {
            if !depositDampBuf.isEmpty { depositDampBuf = [] }
            return
        }
        if depositDampBuf.count != cfg.count {
            depositDampBuf = .init(repeating: 1, count: cfg.count)
        }
        let cellArea = cfg.cellSize * cfg.cellSize
        let lo = cfg.channelFlowMinCells * cellArea
        let hi = max(lo + 1e-12, cfg.channelFlowFullCells * cellArea)
        let cnt = cfg.count
        area.withUnsafeBufferPointer { ab in
        depositDampBuf.withUnsafeMutableBufferPointer { db in
            let pa = ab.baseAddress!, pd = db.baseAddress!
            parallel(cnt) { klo, khi in
                for k in klo..<khi {
                    if pa[k] <= lo { pd[k] = 1; continue }
                    let x = min(1, (pa[k] - lo) / (hi - lo))
                    pd[k] = 1 - (1 - damp) * (x * x * (3 - 2 * x))
                }
            }
        }}
    }

    /// Simuliert `dtYears` Jahre. `dtYears` darf groß sein (Stream-Power ist
    /// implizit stabil); die Hangprozesse werden intern anteilig getaktet.
    /// Nicht-positive sowie nicht-endliche Zeitschritte (`dtYears <= 0`, `NaN`, `±inf`)
    /// führen defensiv zu einem No-op.
    public func step(dtYears dt: Double) {
        // Nicht-positive oder nicht-endliche Zeitschritte (<= 0, NaN, ±inf)
        // defensiv abfangen: Kein Zeitschritt darf die Simulationsuhr rückwärts
        // verstellen, Berechnungen mit NaNs vergiften oder Traps bei
        // Integer-Konvertierungen (z. B. in waveSchedule oder hillslopeDiffusion) auslösen.
        guard dt > 0, dt.isFinite else { return }

        // Abklingende Hebung (post-orogener Zerfall, s. Config). Der Relief-Servo
        // ist nur noch UNTERGRENZE: er greift, wenn U(t) das Relief nicht mehr
        // über `reliefTarget` hält — im normalen 100k-Fenster nie (gemessen). Das
        // max steckt UNTER dem Integral (s. upliftAmount), sonst hinge der
        // Übergangsschritt an der Schrittweite.
        mark("applyUplift")
        applyUplift(dt: dt, gatedAmount: upliftAmount(dt: dt,
                                                      floorPer100y: reliefServoRate()))
        // Regeneration frisch umgegrabener Flächen (Issue #26): trägt das
        // Mikro-Relief ein und räumt Mäander-/Altarmzustand ab, BEVOR der Flow
        // läuft — die Entwässerung dieses Schritts sieht das neue Gelände.
        // Ohne Störung (Normalfall) ein reiner Boolean-Test.
        mark("regenerateDisturbed")
        regenerateDisturbed(dt: dt)
        // Gesteinsfeld (Issue #12) auf die frische Höhe nachziehen, BEVOR ein
        // Erosionspass es liest: die freigelegte Schicht folgt aus h, und h hat
        // sich gerade durch die Hebung verschoben. Reine Ableitung, kein Zustand —
        // die Reihenfolge im Schritt ist damit unkritisch, nur „vor der Erosion".
        mark("updateLithology")
        updateLithology()
        flowStepCount &+= 1
        let mfdInterval = max(1, cfg.mfdUpdateInterval)
        // Braiding ist MFD-Physik, nicht bloß Rendering: dafür darf das Feld
        // niemals hinter dem aktuellen Terrain zurückbleiben.
        // In der Produktion ist dieser Zweig derzeit wirkungslos:
        // `mfdUpdateInterval` steht auf 1, das Feld würde also auch ohne
        // Braiding jeden Schritt gebaut (nachgemessen für Issue #43 —
        // `computeMFDArea` ist deshalb NICHT über den Takt einsparbar,
        // s. docs/perf-measurements.md §E).
        let updateMFD = cfg.braidingEnabled || Int(flowStepCount % UInt32(mfdInterval)) == 0
        computeFlow(includeMFD: updateMFD, dtYears: dt)
        mark("relaxWaterLevel")
        relaxWaterLevel(dt: dt) // Seespiegel folgt dem frischen hf (s. Doku dort)
        mark("updateSaltCrust")
        updateSaltCrust(dt: dt) // Playa-Kruste folgt der frischen Becken-Rolle
        // Gletscher (Issue #35): NACH dem Abflussfeld — das Eis fließt auf dem
        // Bett, das der frische Priority-Flood gesehen hat — und VOR jeder
        // fluvialen Höhenänderung des Schritts, weil `underIce` über den
        // Bett-Funnel JEDE fluviale Bett-Bewegung gatet (seit #96 auch die
        // Auslass-Inzision, die Tropfen und den Pinsel; Mäander und Braiding
        // liefen schon davor darüber) — auch den `meanderStamp` direkt
        // darunter. Ohne Eis (Normalfall der ersten Schritte, oder
        // `iceEnabled = false`) ein reiner Suchlauf, s. dort.
        mark("updateIce")
        updateIce(dt: dt)
        if cfg.meanderEnabled && cfg.meanderBelt {
            mark("meanderBelt")
            meanderBeltStep(dt: dt) // Migration + Gürtel-Stempel, gemeinsam sub-getaktet (Issue #174)
        } else if cfg.meanderEnabled {
            mark("migrateMeander")
            migrateMeander(dt: dt) // Läufe evolvieren (Abfluss/Mobilität aus frischem Flow)
            mark("meanderStamp")
            meanderStamp(dt: dt)   // Bett-Carve + laterale Ufer + Altarm-Pfropf, setzt isChannel
        }
        let passes = max(1, Int((dt / 100).rounded()))
        if cfg.hydraulicEnabled {
            // Prozess-Reihenfolge (FastScape/LEM-Konvention, docs/research-terrain-aging.md §4):
            // Uplift → Flow (oben) → Stream-Power/Auslass (Makro-Täler) → Droplet (Textur)
            // → Hangdiffusion (Grate runden) → Wave.
            // Delta (Issue #174): Abtrag der Inzision und des Bett-Carves
            // als Höhensumme davor und danach (s. `deltaDeposit`).
            let deltaOn = cfg.deltaTrapFraction > 0
            var deltaBefore = (sum: 0.0, land: 0)
            if deltaOn { mark("deltaYield"); deltaBefore = deltaHeightSum() }
            // 1) Fluviale Makro-Inzision zuerst: schneidet das kohärente Talnetz und
            //    entwässert die Becken zum Meer, an dem die Hänge dann „hängen".
            if cfg.outletIncision {
                mark("outletIncision"); outletIncision(dt: dt)
            }
            // Eigener Bett-Pass; channelTargetDepth = 0 schaltet ihn aus.
            mark("channelCarve"); channelCarve(dt: dt)
            var deltaYieldPerCell = 0.0
            if deltaOn {
                mark("deltaYield")
                let after = deltaHeightSum(collectMouths: true).sum
                deltaYieldPerCell = max(0, deltaBefore.sum - after) / Double(max(1, deltaBefore.land))
            }
            if cfg.basinFill { mark("fillLakes"); fillLakes(dt: dt) } // Rest-Senken verlanden (Rückfall)
            if cfg.puddleFillYears > 0 { mark("fillShallowPonds"); fillShallowPonds(dt: dt) }
            // 1b) Braiding: super-linearer Bedload-Transport auf dem MFD-Netz baut
            //     Mittelbänke/Fäden auf den großen Läufen (Verflechtung).
            if cfg.braidingEnabled { mark("braidPass"); braidPass(dt: dt) }
            // 2) Droplet-Erosion legt die feine dendritische Textur (nickmcd-Look) hinein.
            // Tropfen ∝ Zeit × Fläche (Dichte kalibriert auf n = 640).
            let drops = dropletCount(dtYears: dt)
            // Startnummer dieser Charge im fortlaufenden Tropfen-Strom
            // (s. `dropsEmitted`): der Zufall hängt damit an den tatsächlich
            // emittierten Tropfen, nicht an der Zahl der Schritte.
            let firstDrop = dropsEmitted
            dropsEmitted &+= UInt64(drops)
            mark("Hydraulic.erode")
            fill(&trackBuf, 0)
            buildDepositDamp()
            // Kanalmaske mit: auf Mäanderbetten ist die Tropfen-DEPOSITION gedämpft
            // (Reconciliation — sonst schütten die Tropfen das gecarvte Bett wieder zu).
            Hydraulic.erode(h: &h, rock: &rock, sed: &sed, n: n, count: drops,
                            seed: seed, floor: cfg.floor, p: cfg.hydraulic,
                            seaLevel: cfg.hydraulicSkipWaterSpawns ? cfg.sea : nil,
                            firstDrop: firstDrop,
                            hf: hf, receiver: receiver,
                            stream: streamMap,
                            channel: cfg.meanderEnabled ? isChannel : [],
                            // Abfluss-Dämpfer der Deposition (Issue #108): die
                            // dendritischen Läufe halten ihre Rinne, statt sie
                            // zuzuschütten. Leer, wenn der Dämpfer aus ist.
                            depositDamp: depositDampBuf,
                            // Vergletscherte Zellen bleiben unangetastet (#35);
                            // leer, solange nirgends Eis liegt.
                            // Gürtelbett (#174): dieselbe Sperre wie unter dem
                            // Eis, s. `beltDropletGate`.
                            bedLocked: beltDropletGate(),
                            // Dieselbe Gewichtungsregel wie beide Netze (Issue #36):
                            // wo Schmelzwasser abfließt, starten auch mehr Tropfen.
                            flowWeight: flowWeight,
                            erodibility: lithErodeK,
                            track: &trackBuf)
            // Besuchs-RATE (Besuche/Jahr) glätten (nickmcd lrate, dt-skaliert,
            // Zeitkonstante aus `streamMapMemoryYears`), dann sättigen: nur KONSISTENT befahrene
            // Zellen hellen auf, einzelne Zufallspfade verblassen.
            // EWMA + Sättigung fusioniert und datenparallel (per-Zelle unabhängig,
            // bit-identisch zu „erst EWMA-Loop, dann deriveStreamMap").
            mark("streamMapEWMA")
            let lam = Terrain.relaxFraction(dt: dt, tau: cfg.streamMapMemoryYears)
            let r0 = cfg.streamRefRate
            streamRate.withUnsafeMutableBufferPointer { srb in
            streamMap.withUnsafeMutableBufferPointer { smb in
            trackBuf.withUnsafeBufferPointer { tbb in
                let psr = srb.baseAddress!, psm = smb.baseAddress!, ptb = tbb.baseAddress!
                parallel(cfg.count) { lo, hi in
                    for k in lo..<hi {
                        let v = (1 - lam) * psr[k] + lam * (ptb[k] / dt)
                        psr[k] = v
                        psm[k] = v / (v + r0)
                    }
                }
            }}}
            // 2b) Auen-Aggradation: Flüsse schütten seitlich flache Schwemmböden auf
            //     (bankfull) → breite Niedrig-Gradient-Reaches für Mäander/Braiding.
            //     Nach dem Carve (Bett steht), vor der Diffusion (glättet die Aue).
            if cfg.floodplainEnabled { mark("floodplainAggradation"); floodplainAggradation(dt: dt) }
            // 2c) Delta-Schüttung (Issue #174): die Fracht des fluvialen Blocks
            //     landet vor der Mündung, VOR Hangdiffusion und Wellen — die
            //     überarbeiten die frische Front im selben Schritt.
            if deltaOn {
                mark("deltaDeposit"); deltaDeposit(yieldPerCell: deltaYieldPerCell)
            }
            // 3) Hangdiffusion (Bodenkriechen, D·∇²z): rundet Grate über die Zeit → altes
            // Terrain wird RUND statt immer spitzer (Appalachen-Signal, konvexe Kuppen).
            // Gesamtwirkung ∝ dt (chunking-/framerate-UNABHÄNGIG!): Echtzeit-Zeitraffer
            // (winziges dt/Frame) und große Sprünge (+10.000 J.) liefern dasselbe
            // Ergebnis. Früher lief die Diffusion je „Pass" (passes=max(1,dt/100)) →
            // bei dt≈0.2/Frame ~100× zu viel Rundung UND 100× zu viel Rechenzeit.
            // kappa auch auflösungs-unabhängig (∝ 1/dx² ∝ (n−1)², auf n=640 kalibriert).
            let refN = 639.0, m1 = Double(n - 1)
            let kYear = cfg.hillDiffusion * (m1 * m1) / (refN * refN) / 100.0 // war „kappa je 100-Jahr-Pass"
            let totalK = kYear * dt
            let nSub = max(1, Int((totalK / 0.2).rounded(.up)))   // stabil: Teilschritt-kappa ≤ 0.2
            let subK = totalK / Double(nSub)
            mark("hillslopeDiffusion")
            for _ in 0..<nSub { hillslopeDiffusion(base: subK) }
            // Küstenerosion ebenfalls sub-getaktet (Issue #2, s. waveSchedule).
            let wave = waveSchedule(dt: dt)
            mark("wavePass")
            for _ in 0..<wave.count { wavePass(relax: wave.relax) }
        } else {
            transportLimited(dt: dt) // massenerhaltend; auf Kanalzellen gedämpft (Reconciliation)
            // Testpfad: Diffusion und Wave bleiben verschränkt wie bisher. Beide
            // Taktzahlen sind ~dt/100, bei dt = k·100 also identisch zu vorher.
            let wave = waveSchedule(dt: dt)
            for i in 0..<max(passes, wave.count) {
                if i < passes { diffusionPass() }
                if i < wave.count { wavePass(relax: wave.relax) }
            }
        }
        if cfg.meanderEnabled && cfg.meanderBelt && cfg.meanderBeltCoupling && cfg.meanderBeltSymmetricStamp {
            // Strömung formt das Profil während der ganzen Zeit weiter. Eine
            // vollständige Formung nur VOR der Inzision/Diffusion ließ im
            // großen Schritt viel mehr Profil verschwinden als im Zeitraffer.
            // Die erste Hälfte steckt in den Migrations-Teilschritten oben.
            mark("belt.finishProfile")
            for ci in meander.channels.indices where MeanderState.migrates(meander.channels[ci], cfg) {
                beltStamp(dt: 0.5 * dt, only: ci, ageAtEnd: 0)
            }
        }
        // Klima-Vertikale (Issue #33) am Schrittende: Temperatur liest die FINALEN
        // Höhen, und die Schneebilanz muss vor `updateVegetation` stehen — dort
        // leitet `updateHeightBands` die Schneegrenze aus dem frischen Feld ab.
        mark("updateClimate")
        updateClimate(dt: dt)
        mark("updateVegetation")
        updateVegetation(years: dt)
        mark(nil)
        years += dt
    }

    /// Darstellungs-Seespiegel ratenbegrenzt Richtung Füllstand relaxieren
    /// (s. waterLevel-Doku). Exponentiell in Sim-Zeit → dt-invariant: Zeitraffer
    /// in Mini-Schritten und ein +10.000-J.-Sprung landen am selben Pegel.
    /// Per-Zelle unabhängig → parallel, bit-identisch zur sequenziellen Schleife.
    ///
    /// Gedämpft wird nur der ANSTIEG (der Sill-Plug des Sägezahns); fällt der
    /// Füllstand unter den Spiegel, folgt der Spiegel sofort. Bis Issue #174
    /// relaxierte er in beide Richtungen, und auf TROCKENEM Boden (hf = h) ist
    /// er dann nur eine verzögerte Kopie des Geländes: jede Zelle, die schneller
    /// sinkt als τ, trug für Jahrhunderte einen Geister-See der Tiefe des
    /// Abtrags. Der Mäandergürtel gräbt sein Bett in ~10 Jahren eine
    /// Kanaltiefe tief (`meanderBeltRelaxYears`); gemessen (Seed 1337, Jahr
    /// 2300) lagen damit ~2600 Zellen mit Spiegel > hf + 0,01 auf trockenem
    /// Boden (hf-Säule 0,0005, Spiegel-Säule 0,02 ≈ 10 Bankfull-Tiefen), als
    /// fleckige, halbdurchsichtige Seen in den Schlingen und im Kanal selbst
    /// (ohne Gürtel ~140; Messreihe `docs/zielbild-measurements.md`
    /// § Geister-Seen im Mäandergürtel). Ein echter Pegelfall (Auslass
    /// schneidet sich frei) läuft über die Inzision ohnehin allmählich. Die
    /// Physik liest `waterLevel` nicht; sie bleibt bit-identisch.
    private func relaxWaterLevel(dt: Double) {
        guard cfg.lakeLevelResponseYears > 0 else { waterLevel = hf; return }
        let wlam = Terrain.relaxFraction(dt: dt, tau: cfg.lakeLevelResponseYears)
        waterLevel.withUnsafeMutableBufferPointer { wlb in
        hf.withUnsafeBufferPointer { hfb in
            let pwl = wlb.baseAddress!, phf = hfb.baseAddress!
            parallel(cfg.count) { lo, hi in
                for k in lo..<hi {
                    pwl[k] = phf[k] < pwl[k] ? phf[k] : pwl[k] + (phf[k] - pwl[k]) * wlam
                }
            }
        }}
    }

    // MARK: - Diagnose (für Tests & UI)

    /// Reliefspanne über Land (max − min der Landzellen). Reine ANZEIGE-/Test-
    /// Kennzahl: sie hängt an genau zwei Extremzellen (das Minimum liegt per
    /// Definition knapp über `sea`, also IST sie im Wesentlichen die Höhe des
    /// höchsten Punkts). Als Regelsignal ist sie deshalb ungeeignet — dafür
    /// `landReliefRobust()`.
    /// Nicht-endliche Höhenwerte (NaN, ±inf) werden ignoriert; bei fehlenden
    /// Landzellen oder leerem Terrain wird defensiv 0 geliefert (Differenzüberlauf
    /// ist auf .greatestFiniteMagnitude gedeckelt).
    public func landRelief() -> Double {
        let count = min(cfg.count, h.count)
        guard count > 0, cfg.sea.isFinite else { return 0 }
        var lo = Double.greatestFiniteMagnitude, hi = -Double.greatestFiniteMagnitude
        for k in 0..<count where h[k] > cfg.sea && h[k].isFinite {
            lo = min(lo, h[k]); hi = max(hi, h[k])
        }
        if hi < lo { return 0 }
        return min(hi - lo, .greatestFiniteMagnitude)
    }

    /// Robuste Relief-Kennzahl: **95. Perzentil − Median der Landhöhen**, also
    /// die Spanne zwischen dem hohen und dem typischen Land. Sie ist
    /// das Regelsignal des Relief-Servos (Begründung + Messwerte: `Config.swift`
    /// bei `reliefTarget`): Einzelzellen (Nadelgipfel, Sculpt-Strich, tiefe
    /// Rinne) können sie nicht verschieben, weil beide Quantile aus zehntausenden
    /// Zellen kommen — gemessen (n=160, Seed 1337, 100k Jahre) verschiebt eine auf
    /// 1.4 gezogene Einzelzelle `landRelief()` von 0.5097 auf 1.2500 (+145 %),
    /// dieses Signal gar nicht (0.16211 → 0.16211): exakt gerechnet sind es
    /// +0.019 % (0.161965 → 0.161995) und damit weniger als eine Bin-Breite.
    public func landReliefRobust() -> Double {
        Terrain.landReliefRobust(heights: h, sea: cfg.sea)
    }

    /// Freie Funktion auf einem beliebigen Höhenfeld, damit Tests synthetische
    /// Felder (z. B. mit künstlichem Einzelgipfel) prüfen können, ohne das
    /// Terrain zu mutieren.
    public static func landReliefRobust(heights: [Double], sea: Double) -> Double {
        landHeightQuantiles(heights: heights, sea: sea).high
    }

    /// **Hochseitenrelief** = p95 − Median: wie weit steht das hohe Land über dem
    /// typischen? Identisch zu `landReliefRobust()` — das Regelsignal des Servos.
    public func landReliefHigh() -> Double { landReliefRobust() }

    /// **Talseitenrelief** = Median − p05: wie tief liegt das tiefe Land unter dem
    /// typischen? Die Gegenprobe zum Hochseitenrelief (Issue #26): eine
    /// eingeebnete Platte, in die sich Rinnen schneiden, differenziert sich
    /// ZUERST nach UNTEN — das Hochseitenrelief bleibt dabei lange bei ~0 und
    /// täuscht „keine Erholung" vor, während umgekehrt ein paar Rand- oder
    /// Rinnenzellen `landRelief()` (max−min) groß aussehen lassen, ohne dass
    /// sich die Fläche differenziert hätte. Erst BEIDE Seiten zusammen sagen,
    /// ob die Landschaft wieder Struktur hat.
    public func landReliefLow() -> Double {
        let q = Terrain.landHeightQuantiles(heights: h, sea: cfg.sea)
        return q.low
    }

    /// Beide robusten Relief-Halbseiten aus EINEM Histogramm-Pass:
    /// `high` = p95 − Median, `low` = Median − p05. Dünne Hülle um die
    /// allgemeine Quantil-Funktion darunter (Issue #4) — die drei Quantile
    /// kommen weiterhin aus einem einzigen Zählpass.
    public static func landHeightQuantiles(heights: [Double], sea: Double)
        -> (high: Double, low: Double) {
        guard let q = landHeightQuantiles(heights: heights, sea: sea,
                                          probs: [0.05, 0.5, 0.95])
        else { return (0, 0) } // zu wenig Land für Quantile
        return (q[2] - q[1], q[1] - q[0])
    }

    /// Quantile der Landhöhen (`heights > sea`) — EINZIGE Quelle für alle
    /// perzentil-gekoppelten Größen: die Relief-Halbseiten (oben, Issue #26) und
    /// die Höhenbänder für Vegetation/Fels/Schnee (`HeightBands`, Issue #4).
    /// `probs` muss AUFSTEIGEND sortiert sein (ein einziger Histogramm-Durchlauf
    /// bedient alle). `nil` = weniger als 20 Landzellen, also keine belastbare
    /// Verteilung.
    ///
    /// Histogramm statt Sortieren: die Kennzahlen laufen in JEDEM Zeitschritt über
    /// ~500k Landzellen (Frame-Budget!) — ein Zählpass ist O(N) und dazu exakt
    /// deterministisch (Integer-Zählung, keine Reihenfolge-Effekte).
    /// Spanne ab `sea` großzügig bis sea+2.0: die Sim deckelt Hebung bei
    /// isoHighClamp (0.90), nur Sculpting kommt überhaupt in die Nähe. Höhere
    /// Werte landen im letzten Bin — das kann ein Quantil nur dann sättigen,
    /// wenn so viel Land wirklich so hoch steht.
    /// Nicht-endliche Höhenwerte (NaN, ±inf) werden ignoriert; extreme Höhen
    /// (`>= sea + span`) landen sicher im obersten Bin ohne Int-Konvertierungsfehler.
    /// Preis: das Ergebnis ist auf Bin-Mitten quantisiert, jedes Quantil also
    /// ein Vielfaches von span/bins = 0.000488. Das ist 1/140 der Regelspanne des
    /// Servos (reliefServoBand 0.07) — dort bedeutungslos, aber beim Dokumentieren
    /// von Messwerten zu beachten: Unterschiede unterhalb einer Bin-Breite zeigt
    /// diese Funktion als 0 (s. Nadel-Messung oben).
    public static func landHeightQuantiles(heights: [Double], sea: Double,
                                           probs: [Double]) -> [Double]? {
        guard sea.isFinite, !probs.isEmpty else { return nil }
        for i in 0..<probs.count {
            let p = probs[i]
            guard p.isFinite && p >= 0 && p <= 1, i == 0 || p >= probs[i - 1] else { return nil }
        }
        let bins = 4096
        let span = 2.0
        var hist = [Int](repeating: 0, count: bins)
        var total = 0
        let top = sea + span
        heights.withUnsafeBufferPointer { hb in
        hist.withUnsafeMutableBufferPointer { histb in
            guard let ph = hb.baseAddress, let phist = histb.baseAddress else { return }
            let cnt = hb.count
            for k in 0..<cnt {
                let v = ph[k]
                guard v > sea && v.isFinite else { continue }
                let b = v >= top
                    ? bins - 1
                    : min(bins - 1, max(0, Int((v - sea) / span * Double(bins))))
                phist[b] += 1
                total += 1
            }
        }}
        guard total >= 20 else { return nil }
        var out = [Double](repeating: sea + span, count: probs.count)
        var cum = 0, next = 0
        for b in 0..<bins {
            cum += hist[b]
            while next < probs.count,
                  cum > Int((Double(total - 1) * probs[next]).rounded()) {
                out[next] = sea + (Double(b) + 0.5) * span / Double(bins)
                next += 1
            }
            if next == probs.count { break }
        }
        return out
    }

    /// Aktuell wirkende Servo-Hebung (pro 100 Jahre) aus dem robusten Relief-
    /// Signal. EINZIGE Quelle für `step()` und die Diagnose-Anzeige — beide
    /// hatten die Formel früher dupliziert und konnten auseinanderlaufen.
    public func reliefServoRate() -> Double {
        reliefServoRate(reliefSignal: landReliefRobust())
    }

    /// Dieselbe Formel auf einem SCHON GEMESSENEN Regelsignal — für Aufrufer, die
    /// `landReliefRobust()` ohnehin brauchen. Der Histogramm-Pass darunter kostet
    /// bei n = 832 gemessen ~1.4 ms (Messwert und Begründung: `updateHeightBands`),
    /// und die Diagnose-Anzeige zeigt Regelsignal, Talseite und Servo GEMEINSAM:
    /// ohne diesen Einstieg zählte sie dieselbe Höhenverteilung dreimal. Das
    /// Ergebnis ist identisch zur parameterlosen Variante, die Formel steht
    /// weiterhin nur hier.
    public func reliefServoRate(reliefSignal: Double) -> Double {
        guard cfg.reliefServoPer100y > 0, cfg.reliefServoBand > 0 else { return 0 }
        let deficit = cfg.reliefTarget - reliefSignal
        guard deficit > 0 else { return 0 }
        return cfg.reliefServoPer100y * min(1, deficit / cfg.reliefServoBand)
    }

    /// Aktuell wirkende Hebungsrate (pro 100 Jahre) der abklingenden Tektonik:
    /// `U(t) = U_floor + (U₀ − U_floor)·e^(−t/τ)` (docs/research-terrain-aging.md §3).
    /// Reine ANZEIGE-/Diagnose-Größe — `step()` integriert die Rate exakt über den
    /// Zeitschritt (`upliftAmount`), statt sie am Schrittanfang zu sampeln.
    public func upliftDecayRatePer100y() -> Double {
        let u0 = cfg.upliftDecayStartPer100y, uFloor = cfg.upliftDecayFloorPer100y
        guard cfg.upliftDecayYears > 0 else { return u0 }
        return uFloor + (u0 - uFloor) * exp(-years / cfg.upliftDecayYears)
    }

    /// Über das ABSOLUTE Zeitintervall `[a, b]` (Sim-Jahre) exakt integrierte
    /// abklingende Hebung, in Höheneinheiten bei `upliftBase == 1`:
    ///
    ///     ∫ U(t) dt / 100 = [U_floor·(b−a) + (U₀ − U_floor)·τ·(e^(−a/τ) − e^(−b/τ))] / 100
    ///
    /// Die geschlossene Form (statt „Rate am Schrittanfang × dt") ist die
    /// Framerate-Unabhängigkeit dieses Passes: die Summe über viele Mini-Schritte
    /// teleskopiert exakt zum Wert EINES großen Sprungs — Echtzeit-Zeitraffer und
    /// „+10.000 Jahre" tragen dieselbe Hebung ein.
    private func upliftDecayIntegral(from a: Double, to b: Double) -> Double {
        let u0 = cfg.upliftDecayStartPer100y, uFloor = cfg.upliftDecayFloorPer100y
        if u0 <= 0 && uFloor <= 0 { return 0 }
        let tau = cfg.upliftDecayYears
        guard tau > 0 else { return u0 * (b - a) / 100 } // τ = 0 → konstante Hebung
        let decayed = (u0 - uFloor) * tau * (exp(-a / tau) - exp(-b / tau))
        return (uFloor * (b - a) + decayed) / 100
    }

    /// Über `[years, years + dt]` integrierte abklingende Hebung — ohne
    /// Untergrenze (s. `upliftAmount(dt:floorPer100y:)`).
    func upliftDecayAmount(dt: Double) -> Double {
        upliftDecayIntegral(from: years, to: years + dt)
    }

    /// Die Hebung EINES Zeitschritts inklusive Servo-Untergrenze:
    ///
    ///     ∫ max(U(t), U_servo) dt / 100
    ///
    /// Das punktweise `max` unter dem Integral ist der Punkt: `max(∫U, U_servo·dt)`
    /// wäre schrittweiten-ABHÄNGIG. Schneidet U(t) die Untergrenze mitten in einem
    /// großen Schritt, gewinnt dort noch das Integral von U — bei kleineren
    /// Schritten übernähme im hinteren Teil bereits der Servo, und beide Wege
    /// lieferten verschiedene Ergebnisse (verletzt die Framerate-Invariante aus
    /// `AGENTS.md`). Der Schritt wird deshalb am SCHNITTPUNKT geteilt:
    ///
    ///     U(t*) = U_servo  ⇒  t* = −τ · ln((U_servo − U_floor) / (U₀ − U_floor))
    ///
    /// `t*` hängt nur von der Config ab, nicht von der Schrittweite — die Zerlegung
    /// ist damit über beliebige Unterteilungen additiv. (Die Servo-Rate selbst wird
    /// wie bei jedem Regler einmal pro Schritt aus dem aktuellen Relief gelesen;
    /// im Produktionsbetrieb ist sie über das ganze Alterungsfenster 0.)
    /// Wächter: `TerrainAging.testServoFloorCrossingIsFramerateIndependent`.
    func upliftAmount(dt: Double, floorPer100y: Double) -> Double {
        let a = years, b = years + dt
        let s = max(0, floorPer100y)
        if s <= 0 { return upliftDecayIntegral(from: a, to: b) }
        let u0 = cfg.upliftDecayStartPer100y, uFloor = cfg.upliftDecayFloorPer100y
        let tau = cfg.upliftDecayYears
        // Kein Abklingen konfiguriert (τ ≤ 0 oder U₀ == U_floor) → die Rate ist über
        // den Schritt konstant U₀, das punktweise max also trivial.
        guard tau > 0, u0 != uFloor else { return max(u0, s) * (b - a) / 100 }
        func rate(_ t: Double) -> Double { uFloor + (u0 - uFloor) * exp(-t / tau) }
        let rA = rate(a), rB = rate(b)
        if min(rA, rB) >= s { return upliftDecayIntegral(from: a, to: b) } // ganz über der Grenze
        if max(rA, rB) <= s { return s * (b - a) / 100 }                   // ganz darunter
        // Genau ein Schnittpunkt (U ist streng monoton), garantiert in (a, b).
        let ratio = (s - uFloor) / (u0 - uFloor)
        let tStar = min(max(-tau * log(ratio), a), b)
        return u0 > uFloor
            ? upliftDecayIntegral(from: a, to: tStar) + s * (b - tStar) / 100  // fallend: erst U, dann Boden
            : s * (tStar - a) / 100 + upliftDecayIntegral(from: tStar, to: b)  // steigend: erst Boden, dann U
    }

    /// **Mittlere Grat-Krümmung** — die in `docs/research-terrain-aging.md` §6 als
    /// fehlend benannte Alterungs-Diagnose. Mittelwert des diskreten Laplace
    /// `∇²z = (z_l + z_r + z_o + z_u − 4z) / dx²` über die GRAT-Zellen, definiert
    /// als Landzellen nahe der Wasserscheide: Einzugsgebiet ≤ `maxAreaCells`
    /// Zellen (Default 2 — die Zelle selbst plus höchstens ein Zubringer).
    ///
    /// Das Vorzeichen trägt die Aussage: **negativ = konvex** (Material verlassend,
    /// „Kuppe"). Ein junger, spitzer Kamm ist ein schmaler Knick → stark negativ;
    /// die lineare Hangdiffusion arbeitet genau proportional zu dieser Größe und
    /// treibt sie gegen 0 → **betragsmäßig kleiner = runder = älter**. Damit
    /// trennt die Kennzahl „jung spitz" von „alt rund" objektiv, was `landRelief()`
    /// allein nicht kann (ein flaches Terrain kann trotzdem spitze Grate haben).
    ///
    /// Auflösungs-Hinweis: `dx` folgt `cfg.cellSize`, die Feature-Skala des
    /// Generators dagegen dem Grid (`baseFreq / n`) — der ABSOLUTE Wert ist
    /// deshalb nur bei gleichem `n` vergleichbar. Als Alterungs-Signal wird sie
    /// über die ZEIT bei festem `n` gelesen.
    ///
    /// Achtung beim FRISCH generierten Terrain (t = 0): dort dominiert die
    /// Zell-Rauigkeit der Noise-Oberfläche, und ÷dx² verstärkt sie mit steigender
    /// Auflösung (gemessen Seed 1337: −0.045 bei n=160, −0.143 bei n=320, −0.977
    /// bei n=832; nach den ersten ~20k Sim-Jahren liegen alle drei bei −0.03 …
    /// −0.05). Für Alterungs-Vergleiche deshalb erst NACH dem Einschwingen der
    /// frischen Oberfläche ablesen.
    /// Nicht-endliche Höhenwerte (NaN, ±inf) werden ignoriert; bei fehlenden
    /// Landzellen, ungültigen Parametern oder leerem Terrain (n < 3) wird defensiv 0
    /// geliefert.
    public func ridgeCurvature(maxAreaCells: Double = 2) -> Double {
        guard n >= 3,
              h.count >= n * n,
              area.count >= n * n,
              cfg.sea.isFinite,
              maxAreaCells > 0,
              maxAreaCells.isFinite else { return 0 }
        let cellArea = cfg.cellSize * cfg.cellSize
        guard cellArea > 0, cellArea.isFinite else { return 0 }
        let limit = maxAreaCells * cellArea
        var sum = 0.0
        var count = 0
        for j in 1..<(n - 1) {
            for i in 1..<(n - 1) {
                let k = j * n + i
                let hk = h[k]
                guard hk > cfg.sea, hk.isFinite, area[k] <= limit else { continue }
                let hLeft = h[k - 1], hRight = h[k + 1], hUp = h[k - n], hDown = h[k + n]
                guard hLeft.isFinite, hRight.isFinite, hUp.isFinite, hDown.isFinite else { continue }
                let laplacian = (hLeft + hRight + hUp + hDown - 4 * hk) / cellArea
                guard laplacian.isFinite else { continue }
                sum += laplacian
                count += 1
            }
        }
        return count == 0 ? 0 : sum / Double(count)
    }

    public func maxHeight() -> Double { h.max() ?? 0 }
    public func minHeight() -> Double { h.min() ?? 0 }

    /// Gesamtes Einzugsgebiet, das an allen Senken (Meer + Ränder) ankommt.
    /// Muss der Gesamtzellzahl entsprechen: jede Zelle trägt genau ihre eigene
    /// Fläche bei und fließt zu genau einer Senke (Entwässerungs-Invariante).
    /// Gilt mit `cfg.rainWeightedFlow` UNVERÄNDERT: das Gewicht hat auf Land das
    /// Mittel 1 und über See exakt 1.0, Σ Startwerte bleibt also die Zellzahl
    /// (s. `updateRainWeight`; Wächter `testWeightedFlowKeepsDrainageTotal`).
    /// Auch mit Schmelzwasser (Issue #36) unverändert — genau DAS ist die
    /// Renormierung (`cfg.meltRunoffNormalized`, Wächter
    /// `MeltRunoff.testNormalizedMeltKeepsTheDrainageTotal`). Nur im verworfenen
    /// Zusatzwasser-Arm steigt die Summe; dort ist sie die Messgröße für das
    /// zusätzliche Wasser.
    /// Bei Puffer-Mismatch oder ungültiger Zellfläche wird defensiv 0 geliefert.
    public func totalOutletArea() -> Double {
        guard cfg.count > 0,
              receiver.count == cfg.count,
              area.count == cfg.count else { return 0 }
        let cellArea = cfg.cellSize * cfg.cellSize
        guard cellArea > 0, cellArea.isFinite else { return 0 }
        var sum = 0.0
        for k in 0..<cfg.count where receiver[k] < 0 && area[k].isFinite {
            sum += area[k]
        }
        return sum / cellArea
    }

    /// Zahl der Landzellen (`hf > sea`).
    /// Nicht-endliche Werte werden ignoriert; bei Puffer-Mismatch oder leerem Terrain wird defensiv 0 geliefert.
    public func landCellCount() -> Int {
        guard cfg.count > 0,
              hf.count == cfg.count,
              cfg.sea.isFinite else { return 0 }
        var c = 0
        for k in 0..<cfg.count where hf[k] > cfg.sea && hf[k].isFinite { c += 1 }
        return c
    }

    /// Anteil der Zellen, deren Empfänger sich gegenüber `other` NICHT geändert
    /// hat — misst die Fluss-Stabilität zwischen zwei Zuständen.
    /// Bei Puffer-Mismatch oder fehlenden Landzellen wird defensiv 1 geliefert.
    public func receiverAgreement(with other: [Int32]) -> Double {
        guard cfg.count > 0,
              hf.count == cfg.count,
              receiver.count == cfg.count,
              other.count == cfg.count,
              cfg.sea.isFinite else { return 1 }
        var same = 0, total = 0
        for k in 0..<cfg.count where hf[k] > cfg.sea && hf[k].isFinite {
            total += 1
            if receiver[k] == other[k] { same += 1 }
        }
        return total == 0 ? 1 : Double(same) / Double(total)
    }

    public func snapshotReceivers() -> [Int32] { receiver }
}

// MARK: - Zustands-Inventar (Speichern/Laden, Issue #8)

/// **Vollständiges Inventar** des Terrain-Zustands — die eine Stelle, an der
/// steht, WAS eine Welt ist. Die Kodierung (Magic, Version, Datei) macht
/// separat `WorldSnapshot.swift`; hier geht es nur um Vollständigkeit.
///
/// Aufnahmekriterium: jedes Feld, das ein `step()` LIEST, bevor es es schreibt,
/// plus alles, was Rendering/Diagnose sofort nach dem Laden brauchen (Issue #8,
/// Abnahmepunkt 5: kein Einschwingen des Seespiegels). Bewusst großzügig: auch
/// Felder, die `computeFlow` im nächsten Schritt neu ableitet (`hf`, `receiver`,
/// `area`, `areaMFD`, `order`, `floodParent`, `rain`, `rainWeight`,
/// `lithHardness`, `lithErodeK`, `temperature`, `playaBed`, `endorheicBasin`,
/// `endorheicInflow`) reisen mit — dann ist „geladener Zustand == gespeicherter
/// Zustand" feldweise prüfbar (`WorldSnapshotTests`) statt nur „läuft gleich
/// weiter", und der erste gerenderte Frame ist korrekt, ohne einen Sim-Schritt
/// zu erzwingen.
///
/// NICHT aufgenommen sind reine Arbeitspuffer, die ihr Pass vor dem ersten Lesen
/// vollständig überschreibt, sowie abgeleitete Felder. WELCHE das sind und WARUM,
/// steht seit Issue #98 an EINER Stelle: der Einordnung in
/// `SimCoreTests/StateInventoryTests.classification`. Sie spiegelt `Terrain` und
/// sortiert jede gespeicherte Eigenschaft als persistent, abgeleitet oder Scratch
/// ein — eine neue, nirgends einsortierte Eigenschaft macht den Wächter rot,
/// statt still an Inventar, Fingerprint und Spielstand vorbeizulaufen. (Nicht
/// gespiegelt und deshalb hier benannt: die Bin-Puffer des Mäander-Cutoff-Index
/// in `MeanderState` — auch sie sind Arbeitsspeicher.)
///
/// `upliftBase`, `lithBed` und `lithProvince` sind streng genommen fix je Seed,
/// reisen aber mit: `sculpt` koppelt in die Tektonik (`upliftBase` ist damit NICHT
/// mehr rein aus dem Seed ableitbar), und ein Nachbau per Noise-Code wäre eine
/// zweite Wahrheit über „was ist eine Welt".
struct TerrainState {
    // Kernfelder
    var h: [Double] = []
    var rock: [Double] = []
    var sed: [Double] = []
    var upliftBase: [Double] = []
    var rain: [Double] = []
    var rainWeight: [Double] = []        // leer, wenn cfg.rainWeightedFlow aus ist
    var lithHardness: [Double] = []      // leer, wenn cfg.lithologyEnabled aus ist
    var lithErodeK: [Double] = []        // leer, wenn cfg.lithologyEnabled aus ist
    var lithBed: [Double] = []           // leer, wenn cfg.lithologyEnabled aus ist
    var lithProvince: [Double] = []      // leer, wenn cfg.lithologyEnabled aus ist
    // Klima-Vertikale (Issue #33) — alle drei leer, wenn cfg.climateEnabled aus
    // ist. `ice` schreibt in diesem Ticket noch kein Pass; es reist trotzdem mit,
    // damit #35 keinen zweiten Versionssprung braucht (s. Feld-Doku in Terrain).
    var temperature: [Double] = []
    var snow: [Double] = []
    var ice: [Double] = []
    var veg: [Double] = []
    var vegClass: [UInt8] = []
    var riparian: [Double] = []          // Auwald-Nähe: liest der Mäander-Pass im NÄCHSTEN Schritt
    var heightBands: HeightBands = .legacyAbsolute
    // Entwässerung / Wasserhaushalt
    var hf: [Double] = []
    var waterLevel: [Double] = []        // Darstellungs-Seespiegel (ratenbegrenzt) — Abnahmepunkt 5
    var lakeBalance: [Double] = []       // Bilanz-Seespiegel abflussloser Becken (Issue #11)
    var saltCrust: [Double] = []
    var endorheicInflow: [Double] = []
    /// ROHBYTES der Becken-Rolle (`BasinRole.rawValue`) — das Speicherformat:
    /// so liegt das Feld im Schnappschuss (`WorldSnapshot.uint8Fields`).
    var endorheicBasin: [UInt8] = []
    var playaBed: [Bool] = []
    var receiver: [Int32] = []
    var order: [Int32] = []
    var floodParent: [Int32] = []
    var area: [Double] = []
    var areaMFD: [Double] = []
    // Fluss-Gedächtnis
    var isChannel: [Bool] = []
    var barAge: [Double] = []            // Gleithang-Bänke (Issue #174), -1 = keine
    var streamMap: [Double] = []
    var streamRate: [Double] = []
    // Störung / Regeneration (Issue #26)
    var disturb: [Double] = []
    var regenPending: [Double] = []
    var disturbActive = false
    // Mäander (Issue #7): Zentrumslinien + Altarme mit Alter
    var meanderChannels: [RiverChannel] = []
    var oxbows: [[MeanderNode]] = []
    var oxbowAge: [Double] = []
    // Zähler
    var years: Double = 0
    var seed: UInt32 = 0
    // Tropfen-Strom (Issue #2): BEIDE Zähler speisen die Droplet-Erosion und
    // gehören damit zum Determinismus. `dropsEmitted` ist die laufende Nummer
    // des nächsten Tropfens (legt über `Hydraulic.dropRNG` seinen Startpunkt
    // fest), `dropCarry` der angebrochene Tropfen aus dem letzten Schritt.
    // Ohne beide würde eine geladene Welt mit einem anderen Tropfen (bzw. bei
    // Frame-Schritten mit einer anderen Tropfenzahl) weiterlaufen als die
    // durchgehend simulierte — genau die Invariante, die WorldSnapshotTests
    // bit-genau prüft. (Ersetzt den früheren Schritt-Zähler `stepCount`.)
    var dropsEmitted: UInt64 = 0
    var dropCarry: Double = 0
    var beltCouplingCarry: Double = 0
    var flowStepCount: UInt32 = 0        // taktet das MFD-Intervall
}

extension Terrain {
    /// Kompletter Zustand als Wertkopie (Reihenfolge = Inventar oben).
    var state: TerrainState {
        var s = TerrainState()
        s.h = h; s.rock = rock; s.sed = sed; s.upliftBase = upliftBase
        s.rain = rain; s.rainWeight = rainWeight
        s.lithHardness = lithHardness; s.lithErodeK = lithErodeK
        s.lithBed = lithBed; s.lithProvince = lithProvince
        s.temperature = temperature; s.snow = snow; s.ice = ice
        s.veg = veg; s.vegClass = vegClass; s.riparian = riparian
        s.heightBands = heightBands
        s.hf = hf; s.waterLevel = waterLevel; s.lakeBalance = lakeBalance
        s.saltCrust = saltCrust; s.endorheicInflow = endorheicInflow
        s.endorheicBasin = endorheicBasin.map(\.rawValue); s.playaBed = playaBed
        s.receiver = receiver; s.order = order; s.floodParent = floodParent
        s.area = area; s.areaMFD = areaMFD
        s.isChannel = isChannel; s.streamMap = streamMap; s.streamRate = streamRate
        s.barAge = barAge
        s.disturb = disturb; s.regenPending = regenPending
        s.disturbActive = disturbActive
        s.meanderChannels = meander.channels
        s.oxbows = meander.oxbows
        s.oxbowAge = meander.oxbowAge
        s.years = years; s.seed = seed
        s.dropsEmitted = dropsEmitted; s.dropCarry = dropCarry
        s.beltCouplingCarry = beltCouplingCarry
        s.flowStepCount = flowStepCount
        return s
    }

    /// Übernimmt einen Zustand vollständig. Erwartet Feldlängen, die zur Config
    /// dieses Terrains passen — dafür sorgt der Leser in `WorldSnapshot.swift`
    /// (`SnapshotError.fieldLengthMismatch`).
    func restore(_ s: TerrainState) {
        h = s.h; rock = s.rock; sed = s.sed; upliftBase = s.upliftBase
        rain = s.rain; rainWeight = s.rainWeight
        lithHardness = s.lithHardness; lithErodeK = s.lithErodeK
        lithBed = s.lithBed; lithProvince = s.lithProvince
        temperature = s.temperature; snow = s.snow; ice = s.ice
        // Ableitung aus `ice` und deshalb NICHT im Inventar (#35): der erste
        // `updateIce` des nächsten Schritts baut sie neu, und bis dahin darf
        // keine Maske eines anderen Terrains stehen bleiben.
        underIce = []
        veg = s.veg; vegClass = s.vegClass; riparian = s.riparian
        heightBands = s.heightBands
        hf = s.hf; waterLevel = s.waterLevel; lakeBalance = s.lakeBalance
        saltCrust = s.saltCrust; endorheicInflow = s.endorheicInflow
        endorheicBasin = s.endorheicBasin.map(BasinRole.init(persisted:)); playaBed = s.playaBed
        receiver = s.receiver; order = s.order; floodParent = s.floodParent
        area = s.area; areaMFD = s.areaMFD
        isChannel = s.isChannel; streamMap = s.streamMap; streamRate = s.streamRate
        barAge = s.barAge
        disturb = s.disturb; regenPending = s.regenPending
        disturbActive = s.disturbActive
        // Frischer MeanderState: die Bin-Puffer des Cutoff-Index sind Arbeits-
        // speicher und werden je Aufruf neu aufgebaut.
        let m = MeanderState()
        m.channels = s.meanderChannels
        m.oxbows = s.oxbows
        m.oxbowAge = s.oxbowAge
        meander = m
        years = s.years
        seed = s.seed
        noise = SimplexNoise(seed: s.seed) // Permutationstabelle rein aus dem Seed
        dropsEmitted = s.dropsEmitted
        dropCarry = s.dropCarry
        beltCouplingCarry = s.beltCouplingCarry
        flowStepCount = s.flowStepCount
    }
}

extension Double {
    @inline(__always) func magnitudeHypot(_ y: Double) -> Double {
        (self * self + y * y).squareRoot()
    }
}

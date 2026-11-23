# relaxFraction ist die eine exponentielle Relaxation und bit-genau gepinnt

`Terrain.relaxFraction(dt:tau:)` ersetzt elf Fundstellen, die alle wörtlich `1 − e^(−dt/τ)` rechneten (Seespiegel, Salzkruste, Becken-Bilanz, Pfützen, Altarme, Vegetation, Stream-Map, Regeneration). Sie ist eine der drei Bauformen der Framerate-Unabhängigkeit und wird deshalb unabhängig gepinnt: das Ergebnis bit-genau gegen die geschlossene Form, das Verhalten über Teleskopierung, Monotonie und Ränder.

Bit-genau, weil der Sim-Kern bit-identisch reproduzierbar sein muss: jede mathematisch gleichwertige Umformung wäre eine Physik-Änderung. `DtInvariance.testRelaxationsTelescopeAcrossSubsteps` prüft die Teleskop-Eigenschaft bewusst mit ausgeschriebener Formel, damit dieser Wächter nicht am Helfer hängt, den er absichern soll.

Zugesicherte Eigenschaften:
- Der verbleibende Rest ist multiplikativ: N Teilschritte und ein Sprung derselben Gesamtdauer landen auf demselben Wert („Echtzeit-Zeitraffer == +10.000 Jahre").
- Der Wert liegt für dt > 0 in (0, 1], wächst in `dt`, fällt in `tau`; als Gewicht einer Mischung `x += (ziel − x)·f` schießt nichts über. Strikt monoton nur bis zur Sättigung: ab etwa 37 τ liegt `e^(−dt/τ)` unter der halben `Double`-Auflösung bei 1.0 und `1 − …` rundet auf exakt 1 (τ = 20 J. gegen einen 10.000-Jahr-Sprung sind 500 τ).
- Nach einer Zeitkonstante ist genau `1 − 1/e` zurückgelegt, bei dt = 0 exakt nichts. Das ist die Voraussetzung dafür, dass `dt = 0` bei Generierung und Spieler-Eingriff ein No-Op der Relaxationen ist.
- `tau = 0` heißt „sofort ganz" (1.0), nicht NaN. `floodplainAggradation` verlässt sich darauf; der Helfer prüft das bewusst nicht selbst.

Geprüft über die Produktions-Zeitkonstanten plus die fest verdrahtete der Seen-Verfüllung (3000 J.) und dt von 0,2 J. (Echtzeit-Frame) bis 10.000 J.

Betrifft: `Terrain.relaxFraction`, `Terrain.floodplainAggradation`, `RelaxationTests`, `DtInvariance.testRelaxationsTelescopeAcrossSubsteps`

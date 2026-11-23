# RenderState: ein Invalidierungs-Einstieg, Brücke nur über den Frame

Seit Issue #93 gehört der Render-Zustand nicht mehr der GDExtension, sondern `RenderState`. Der Umzug trägt zwei Zusicherungen, deshalb zwei Wächter-Ebenen: Verhalten (headless) und Quelltext der Brücke (sie darf den Zustand nicht wieder selbst halten). Dass keine Terrain-Änderung ohne Invalidierung bleibt, prüft `WorldSessionTests` an der Welt-Sitzung.

Seit #214 sind `frame` und `invalidate` das ganze öffentliche Interface. Die Wächter treiben ausschließlich darüber an; interne Zwischenergebnisse (Band-Mesh nach dem Frame) werden mit `@testable` nur beobachtet. Band-Mechanik (Delta, Snapshot, Rebuild-Sentinel) wird direkt am `RiverRibbonRenderer` geprüft. Die Brücke bedient den Render-Zustand nur über den Frame; kein Einzelschritt-Callable darf zurückkommen, sonst ließe sich die Reihenfolge Bänder → Wasser → Masken von außen umgehen.

Jeder mutierende Einstieg endet in `invalidate`, danach zeigt der nächste Frame den frischen Stand. Geprüft wird die Wirkung, nicht ein Flag: der Frame muss dieselben Farben liefern wie ein frischer Render-Zustand auf demselben Terrain, und der alte Puffer muss sich vorher unterscheiden, sonst bemerkte die Prüfung einen stehengebliebenen Cache nicht. Laden ist der sechste Einstieg und der, an dem die von #93 aufgelöste Asymmetrie lebte: die Sitzung ersetzt das Terrain-Objekt. Der erste Frame nach `.replaced` muss neu bauen (bis #93 ließ das Generieren den Band-Vergleichsstand stehen).

Der reine Cache-Vertrag („stehen bis `invalidate`") ist seit #214 nur am internen Schritt prüfbar: der Frame zieht das Wasserfeld bedingungslos neu, und ändert sich dessen nasse Wiese, fällt der Material-Cache bewusst (#174 C, `RenderState.waterFieldBytes`). Vom Brücken-Pfad ist „geändert, aber nicht invalidiert" ohnehin unerreichbar.

`.replaced` löst den Unterschied zwischen Neu-Generieren und Laden auf: dieselbe Welt behält ihre Vergleichsstände, eine andere Welt verwirft Dirty-Snapshots und den Diagnose-Vergleichspunkt. Der Band-Vergleichsstand muss auch fallen, wenn die neue Welt keine Zentrumslinien hat. Daran scheiterte der frühere Sentinel: `maxDelta` verglich Längen, und „kein Vergleichspunkt" war dasselbe leere Array wie „Welt ohne Kanäle"; zusammen ergab das „0 = unverändert", der Rebuild blieb aus, die Bänder der vorigen Welt blieben sichtbar und `bandCoverage` deckelte das Raster-Wasser weiter entlang ihrer Korridore.

Nicht-endliche Knoten (NaN, ±inf) erzwingen den Rebuild-Sentinel je Achse: `max(maxD, NaN)` liefert `maxD`, ohne Wächter meldete eine NaN-Koordinate „unverändert". Liegt der Wert schon im Snapshot, bleibt der Zustand dirty, bis wieder endliche Koordinaten gebaut sind.

Betrifft: `RenderState.frame`, `RenderState.invalidate`, `TerrainChange`, `RiverRibbonRenderer.maxDelta`, `RiverRibbonRenderer.rebuildSentinel`, `Extension/Sources/RiverSimGD/SimNode.swift`, `RenderStateTests`

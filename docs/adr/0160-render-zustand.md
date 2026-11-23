# Render-Zustand als eigener Typ mit einem Invalidierungs-Einstieg

`RenderState` besitzt den Render-Zustand EINER Welt: die drei zustandstragenden Renderer (EWMA-Felder, Arbeitspuffer, Dirty-Snapshots) und die Caches der zustandslosen Pässe `TerrainColorRenderer` (#93), `WaterProtectMask` (#154) und `ForestCanopyMask` (#152). Bis #93 gehörte dieser Zustand der GDExtension, obwohl die Brücke reines Marshalling sein soll. Die Cache-Invalidierung stand dort sechsmal von Hand, und Neu-Generieren und Laden fuhren zwei Politiken: das Laden verwarf die Dirty-Snapshots, das Generieren verließ sich auf die Delta-Heuristik. Jetzt gibt es genau einen Einstieg, `invalidate(terrain, change)`, und „dieselbe Welt hat sich geändert" gegen „eine ANDERE Welt" ist ein benannter Parameter (`TerrainChange`).

`RenderState` liest das Terrain und ändert es nie. Die Welt reist als Parameter durch jeden Einstieg; Besitzer des `Terrain` bleibt die Welt-Sitzung. #93 verschob den Render-ZUSTAND, nicht die Sim-Ownership.

Seit Issue #214 sind nur `frame` und `invalidate` plus die Werte, die das Spiel liest (Diagnose, `deferWaterTail`, `renderGrid`), öffentlich. Die reihenfolgeabhängigen Einzelschritte (Bänder bauen und markieren, Wasserfeld, Masken, Material, Fahnen) sind `internal` und laufen nur in der Reihenfolge des Frames. Ein direkter Aufruf von außen lieferte sonst Material vor dem Wasser des Frames (dessen nasse Wiese ins Material geht), ein Wasserfeld, das `visibleWater` setzt und die Masken verwirft, oder einen Bänderbau an Bänder → Wasser → Masken vorbei. Die headless Wächter beobachten Zwischenergebnisse über `@testable`, fahren aber denselben Frame. Auch die Welt-Sitzung reicht keine Einzelschritte mehr nach außen.

Invalidierungs-Politik:
- `.advanced` (Sim-Schritt): Render-Gedächtnisse laufen weiter, der Wald wächst nach.
- `.edited` (Pinsel, Nachzug): dieselbe Welt, aber kein Gedächtnis darf den alten Stand zeigen; das Waldgedächtnis wird zurückgesetzt (Issue #167).
- `.replaced` (Generieren, Laden): zusätzlich fällt alles, was gegen den VORHERIGEN Stand vergleicht: der Dirty-Snapshot der Bänder (ohne Vergleichsstand meldet er 1e9, weit über `ribbonRebuildDelta`, also baut der nächste Frame neu) und der Diagnose-Vergleichspunkt (die Δ-Karte zeigt, was die Sim AB JETZT tut). Bis #93 tat das nur das Laden; die Asymmetrie war Altbestand, keine Entscheidung.
- Pinsel, Laden und Neugenerieren beenden laufende Band-Übergänge sofort (keine versiegenden Arme); eine andere Welt verwirft auch die Deckung.
- Bewusst ausgenommen ist das EWMA-Gedächtnis des Wasserfelds. Es ist keine Aussage über die alte Welt, sondern eine zeitliche Glättung, und jeder Weltwechsel endet in `frame(.settled)` mit Blend 1.0, der es vollständig überschreibt. Ein Reset wäre wirkungslos (geprüft mit #94).

Cache-Abhängigkeiten:
- Die Schutzmaske folgt dem zuletzt an Godot ausgelieferten Wasserfeld (`visibleWater`), nicht dem Terrain: nach einem Pinselstrich zeigt Godot bis zum nächsten Wasser-Upload noch das alte Feld, und genau das muss geschützt bleiben. Eigenes Nachrechnen kostete außerdem einen zweiten Wasserfeld-Lauf (rund 13 ms). Sie fällt, wenn sich das Wasserfeld oder die Bandabdeckung ändert.
- Auch die Rohbytes des `deferTail`-Pfads (`RS_WATER_GPU`) zählen als ausgeliefert: sie sind ungeblurt um höchstens die zwei Blur-Pässe schmaler als das Sichtbare, und genau so weit reicht der Saum (`WaterRender.protectSeamCells`).
- Ändert sich die nasse Wiese des ausgelieferten Wasserfelds, fällt der Material-Cache.
- Farbe und Schutzmaske lesen DASSELBE Gürtel-Material (`BarMaterial`); es fällt mit dem Material-Cache.
- Schutz- und Waldmaske fallen immer gemeinsam: die Waldmaske endet an der Schutzmaske, ein veralteter Wald stünde sonst über neuem Wasser.
- Die Kopplung der beiden Wasserpfade liegt in `waterFieldBytes`, nicht beim Aufrufer: `bandChannelFlags`/`bandCoverage` sind das ECHTE Bauergebnis des letzten Ribbon-Builds, und nur Kanäle MIT Band werden im Feld zum Saum gedeckelt (Issue #34).

`geometryMode` (Band-Geometrie seit #34 Standard, sonst Raster-Stempel) löst den Legacy-A/B-Schalter `RS_WATER_STAMP` hier auf, wo das Wasserfeld ihn braucht, statt in der Brücke; `Main.gd` liest dieselbe Variable und baut dann kein Ribbon-Mesh. Die Umgebung wird einmal gelesen, weil der Schalter nicht mitten in einer Sitzung umspringen darf; injizierbar ist er, damit die Wächter beide Pfade fahren, ohne die Prozess-Umgebung zu verstellen.

Betrifft: `RenderState`, `RenderState.invalidate`, `RenderState.dropMasks`, `RenderState.waterFieldBytes`, `RenderState.geometryMode`, `TerrainChange`, `WorldSession` (Render-Zustand)

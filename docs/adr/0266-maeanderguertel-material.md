# Material des Mäandergürtels: Sand nur am Gerinne, Vorzeichen des Querprofils

Das Render des Mäandergürtels (#174, Paket C Teil 2) ist reine Render-Ableitung, das Terrain bleibt bit-gleich. `BarMaterial` legt Sand nur auf die junge Bank direkt am Gerinne (höchstens etwa eine Kanalbreite je Ufer); dahinter steht Pionier-Grün. Scroll-Rippen folgen den Isolinien des Bankalters und blenden aus, wo sie aliasen würden. Altarme verlanden über Ried zum Vegetationsbogen, auch trockene junge Altarme ohne Wasserband zeigen das Ried. Sand geht in die Materialgewichte (A-Kanal der Makrofarbe, weniger Vegetation) und in die Schutzmaske (kein Wald auf frischen Bänken).

Befunde, aus denen die Regeln stammen:
- „Sandwüste" (#174): Ist das ganze Innere einer Schlinge junge Bank, weil der Gürtel es eben überstrichen hat, liegt Sand trotzdem nur als Streifen am Gerinne. Seit Look-Iteration 12 liegt offener Sand nur noch innerhalb `barSandReachLo` Kanalbreiten.
- Scroll-Rippen sind leise Bewuchs-Bänder, nie helle Sandringe: weit vom Gerinne bleibt Sand 0 und die Bewuchs-Verschiebung klein.
- Review zu #174: Die Schwelle, ab der ein Nachbar im Sprenkel-Filter als Sand zählt, stand als Literal im Filter; sie gehört in den Vertrag neben das Fenster `barSandNeighboursLo/Hi` (`WaterRender.barSandNeighbourMin`, Wert 0,05 unverändert).
- Review zu #174 C: Das Pionier-Grün hing am rohen Sand vor dem Entsprenkeln. Eine einzelne Sandzelle verlor ihren Sand, behielt aber auch kein Grün (`1 − Sand_roh = 0`) und stand als kahler Punkt da. Das Grün richtet sich deshalb nach dem entsprenkelten Sand.
- Review zu #174 D („Talboden-Wiese hell-saftig in der Aue"): Bänke, deren Sand-Fenster vorbei ist, tragen Talboden-Wiese, auch wo Steigung und Höhenband sie verfehlen.

Querprofil im Band: UV2.y trägt die Bogenstärke der Sim, das Prallhang-Ufer ist das tiefe. Konvention: Ein Linksbogen (gegen den Uhrzeigersinn in x/z) hat positive Bogenstärke; sein Außenufer liegt rechts der Fließrichtung, also bei UV.x = 0. Sim und Render müssen diese Vorzeichen teilen.

Betrifft: `BarMaterial`, `WaterRender.barSandNeighbourMin`, `WaterRender.barSandReachLo`, `WaterRender.ribbonOutward`, `TerrainColorRenderer`, `WaterProtectMask`

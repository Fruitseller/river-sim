# Flussbänder steigen stromab nicht sichtbar an

Befund des Projekteigners im Zeitraffer um Jahr 230.000 (Issue #174): „Flüsse fließen bergauf". Eine abgekoppelte Gürtel-Linie lief eine Talwand hinauf, und das Band folgte ihr. `WaterRender.ribbonUphillFade` blendet das Band aus, wo das Gelände unter der Mitte über das laufende Minimum stromauf steigt.

Der Wächter läuft auf einer Kunstwelt: nach Osten fallende Ebene, Zentrumslinie über einen 72 m hohen Rücken, darunter ein Strahler-3-Baum im D8-Netz, damit das Band überhaupt emittiert wird. Hinter dem Rücken liegt das Gelände wieder unter dem Lauf davor; dort ist es wieder Wasser, und das Band darf nicht ganz verschwinden. Wo das Gelände stromab fällt, wirkt die Blende nicht: vor dem Rücken ist das Band bit-gleich zur Welt ohne Rücken.

Betrifft: `WaterRender.ribbonUphillFade`, `RiverRibbonRenderer.fadesUphill`, `RibbonUphillTests`

# Querprofil des Korridors: Form, Tiefe, Ufersuche

Die Geschmackswerte des Korridors stehen neben ihrem Code in `CorridorProfile`, nicht im Kalibrier-Register (Entscheidung des Eigners zu #235–#239). Ausnahme sind die zwei Werte, die auch Shader lesen: Uferlinie als Anteil der sichtbaren Wasser-Halbbreite (`shoreFraction` = `WaterRender.corridorShoreFraction`) und ihr Wandern im Bogen (`shoreBendShift` = `WaterRender.corridorShoreBendShift`, am Prallhang nach außen, am Gleithang nach innen, dort liegt die Kiesbank). Das Band (`water.gdshader`) endet genau an dieser Uferlinie, der nasse Saum (`corridor.gdshaderinc`) ebenso; deshalb reisen sie über das Register.

Form: Der Fuß jenseits der Uferkante (`footCells` 0,45, als Uferwall `leveeFootCells` 0,9) liegt immer auf dem Gelände. Steht die Kante als Uferwall darüber, fällt sie bis zum Fuß ab; sonst ist der Fuß nur der Saum, über den der Shader ins Gelände blendet. Die Böschung ist am Prallhang steil (der Abfall liegt nah am Wasser, oben eine Schulter) und am Gleithang flach (Kiesbank).

Tiefe: Bett-Tiefe unter dem Wasserspiegel aus der Wasserbreite, Breite/Tiefe ~ 4 statt der natürlichen 10–20, weil das Gelände selbst ~ 6-fach überhöht ist. Gedeckelt (`depthMax`), Furten (Riffel) flacher (`riffleShallowing`).

Ufersuche: Liegt das Gelände an der Uferkante unter dem Wasser (die Lagrange-Zentrumslinie liegt oft eine Zelle neben der D8-Rinne), sucht die Kante bis `edgeSearchCells` (2,5 Zellen) nach außen nach Gelände über dem Wasser, in `edgeSearchStep`-Schritten. Erst danach hebt sie sich über das Gelände. Gemessen bei n = 384: ohne Suche 45 % gehobene Kanten.

Jenseits der Uferlinien ist es trocken: die Wasser-Ebene läuft quer weiter, aber ein Fuß auf tieferer Aue liegt nicht unter Wasser (Review Neon Nr. 6); die Tiefe dort ist ≤ 0.

Betrifft: `CorridorProfile` (`footCells`, `leveeFootCells`, `shoreFraction`, `shoreBendShift`, `depthBase`, `depthPerWidth`, `depthMax`, `riffleShallowing`, `edgeSearchCells`, `edgeSearchStep`, `section`), `WaterRender.corridorShoreFraction`, `WaterRender.corridorShoreBendShift`, `game/shaders/water.gdshader`, `game/shaders/corridor.gdshaderinc`

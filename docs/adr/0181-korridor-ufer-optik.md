# Korridor-Ufer: Gelände scheint durch, Erde nur am Prallhang, ein gemeinsames Bett

Über Wasser deckt der Korridor nur, wo er etwas zeigt: Erde an der steilen, flusszugewandten Böschung (Prallhang) und ein schmaler nasser, dunkler Saum an der Uferlinie. Sonst scheint das Gelände durch (es liegt dort fast auf der Böschung, samt Sand der Bank); die Makrofarbe allein ist nicht das fertig schattierte Gelände und las sich grau.

- Die trockene Bank am Gleithang malt der Korridor nicht mehr selbst, dort zeigt das Gelände seinen Sand (SimRender.BarMaterial); beide zusammen lagen als zwei helle Bänder nebeneinander (Gremium, Befund 1).
- Erde nur auf Flächen, die zum Fluss schauen: die Außenflanke eines Uferwalls (Kante über flacher Aue) ist keine Prallhang-Wand.
- Der nasse Saum folgt dem Querversatz zur Uferlinie (derselben wie im Band), nicht einem Höhenfenster: auf flacher Aue steigt das Ufer kaum, ein Höhenfenster deckte dort die ganze Böschung (README Look E, verworfen).
- Bett unter Wasser: das gemeinsame Bett `water_bed_color` (dasselbe wie unter Raster-Wasser und Seen), im Flachwasser am Gleithang Kies. Den Wasserkörper malt das Band darüber mit der gemeinsamen Deckkraft-Rampe; der frühere eigene Beer-Lambert hier färbte den Thalweg fast schwarz und den Rand hell. Die Uferlinie ist dieselbe, an der das Band endet (`water_corridor_shore`, CorridorProfile).

Betrifft: `game/shaders/corridor.gdshaderinc` (fragment), `SimRender.BarMaterial`, `CorridorProfile`

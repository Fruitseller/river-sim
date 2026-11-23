# Gletscher: Eis als eigene Auflage, Vergletscherungsmaske als einziges Gate

`Terrain.ice` ist Eisdicke in Höheneinheiten und der einzige zusätzliche Zustand des Gletscher-Passes; Eisfluss, Gleitrate und Maske sind Ableitungen je Schritt (`docs/research-climate-cryosphere.md` §4/§6). Das Feld wurde mit #33 angelegt und erst mit #35 beschrieben, weil das Speicherformat keine Migration kennt: alle Kryo-Felder mussten in einen Versionssprung (`WorldSnapshot.version` 2 → 3), sonst hätte der Eisfluss eine zweite Ungültigkeitsrunde für alle Spielstände gekostet.

`h` enthält das Eis nicht, es liegt als Auflage über dem Bett. Die Entwässerung (`computeFlow`) läuft deshalb unverändert auf dem Bett; subglaziales Wasser folgt real ebenfalls dem Bettgefälle.

`underIce` (`ice > cfg.iceMinThickness`) gatet den fluvialen Abtrag: unter einem Gletscher trägt kein Oberflächenwasser ab, sonst carvt dasselbe Tal ein zweites Mal mit fluvialem statt glazialem Querschnitt. Seit #96 gibt es eine Prüfstelle, `Terrain.Bed.erode` im Funnel `erodeCell`/`depositCell`, über den jede fluviale Bettbewegung schreibt, auch Auslass-Inzision, Tropfen (mit der strengeren Maske Eis ∪ Gürtelbett, `beltDropletGate`) und Pinsel. Hangdiffusion und Brandung sind nicht gegatet (kein fluvialer Pass, tragen aber Nachbaränderungen auf die Eiszelle; `docs/glacier-measurements.md` §I.1).

Fließen und Abrasion setzen an derselben Schwelle ein wie die Maske. Vorher hingen sie an „irgendeiner positiven Restdicke", und am dünnen Saum liefen fluviale und glaziale Erosion gleichzeitig. Die Bilanz (Zufuhr, Schmelze, Moräne) läuft für dünnes Eis weiter, sonst könnte ein Schneefeld nie über die Schwelle wachsen.

Leer heißt aus: trägt keine Zelle Eis über der Schwelle, bleibt `underIce` leer und die Arithmetik ist bit-identisch zum Stand ohne Gletscher. `underIce` ist reine Ableitung und nicht im Inventar (`StateInventoryTests.classification`, #98).

Betrifft: `Terrain.ice`, `Terrain.underIce`, `Terrain.rebuildIceMask`, `Terrain.iceFlowSubStep`, `Terrain.Bed.erode`, `WorldSnapshot.version`

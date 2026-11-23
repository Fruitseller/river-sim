# Orographischer Regen auf geglätteter Höhe mit Feuchte-Untergrenze

`computeRain` fegt je Zeile von West nach Ost (zeilenparallel). Der Anstieg wird auf einer geglätteten Höhe gezählt (EWMA mit Faktor 0,25, ~4 Zellen): seit der Pre-Erosion trägt jeder Hang feine Rinnen, als Roh-Anstiege gezählt trockneten sie die ganze Insel aus (Regen ≈ 0, kein Grün). Orographie ist Makrorelief, nicht Rinnentextur.

Die Feuchte fällt nie unter 0,18 (vorher 0,05): auch der Regenschatten-Osten bekommt Grundfeuchte, also moosige Tieflandebenen statt kahler Blässe.

Betrifft: `Terrain.computeRain`

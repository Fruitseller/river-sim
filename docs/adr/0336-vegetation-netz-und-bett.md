# Vegetation: D8-Quellmaske, kein Gehölz auf dem Bett, Alt-Dämpfung für Gras

Die Quellmaske in `updateVegClass` (Wasser-Quelle für Auwald: substanzieller Lauf oder stehendes Wasser im Dilatations-Umkreis) liest `area` (D8). Früher las sie `areaMFD`, womit das MFD-Netz über `vegClass` → `vegDamp` in die Erosion floss; das verletzt die Netz-Trennung (MFD nur Render und Braiding). Der Test spiegelt dieselbe D8-Quelle.

Auf dem Wasserlauf selbst wächst kein Gehölz, weder Auwald (3) noch Wald (2). Sonst liegt eine Wurzel-Kohäsion (1,3 bzw. 1,1) auf dem Gerinne und panzert den Talboden; die stehen gebliebenen Knubbel im breiten MFD-Lauf zählte `testBraidingBuildsBars` als Inseln (Braiding-Regression Aug 2026). Bett = Gras heißt zugleich, dort gilt exakt die Vor-Merge-Dämpfung `1 − 0,6·veg`; allgemein bleiben alle veg-Konsumenten mit Klassen {0, 1} unverändert (`typFactor(Gras) = 1,0`).

Der Regrowth-Test schaltet den Störungspfad (#26) ab: der hält frisch umgegrabenen Boden bewusst über sein Abklingfenster kahl und wird über `step()` abgebaut; ein Test, der nur `updateVegetation` ruft, mäße sonst eine Störung, die er nie beenden kann (eigene Wächter: `FlattenRegeneration`).

Betrifft: `Terrain.updateVegClass`, `Terrain.vegDamp`, `VegetationTests`

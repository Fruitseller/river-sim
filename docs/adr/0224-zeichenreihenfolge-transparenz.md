# Feste Zeichenreihenfolge der transparenten Flächen

Die transparenten Flächen werden über `render_priority` in einer festen Reihenfolge gezeichnet, weil Godot sie sonst nach Abstand sortiert und sich Schichten falsch überdecken.

- Korridor (Ufer und Bett, #239): Priorität −1, vor allen übrigen transparenten Flächen, damit das Band danach gegen Ufer und Bett tiefengetestet wird.
- Flussbänder, Wasser, Meer: Priorität 0.
- Talnebel: `FOG_PRIORITY` 1, nach den Bändern. Sonst lägen die Bänder auf dem Nebel statt darunter.
- Wolkenkörper über den Kämmen: `CLOUD_PRIORITY` 2 (Main hebt sie darauf).
- Pinselkuppel: zuletzt (`RENDER_PRIORITY_MAX`). Sie zeichnet zweistufig, erst den verdeckten Teil gedämpft ohne Tiefentest, darüber den sichtbaren. Läge sie nicht hinter allen übrigen transparenten Flächen (Wasser, Meer, Wolken), überdeckten diese den gedämpften Teil.

Betrifft: `Atmosphere.FOG_PRIORITY`, `Atmosphere.CLOUD_PRIORITY`, `Atmosphere.make_valley_fog`, `RiverCorridor._make`, `Main._setup_scene` (Pinselkuppel)

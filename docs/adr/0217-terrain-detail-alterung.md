# Kosmetische Shader-Rinnen gegenläufig zum Geländealter

Die Physik altert von einer scharfen zu einer runden Landschaft. Eine konstante Stärke der kosmetischen Sub-Grid-Rinnen überzeichnete Jahr 0 und ließ 100k im Vergleich leer aussehen. Der Renderkontrast läuft deshalb gegenläufig (jung 0,16, alt 0,42) und hält beide Zustände als dieselbe Welt lesbar, ohne Sim-Höhen, Wasser oder Spielstände zu ändern. Der Übergang folgt einem Smoothstep über das Alter, damit es am Anfang und bei 100k keinen sichtbaren Knick gibt; danach bleibt der alte Zustand stabil, statt immer kontrastreicher zu werden.

Kalibrierung per A/B-Screenshot (maximiert, `RS_STEP=100000`, Seed 1337): Die Stärke ist nicht der Hebel für „alt wirkt leer“. Bei 0,70 wurde aus dem Detail-Layer ein sichtbar repetitives Tapeten-Muster (Nutzer-Abnahme 2026-09-02), weil die gealterte Welt gleichförmig flache Hänge hat und `erosion_detail` die Wellen-Richtung auf die lokale Steigung normiert, also überall gleiche Frequenz und Amplitude. Am jungen Ende ist der Layer ohnehin fast unsichtbar: die echten Pre-Erosions-Rinnen der Generierung dominieren, A/B mit `detail_enabled = false` war ununterscheidbar.

Betrifft: `Main.TERRAIN_DETAIL_YOUNG`, `Main.TERRAIN_DETAIL_OLD`, `Main.terrain_detail_strength`

# Vertragstest von Licht, Atmosphäre und Wolken

`game/tests/lighting.gd` (#151) prüft das äußere Verhalten von `scripts/Lighting.gd`, der einen Quelle für Sonne, Atmosphäre und Wolken; braucht die GDExtension nicht:
- feste Welt-Sonne: das Licht fällt von oben aus der vereinbarten Richtung, unabhängig von der Kamera (Main ruft `configure_sun` nur beim Aufbau);
- Atmosphäre: AgX, Luftperspektive, Talnebel knapp über dem Meer, Anteil neutral-warmes Umgebungslicht;
- `performance` ist billiger als `balanced`;
- Wolkenschatten: jede `cloud*`-Uniform ist in allen drei Shadern und im Wolkenkörper default-frei deklariert (die Werte reisen nur über `Lighting.gd`) und wird gesetzt; die Shader kompilieren mit dem gemeinsamen Include;
- Wolkenkörper (#174 D): drei Ebenen über dem Kamm, Basis = Schattenbasis, in `performance` unsichtbar, Schatten fallen entlang der Sonne. Das Körper-Tuning (`cloud_body_lift`, `cloud_body_self_shadow_*`, Review zu #174 D) reist nur über `Lighting.gd`; die Deckungs-Schwelle teilt der Körper mit dem Schatten über `cloud_cover_at`, ohne Kopie im Körper-Shader.

Betrifft: `game/tests/lighting.gd`, `game/scripts/Lighting.gd`, `game/shaders/clouds.gdshaderinc`, `game/shaders/cloud_body.gdshader`

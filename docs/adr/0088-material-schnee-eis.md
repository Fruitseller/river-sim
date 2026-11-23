# Schnee und Gletschereis im Material-Render

Gletscher sollen im Bild vom Schneefeld unterscheidbar sein, und steile Wände sollen weder Schnee noch Eis tragen. Die Sim behält ihr Eis unverändert; nur die Kältedeckung im Render wird umverteilt.

## Blankes Eis nur im Zehrgebiet (`firnTempLo/Hi` = −1/+1)

Temperatur (`Terrain.temperature`, °C) relativ zur Eis-Firn-Grenze, ab der das Eis aus dem Firn tritt und ab der es voll blank ist. Oberhalb der Gleichgewichtslinie ist der Gletscher Firn und liest sich als Schnee, darunter als bläuliche Zunge (Vorlage B/C). Ohne diese Trennung war jede kalte Zelle „blankes Eis", weil der Schnee im Nährgebiet zu Eis wird und die Schneedeckung dort klein bleibt (Seed 1337, Jahr 2000). Seit der Entkopplung der Eis-Firn-Grenze (`SimConfig.iceFirnTemp`, −2 °C, #174) gelten die Werte relativ zu ihr, nicht zur 0-°C-Isotherme: mit festen 0 °C lag die Zunge zwischen −2 und 0 °C als Firn unter dem Schnee, und im Bild war kein Gletscher vom Schneefeld zu unterscheiden (Abnahmepunkt 36).

## Schnee auf der Zunge (`iceSnowHide` = 0,85)

Blankes Eis × (1 − `iceSnowHide` × Schneedeckung × (1 − Zehranteil)). Im Zehrgebiet schmilzt der Winterschnee jeden Sommer ab; die Schneedecke der Sim ist ein Jahresmittel und deckte dort sonst die Zunge zu. Im Nährgebiet bleibt der Gletscher Firn.

## Schnee gleitet von Steilflanken (`snowShedSlopeLo/Hi` = 1,4/2,2 ≈ 55°/66°)

Weltsteigung samt Höhenskala. Steile Wände halten keinen Schnee, er geht als Lawine ab (dieselbe Physik wie der Firn-Abgang des Eises, `SimConfig.iceAvalancheSlopeLo/Hi`, dort in Sim-Steigung). Ohne das deckte die Kälte jede Wand über der Schneegrenze weiß zu, und Hörner, Grate und Karwände lasen sich als weiße Tafeln (Befund #174, Seeds 1337/20). Gemessen (Seed 1337, Jahr 20.000, Zellen über 0,5): Schnee liegt mit mittlerer Weltsteigung 1,36, 44 % über 1,5. Verworfen: 0,8/1,5 (Diorama fast nur graue Gipfel) und 1,2/2,0 (Grate grauer als die Vorlagen; mit 1,4/2,2 hält der Kamm sichtbar mehr Schnee, die Wände bleiben Fels).

## Eis steiler (`iceShedSlopeLo/Hi` = 1,6/2,6 ≈ 58°/69°)

Hängegletscher halten sich steiler als Schnee, darüber bricht Eis in Séracs ab. Die Sim behält ihr Eis (`underIce` und der Abtrag bleiben unberührt), nur die Kältedeckung im Render weicht dem Fels. Gemessen (Seed 1337, Jahr 20.000): Eis liegt mit mittlerer Weltsteigung 1,31, 42 % über 1,5; ohne diese Abstufung blieben die Wände weiß, auch wenn der Schnee abglitt.

## Umverteilung nach der Form (Look-Iteration 7)

Je Pixel halten Rinnen (`cavity` < 0) Schnee, Rippen geben ihn ab (`snowCavity`, `snowSlopeLo/Hi` mit Render-Verschiebung), freigegebener Schnee wird Fels; `rockFray` franst die Grenze Fels ↔ Bewuchs aus. Beides setzt erst ab einem kleinen Kälte- bzw. Felsgewicht ein (sonst lägen Schnee und Fels in jeder Rinne bzw. auf jeder Rippe) und blendet bis `redistributeFade` stetig ein. Bis Review Neon Nr. 4 schaltete es an der Schwelle hart: ein Pixel mit Kälte 0,0021 in einer Rinne lag voll im Schnee, sein Nachbar mit 0,0019 ganz frei.

Betrifft: `MaterialRender.firnTempLo`, `MaterialRender.iceSnowHide`, `MaterialRender.snowShedSlopeLo`, `MaterialRender.iceShedSlopeLo`, `MaterialRender.snowCavity`, `MaterialRender.rockFray`, `MaterialRender.redistributeFade`, `SimConfig.iceFirnTemp`, `SimConfig.iceAvalancheSlopeLo`, `game/shaders/terrain.gdshader`

# Korridor weicht dem Wasser anderer Bänder

Jedes Band baut seinen Korridor allein. Am Zusammenfluss schrieb deshalb die Böschung des Zubringers mit Deckel-Tiefe über das Wasser des Hauptlaufs, die des Hauptlaufs quer über die Mündung des Zubringers (Dämme, Querwände), und ein versiegender Arm, der im heutigen Lauf liegt, legte seine Böschungen als Querbalken über dessen Wasser (Gremium, Befund 2). Deshalb blenden Ufer und Bett aus, wo sie im Wasser eines ANDEREN Bands liegen, nach zwei Regeln:

- Wasser eines FRÜHER gebauten Bands (Hauptläufe vor Zubringern, versiegende Arme zuletzt) hat Vorrang: dort weicht jeder Teil.
- Wasser eines später gebauten Bands öffnet nur das trockene Ufer und nur außerhalb des eigenen Wassers: die Mündung des Zubringers.

Gelesen wird das Wasser jedes Bands VOR der Verdeckung durch frühere Bänder (`emitRibbon`), sonst bliebe das Ufer des Hauptlaufs vor jeder Mündung stehen. Je Zelle werden bis zu zwei Eigentümer gehalten (Slot A = zuerst gebautes Band, B = erstes andere).

Ein Dreieck mit einem ausgeblendeten Vertex fällt ganz weg: über die Fläche interpoliert bliebe die Deckkraft sonst über null, und der Korridor schriebe dort weiter Deckel-Tiefe vor das fremde Wasser.

Betrifft: `RiverRibbonRenderer.fadeCorridorsInForeignWater`, `RiverRibbonRenderer.CorridorWater`, `RiverRibbonRenderer.CorridorBand`, `RiverRibbonRenderer.emitRibbon`

# SimConfig reist per Codable-Synthese vollständig im Spielstand

Die Config wird im Weltformat (Issue #8, `WorldSnapshot.swift`) komplett mitgespeichert, und zwar automatisch: eine neue Stellschraube braucht keinen Eintrag im Serialisierer. Deshalb stehen `Codable`/`Equatable` direkt an der Deklaration von `SimConfig` und nicht als Extension in `WorldSnapshot.swift`, denn Swift synthetisiert die Konformität nur in der Ursprungsdatei.

Höhen sind normiert (etwa −0,3 … 1,4), Weltkoordinaten sind abstrakte Einheiten.

Betrifft: `SimConfig`, `WorldSnapshot.swift`

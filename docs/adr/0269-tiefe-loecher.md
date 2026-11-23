# Keine ewigen Tiefen-Löcher („dunkle Stellen")

Regression: Zellen, die anfangs Land oder Flachwasser waren, gerieten tief unter den Meeresspiegel und blieben dort für immer, weil alle Prozesse (Erosion, Verfüllung, Deposition) `h <= sea` überspringen; die Unterwasser-Farbrampe malte sie als dunkle Flecken. Der Wächter verlangt, dass die reine Simulation keine solchen Löcher gräbt (Seeds der „Neues Terrain"-Kette des Spiels, LCG ab 1337, getaktet wie der 60-J/s-Zeitraffer).

Spieler-Absenken darf keine ewige Absenkungszone hinterlassen: Früher koppelte `sculpt(dir < 0)` die Tektonik bis −2, und die Kraterränder sanken über Jahrtausende unter den Meeresspiegel. Diese Kopplung ist entfernt; gemessen wird nur das simulationsgetriebene Absacken nach dem Graben.

Betrifft: `Terrain.sculpt`, `DeepPitDiag`

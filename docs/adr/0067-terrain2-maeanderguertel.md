# Mäandergürtel: Sub-Takt je Lauf und Querprofil-Stempel (Issue #174, Paket B)

## Abfluss je Knoten

`refreshBeltDischarge` nimmt das größte Einzugsgebiet im 3×3 um den Knoten und macht es entlang des Laufs monoton (laufendes Maximum stromab). Bilinear auf der einzelligen D8-Rinne fiel der Abfluss eines Knotens, der eine Zelle neben der Rinne lag, auf ~1 Zelle; gemessen endete der Hauptlauf in Jahr 100.000 auf 1–50 Zellen Einzugsgebiet. Mit Kopplung (#187) setzt stattdessen `coupleBeltToDrainage` Läufe und Abfluss (s. dort).

## Sub-Takt je Lauf

Migration und Gürtel-Stempel sind gemeinsam sub-getaktet, und zwar JE LAUF: jeder wandernde Lauf springt je Teilschritt höchstens einen halben Knotenabstand (eigene CFL-Zahl), und hinter ihm bleibt in jedem Teilschritt die Bank liegen, sonst hinge die Spur der Scroll-Bars an der Schrittweite. Mit einer Teilschrittzahl für alle setzte der schnellste Knoten der Welt den Takt (gemessen 13 Teilschritte je 100 Jahre, Gürtel 36 ms je Schritt). Feste Läufe (unter `meanderBeltMinCells`) bekommen einen Stempel über den ganzen Schritt. `beltSubsteps` meldet die größte Teilschrittzahl.

Der Teilschritt-Deckel `maxSub = 4096` ist nur Sicherheitsnetz. Mit 256 riss er bei Einlauf und Sprüngen: gemessen max. Rate 0,21–0,31 Zellen/Jahr, nötig 276–419 Teilschritte bei dt 1000, 551–837 bei dt 2000; schnelle Bögen wuchsen dann nur mit 31–93 % ihrer Rate (Review #187).

Alter je Teilschritt (Review #187): eine Bank oder ein Altarm aus Teilschritt `si` ist am Schrittende `dt − (si+1)·sub` Jahre alt, nicht 0. Vorher alterten Bank- und Altarm-Alter einmal je Schritt; nach einem 1000-Jahr-Schritt trugen gemessen alle 9971 neuen Bankzellen das Alter 0 (in 100 × 10 Jahren: 269, der Rest über 0–1000 Jahre verteilt), die Scroll-Rippen (Isolinien des Alters) fehlten nach Einlauf und jedem Sprung. Neue Altarme erkennt der Gürtel deshalb am Index (`plugOxbows(from:)`), nicht am Alter 0.

Mit Kopplung stempelt der Teilschritt eines wandernden Laufs nur dessen FLACHE Knoten (Mobilität > 0); seine steilen Strecken bekommen wie die festen Läufe einen Linien-Carve über den ganzen Schritt. Seit die wandernden Läufe die ganzen Flüsse von der Quelle bis zur Mündung sind, stempelte jeder Teilschritt sonst den Gebirgsabschnitt mit (gemessen `belt.stamp` 3,8 → 8,0 ms je Schritt). Der Parameter `part` von `beltStampChannel`: 0 alle Knoten, 1 nur flache (Teilschritt eines wandernden Laufs), 2 nur steile (wandernder Lauf am Schrittende).

Die Profil-Relaxation ist auf zwei Hälften verteilt: die erste steckt in den Migrations-Teilschritten, die zweite (`belt.finishProfile`) läuft am Schrittende nach Inzision und Diffusion. Eine vollständige Formung nur vor Inzision/Diffusion ließ im großen Schritt viel mehr Profil verschwinden als im Zeitraffer.

## Querprofil (`beltStamp`)

- Sohle: Ziel `z_bf − D·(1 − η²)(1 + skew·a·η)`, η = Abstand zur Mitte in Halbbreiten (positiv = außen), `a` aus |Krümmung|·Breite: im Bogen liegt der Kolk außen, im Wendepunkt (a = 0) ist das Profil symmetrisch. Was über dem Ziel liegt, wird abgetragen (Relaxation über `meanderBeltRelaxYears`) und geht ins Bank-Budget.
- Im Kanal füllt das Budget jede Zelle unter dem Ziel auf, außen wie innen. Bis zur Kalibrierung (#174) nur innen: Kolke außen blieben tiefer als das über ±2 Knoten gemittelte Ziel, Übergänge wurden darauf abgetragen, der Bezug sank je Teilschritt (Sohlen-Ratsche, gemessen ~2 Tiefen Eintiefung unter die eigene Aue, Rest-Budget 29 Tiefen·Zellen je Knoten; danach 13).
- Bank: innen neben dem Kanal füllt das Budget bis `z_bf − barTop·D`, nie darüber. Die Bank ist eben (bankfull), wandernde Läufe hinterlassen eine flache Aue: laterale Planation. Was ein Knoten nicht unterbringt, wandert zum nächsten stromab. Der Deckel gilt auch im Profil: ab κ·η < −1 kippt der Faktor (1 + κη) ins Negative, das Ziel läge über bankfull.
- `z_bf` (bankfull) = tiefste Sohle des Querschnitts plus Kanaltiefe, über ±2 Knoten gemittelt; aus der Sohle, nicht aus den Ufern, sonst senkt die eigene Bank den Bezug Schritt für Schritt. Genau: `z_bf` steht so hoch, dass der tiefste Punkt des Zielprofils auf der heutigen Sohle liegt (Profil-Maximum von (1 − e²)(1 + κe) als Nullstelle von −3κe² − 2e + κ), ein Fixpunkt. Mit pauschalem Aufschlag wanderte der Bezug je Teilschritt nach oben.
- Steile Strecken (Mobilität 0) bekommen den alten Linien-Carve; ihr Bett formen `channelCarve` und die Tropfen.
- Schwellen schneiden (`meanderBeltSillCutDepths`): die Sohle liegt nie über dem Wasserspiegel stromauf (`hf`). Eine Schwelle bis zu so vielen Bankfull-Tiefen bekommt ein Ziel eine Viertel-Tiefe unter diesem Spiegel, damit D8 ihr folgt; ein flacher Lauf ohne Schwelle bleibt unberührt. Das Ziel hängt nur vom Zustand ab, nicht von der Zahl der Stempel (dt-Invarianz über `rel`).
- Frische Bank nur, wo die Ablage die Zelle bis auf eine Viertel Kanaltiefe an die Bank-Oberkante hebt, ein Zustand, keine Menge. Bis #187 machte jede Mini-Ablagerung eine frische Bank (Alter 0, Bewuchs weg, Tropfen gesperrt), und ihre Menge hing über `rel` an der Schrittweite. Eine bestehende Bank verjüngt sich, wenn die Ablage mehr als 0,2 Tiefen Lücke bis zur Oberkante schließt.

## Tropfen-Sperre im Gürtelbett

`beltDropletGate` sperrt für die Tropfen neben dem Eis (#35) das Bett der Mäanderläufe (`inBelt`): dort tragen sie weder ab noch lagern sie ab, ihre Fracht geht hindurch. Der Gürtel löst das Bett auf Bankfull-Skala auf (Kolk, Gleithang, Bank); der radiale Erosions-Pinsel der Tropfen grub jeden Schritt ein symmetrisches V hinein (gemessen: mittleres Querprofil außen/innen 0,9 / 0,9 Tiefen statt des Kolks außen), und der Bezug des Stempels sank mit der Sohle. Dieselbe Doktrin wie bei `channelCarve` auf Gürtelzellen.

Mit Kopplung (#187) nur das Bett WANDERNDER Läufe. Seit jeder D8-Abschnitt seine Linie hat, liegen Profil-Stempel fester Läufe auf viel mehr Wegen; die Tropfen tragen über gesperrte Zellen ihre volle Fracht und laden sie an der ersten freien Zelle ab. Am Ende eines solchen Stücks wuchs gemessen ein Schutthügel von 0,40 Höhe in einem 500-Jahr-Schritt (n = 160, Seed 1337, Zelle (5, 101): 0,318 → 0,722, über dem höchsten Gipfel; ohne Tropfen keiner). Das Profil, das die Sperre schützt, baut nur der wandernde Gürtel.

Betrifft: `Terrain.meanderBeltStep`, `Terrain.refreshBeltDischarge`, `Terrain.beltStamp`, `Terrain.beltStampChannel`, `Terrain.beltDropletGate`, `Terrain.plugOxbows`, `Terrain.barAge`, `SimConfig.meanderBelt*`

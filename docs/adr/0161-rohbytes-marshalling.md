# Felder als rohe float32-Bytes über die Brücke

Höhen und andere Float-Felder reisen als rohe float32-Bytes (`PackedByteArray`), die Godot direkt als R32F-Bilddaten übernimmt (`Image.set_data`). GDScript rechnete vorher `heights().to_byte_array()`: dieselben Bytes, aber eine zusätzliche Kopie von rund 2,7 MB je Textur-Update (Issue #53). `[Float]`-Felder (etwa die Sedimentfahne) gehen ohne Umweg über Double.

`packBytes` schreibt mit `storeBytes`, das ausrichtungsfrei arbeitet; der Byte-Puffer muss deshalb nicht 4-Byte-ausgerichtet sein.

Betrifft: `SimNode.heightsBytes`, `SimNode.packBytes`, `SimNode.packFloatBytes`

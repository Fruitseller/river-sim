# Swift-Toolchain in CI: eigene Composite-Action, Direktdownload mit gepinnter Prüfsumme

Die Toolchain-Einrichtung ist in diesem Repo nicht generisch (feste Version, swift.org-Direktdownload statt setup-swift, ncurses-Shim). Sie steht deshalb einmal in der lokalen Composite-Action `.github/actions/swift-toolchain` und wird von beiden CI-Jobs benutzt. Mit dem Godot-Vertrags-Job aus #52 hätte sie sonst zweimal dagestanden, und ein Toolchain-Wechsel, der nur einen Job erwischt, fällt erst nach 20 Minuten Build auf.

Download: direkt von swift.org (`https://download.swift.org/swift-<VERSION>-release/ubuntu2204/`). Verworfen, gemessen in den ersten CI-Läufen (Aug 2026): swiftly 0.3.0 scheiterte an Ubuntu 24.04 („Unsupported platform"), setup-swift v2.4.0 kennt Swift 6.3.3 nicht („Version 6.3.3 is not available"). Bei Cache-Hit ist `/opt/swift` schon gefüllt und der Download entfällt. Die Toolchain ist mehrere GB groß; ohne Cache hinge jeder Lauf am Download. `actions/cache` stellt mit absoluten Pfaden (`-P`) direkt nach `/opt/swift` wieder her, deshalb muss das Verzeichnis dem Runner-User gehören, sonst bricht der Restore mit EACCES ab.

Prüfsumme: HTTPS sichert nur den Transport. Ohne sha256 wäre das ein ungeprüftes ~1-GB-Fremdarchiv, aus dem jeder Compiler-Aufruf stammt. Der gepinnte Wert stammt aus dem Archiv, dessen Signatur gegen den „Swift 6.x Release Signing Key" (52BB 7E3D E28A 71BE 22EC 05FF EF80 A866 B47A 981F) verifiziert wurde. Hash statt `gpg --verify` im Job: kein zweiter Fremd-Download (Schlüsselbund) im Lauf, im Diff sichtbar gepinnt, und dasselbe Verfahren wie für die Godot-Binärdatei in `scripts/fetch-godot.sh`. `SWIFT_VERSION` und `SWIFT_SHA256` werden nur zusammen ausgetauscht. Neu ableiten beim Anheben:

    B=https://download.swift.org/swift-<VER>-release/ubuntu2204/swift-<VER>-RELEASE/swift-<VER>-RELEASE-ubuntu22.04.tar.gz
    curl -fsSLO "$B" -O "$B.sig"
    curl -fsSL --compressed https://www.swift.org/keys/all-keys.asc | gpg --import -
    gpg --verify swift-<VER>-RELEASE-ubuntu22.04.tar.gz{.sig,}
    sha256sum swift-<VER>-RELEASE-ubuntu22.04.tar.gz

Die Version muss zur lokal über Swiftly genutzten passen (`SimCore/` und `Extension/Package.swift` verlangen tools-version 6.0).

Runner: `ubuntu-22.04` statt `latest`. Die swift.org-22.04-Toolchain unterstützt 24.04 nicht (glibc/System-Libs), swiftly 0.3.0 scheiterte dort (erster CI-Lauf, Aug 2026). 22.04 hat außerdem `libncursesw.so.6` für den Shim.

System-Pakete laut swift.org-Installationsanleitung für Ubuntu 22.04 (https://www.swift.org/install/linux/): die Binaries verlinken u. a. gegen libz3 und libcurl, die auf dem Runner-Image teils fehlen. `libpython3` ist bewusst weggelassen: das Metapackage ist im Runner-Image-Index nicht auffindbar, die Laufzeitlib kommt über python3.10.

ncurses-Shim: die swift.org-Toolchain (und Swiftlys Ubuntu-Toolchain lokal auf Debian) erwartet `libncurses.so.6`, manche Systeme haben nur die binärkompatible Wide-Char-Variante. `scripts/build.sh` und die Action legen dieselbe Verknüpfung unter `.tools/swift-libs` an, nur lokal im Repo. In CI wird laut geloggt bzw. hart abgebrochen, wenn keine passende Lib da ist; ein still gescheiterter Shim zeigte sich sonst erst als kryptisches „cannot open shared object file" beim `swift`-Aufruf.

Ebenso ergänzt `scripts/start.sh` auf schlanken Debian-Systemen fehlende X11-/Wayland-Laufzeitbibliotheken für Godot aus `.tools/debian-libs`, ohne globale Pakete vorauszusetzen.

Betrifft: `.github/actions/swift-toolchain/action.yml`, `.github/workflows/ci.yml` (`SWIFT_VERSION`, `SWIFT_SHA256`, `runs-on`), `scripts/build.sh` (`COMPAT_LIBS`), `scripts/start.sh` (`LOCAL_LIBS`)

import Foundation

/// Mess-Instrument für die Pass-Aufteilung eines Sim-Schritts (Issue #43).
///
/// Absichtlich kein Sampling-Profiler: auf dem Linux-Host gibt es kein `perf`
/// und kein Instruments, und die Frage „welcher Pass kostet wie viel" ist mit
/// Zeitstempeln an den Pass-Grenzen exakt beantwortbar — Sampling schätzt sie
/// nur. Die Instrumentierung ist deshalb dauerhaft im Repo (Wächter gegen die
/// nächste Perf-Regression), aber **standardmäßig aus**: `enabled == false`
/// kostet je Pass genau einen Bool-Load, also nichts Messbares (verifiziert in
/// `docs/perf-measurements.md` §A).
///
/// Bedienung ist ein **Marker-Strom**, kein Closure-Wrapper: `Terrain.step()`
/// setzt vor jedem Pass eine Marke, die den vorherigen Span schließt und den
/// neuen öffnet. Grund: die Pass-Reihenfolge in `step()` ist LEM-Konvention und
/// muss am Stück lesbar bleiben (s. `AGENTS.md`) — eine Marker-Zeile stört das
/// weniger als 20 verschachtelte `prof("…") { … }`-Blöcke.
///
/// Nicht thread-sicher und nicht dafür gedacht: gemessen wird der Hauptthread,
/// auf dem `step()` läuft.
public enum SimProfile {
    /// Schalter. Solange `false`, wird kein Zeitstempel gelesen.
    public nonisolated(unsafe) static var enabled = false

    /// Summierte Zeit je Marke, in Sekunden.
    public nonisolated(unsafe) private(set) static var totals: [String: Double] = [:]
    /// Zahl der Spans je Marke (ein Pass kann pro Schritt mehrfach laufen).
    public nonisolated(unsafe) private(set) static var counts: [String: Int] = [:]

    private nonisolated(unsafe) static var openName: String?
    private nonisolated(unsafe) static var openStart: UInt64 = 0

    /// Schließt den offenen Span und öffnet `name` (bzw. nichts bei `nil`).
    @inline(never)
    public static func mark(_ name: String?) {
        let now = DispatchTime.now().uptimeNanoseconds
        if let open = openName {
            totals[open, default: 0] += Double(now &- openStart) * 1e-9
            counts[open, default: 0] += 1
        }
        openName = name
        openStart = DispatchTime.now().uptimeNanoseconds
    }

    /// Alle Zähler zurücksetzen (nach dem Einlauf aufrufen).
    public static func reset() {
        totals.removeAll()
        counts.removeAll()
        openName = nil
    }

    /// Absteigend nach Gesamtzeit sortierte Aufstellung.
    public static func report() -> [(name: String, seconds: Double, calls: Int)] {
        totals.map { (name: $0.key, seconds: $0.value, calls: counts[$0.key] ?? 0) }
            .sorted { $0.seconds > $1.seconds }
    }
}

import Foundation

/// Höchstens EIN Hintergrund-Job zur Zeit, mit genau einem Ergebnis-Platz.
///
/// Wofür: im Zeitraffer rechnet `SimNode` den Sim-Schritt und die
/// Frame-Aufbereitung (`RenderState.frame`) auf einem Hintergrund-Thread,
/// damit der Hauptthread in der Zeit weiter zeichnet; er lädt nur noch fertige
/// Puffer hoch (Messprotokoll: `docs/perf-measurements.md` §L). Dieser Typ ist
/// die ganze Nebenläufigkeit dabei. Er ist godot-frei, damit sein Vertrag
/// headless prüfbar bleibt (Wächter: `SimCoreTests/BackgroundJobTests.swift`).
///
/// Vertrag: EIN Besitzer-Thread (in Godot der Hauptthread) ruft `start`,
/// `wait` und `take`; nur die Arbeit selbst läuft woanders. Daraus folgt:
/// - Ein Job ist UNTERWEGS (`isPending`) von `start` bis `take`: er rechnet
///   noch, oder sein Ergebnis liegt fertig und ist noch nicht abgeholt.
/// - Solange er rechnet, gehören die Objekte, die er anfasst, ihm allein. Wer
///   sie sonst anfassen will, ruft vorher `wait()`. Danach sieht der Aufrufer
///   jeden Schreibzugriff des Jobs: das Fertig-Signal läuft über die Sperre
///   und die Gruppe, beide sind Speicherbarrieren.
/// - `start`, während ein Job unterwegs ist, startet NICHTS (Rückgabe
///   `false`): das liegende Ergebnis ginge sonst verloren, und mit ihm etwa
///   ein Band-Bau, den der Render-Zustand schon für ausgeliefert hält.
/// - `isReady` blockiert nie. `wait` und `take` blockieren, solange der Job
///   rechnet, und zählen diese Zeit (`waits`, `waitedSeconds`): das ist die
///   Messgröße „der Hauptthread hat auf die Sim gewartet".
///
/// Swift 6 (Issue #201): `@unchecked Sendable` — der Typ IST die
/// Nebenläufigkeit; `running`/`finished`/`output` stehen unter der Sperre,
/// `waits`/`waitedSeconds` gehören laut Vertrag dem Besitzer-Thread allein.
/// Die Arbeit selbst (`start`) bleibt eine nicht-`@Sendable`-Closure: sie
/// erfasst bewusst nicht-`Sendable`-Objekte (Welt, Render-Zustand), die der
/// Vertrag dem Job exklusiv überträgt — genau das kann das Typsystem ohne
/// Besitzer-Disziplin nicht ausdrücken. EINE zentrale
/// `nonisolated(unsafe)`-Erfassung in `start` (statt an jeder Aufrufstelle),
/// dieselbe Bauform wie `Terrain.parallel`: Wer ein Rennen einbaut, baut es
/// durch DIESEN Engpass, und die Tor-Wächter (`BackgroundJobTests`) sehen es.
public final class BackgroundJob<Output>: @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock()
    /// Gruppe des unterwegs befindlichen Jobs, `nil` = keiner.
    private var running: DispatchGroup?
    private var finished = false
    private var output: Output?

    /// Wie oft `wait`/`take` tatsächlich blockiert haben, und wie lange
    /// insgesamt (Sekunden). Nur der Besitzer-Thread schreibt sie.
    public private(set) var waits = 0
    public private(set) var waitedSeconds = 0.0

    /// Test-Haken: läuft auf dem Besitzer-Thread, unmittelbar bevor `wait`
    /// tatsächlich blockiert. Damit geben Wächter einen am Tor gehaltenen Job
    /// genau dann frei, wenn der Zugriff nachweislich wartet, statt das aus
    /// einer Verzögerung abzuleiten (Review #216). Produktion setzt ihn nie.
    var willBlock: (() -> Void)?

    public init(label: String) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Ein Job ist unterwegs: er rechnet, oder sein Ergebnis wartet auf `take`.
    public var isPending: Bool { locked { running != nil } }

    /// Der Job ist fertig, `take` blockiert nicht. Blockiert selbst nie.
    public var isReady: Bool { locked { running != nil && finished } }

    /// Startet `work` im Hintergrund. `false` = es war schon ein Job unterwegs,
    /// nichts gestartet (s. Vertrag).
    @discardableResult
    public func start(_ work: @escaping () -> Output) -> Bool {
        let group = DispatchGroup()
        let claimed: Bool = locked {
            guard running == nil else { return false }
            running = group
            finished = false
            output = nil
            return true
        }
        guard claimed else { return false }
        group.enter()
        nonisolated(unsafe) let unsafeWork = work
        queue.async {
            let result = unsafeWork()
            self.locked {
                self.output = result
                self.finished = true
            }
            group.leave()
        }
        return true
    }

    /// Wartet, bis der unterwegs befindliche Job gerechnet hat; sein Ergebnis
    /// bleibt für `take` liegen. Ohne Job oder mit fertigem Job: sofort zurück.
    public func wait() {
        let (group, done) = locked { (running, finished) }
        guard let group, !done else { return }
        let start = DispatchTime.now().uptimeNanoseconds
        willBlock?()
        group.wait()
        waits += 1
        waitedSeconds += Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    }

    /// Wartet wie `wait` und holt das Ergebnis ab; danach ist kein Job mehr
    /// unterwegs. `nil` = es war keiner unterwegs.
    public func take() -> Output? {
        wait()
        return locked {
            guard running != nil else { return nil }
            let result = output
            running = nil
            finished = false
            output = nil
            return result
        }
    }
}

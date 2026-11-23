import Foundation
import XCTest

enum RepoSource {

    static let extensionDirectory = "Extension/Sources/RiverSimGD"

    static func file(_ relativePath: String) throws -> String {
        let url = try root().appendingPathComponent(relativePath)
        return try XCTUnwrap(try? String(contentsOf: url, encoding: .utf8),
                             "\(relativePath) fehlt oder ist umbenannt — die "
                             + "Kalibrierung wäre damit ungeprüft")
    }

    static func probe(_ relativePath: String) throws -> SourceProbe {
        let language: SourceProbe.Language
        switch (relativePath as NSString).pathExtension {
        case "swift": language = .swift
        case "gd": language = .gdscript
        case "gdshader", "gdshaderinc": language = .gdshader
        default:
            struct UnknownLanguage: Error {}
            XCTFail("Keine Sprachregel für \(relativePath) — SourceProbe.Language erweitern")
            throw UnknownLanguage()
        }
        return SourceProbe(try file(relativePath), language: language)
    }

    static func extensionSources() throws -> SourceProbe {
        let directory = try root().appendingPathComponent(extensionDirectory)
        let names = try XCTUnwrap(
            try? FileManager.default.contentsOfDirectory(atPath: directory.path),
            "\(extensionDirectory) fehlt — die Kalibrierung wäre damit ungeprüft")
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        XCTAssertFalse(names.isEmpty, "Keine Swift-Quellen in \(extensionDirectory)")
        let joined = try names
            .map { try file("\(extensionDirectory)/\($0)") }
            .joined(separator: "\n")
        return SourceProbe(joined, language: .swift, joinedFromMultipleFiles: true)
    }

    private static func root() throws -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let marker = root.appendingPathComponent("AGENTS.md")
        guard FileManager.default.fileExists(atPath: marker.path) else {
            throw XCTSkip("Repo-Wurzel nicht erreichbar (\(root.path) ohne AGENTS.md)")
        }
        return root
    }
}

func assertContains(_ haystack: SourceProbe, _ needle: String, hint: String,
                    file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(haystack.contains(needle),
                  "\(hint) — erwartet im Quelltext (ohne Kommentare): \(needle)",
                  file: file, line: line)
}

func glsl(_ value: Double) -> String { "\(value)" }

func glsl(_ color: (r: Double, g: Double, b: Double)) -> String {
    "vec3(\(color.r), \(color.g), \(color.b))"
}

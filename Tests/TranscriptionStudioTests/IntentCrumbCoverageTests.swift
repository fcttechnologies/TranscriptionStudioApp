import FCTMetrics
import Foundation
import Testing
@testable import TranscriptionStudio

/// Every App Intent reports its own run, under its own name, inside `Diag.intent(_:_:)`.
///
/// An intent is the code most likely to crash with nobody watching — no UI, often no running app,
/// fired from Siri, a widget button, the Control Center or the Lock Screen, against a store opened
/// through the App Group rather than the app's own. A crash there arrives with a trail whose last
/// entry is whatever the person did by hand, possibly hours earlier, and nothing between it and
/// the stack.
///
/// The guard is structural rather than a hand-written list: it reads the intent sources and
/// requires the bracket around every `perform()` that returns an `IntentResult`, which is what
/// makes a new intent that forgets one fail here instead of going silently unreported for the life
/// of the app.
struct IntentCrumbCoverageTests {

    private static var sourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TranscriptionStudioTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources", isDirectory: true)
    }

    /// One declared intent: its type name, the first statement of its `perform()`, and the body.
    struct DeclaredIntent {
        let name: String
        let firstStatement: String
        let body: String
    }

    /// Every type under `Sources` declaring a `perform()` that returns an `IntentResult` — which
    /// is exactly an App Intent's `perform()`, and catches the `@AppIntent(schema:)` macro form
    /// whose declaration line names no protocol at all.
    ///
    /// Source parsing rather than reflection, because what is being checked is how the body is
    /// written: a bracket the compiler can see is one an intent's crash trail actually gets.
    static func declaredIntents(in directory: URL) throws -> [DeclaredIntent] {
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        var found: [DeclaredIntent] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).split(
                separator: "\n", omittingEmptySubsequences: false
            ).map(String.init)
            var currentType: String?
            for (index, line) in lines.enumerated() {
                if let name = typeName(declaredOn: line) { currentType = name }
                guard line.contains("func perform("), let name = currentType else { continue }
                let indent = String(line.prefix { $0 == " " })
                // A long return type is often wrapped, so the signature is read to its opening
                // brace rather than off the one line — an intent whose `perform()` wraps must not
                // be able to slip the sweep by being formatted differently.
                let openBrace = lines[index...].firstIndex { $0.hasSuffix("{") } ?? index
                let signature = lines[index...openBrace].joined(separator: " ")
                guard signature.contains("IntentResult") else { continue }
                // The body runs to the line that closes `perform()` at its own indentation.
                let end = lines[(openBrace + 1)...].firstIndex { $0 == indent + "}" } ?? lines.endIndex
                let body = lines[(openBrace + 1)..<end]
                found.append(DeclaredIntent(
                    name: name,
                    firstStatement: body.first?.trimmingCharacters(in: .whitespaces) ?? "",
                    body: body.joined(separator: "\n")
                ))
                currentType = nil
            }
        }
        return found
    }

    /// The type name on a declaration line, or nil when the line declares none.
    private static func typeName(declaredOn line: String) -> String? {
        let words = line.split(separator: " ").map(String.init)
        guard let keyword = words.firstIndex(where: { $0 == "struct" || $0 == "class" }),
              words[..<keyword].allSatisfy({ ["nonisolated", "public", "final", "internal"].contains($0) }),
              keyword + 1 < words.count else { return nil }
        let name = words[keyword + 1].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return name.isEmpty ? nil : String(name)
    }

    // MARK: Tests

    /// Every intent's body runs inside the bracket, hoisted into the nested `run()` the opaque
    /// return type requires. This is the whole contract, and the sweep is over the declarations
    /// rather than a list, so it cannot go stale by omission.
    @Test func everyIntentRunsInsideTheDiagBracket() throws {
        let intents = try Self.declaredIntents(in: Self.sourcesDirectory)
        #expect(intents.count >= 29, "found only \(intents.count) intents — the sweep missed files")
        let unbracketed = intents
            .filter { !$0.firstStatement.hasPrefix("func run(") || !$0.body.contains("Diag.intent(TranscriptionCrumb.") }
            .map(\.name)
            .sorted()
        #expect(unbracketed.isEmpty,
                "these intents run unreported — a crash in one arrives with no trail: \(unbracketed)")
    }

    /// A name is what the fleet groups on, so two intents sharing one would report as one intent —
    /// and a crumb reused from a screen would file an intent's runs under that screen.
    @Test func everyIntentNameIsDistinctAndNamespaced() throws {
        let intents = try Self.declaredIntents(in: Self.sourcesDirectory)
        let names = intents.compactMap { intent -> String? in
            guard let start = intent.body.range(of: "Diag.intent(TranscriptionCrumb."),
                  let end = intent.body.range(of: ",", range: start.upperBound..<intent.body.endIndex)
            else { return nil }
            return String(intent.body[start.upperBound..<end.lowerBound])
        }
        #expect(names.count == intents.count)
        #expect(Set(names).count == names.count, "two intents share one crumb")
        let cases = Dictionary(uniqueKeysWithValues: TranscriptionCrumb.allCases.map { ("\($0)", $0.diagName) })
        for name in names {
            let wire = try #require(cases[name], "\(name) is not a TranscriptionCrumb case")
            #expect(wire.hasPrefix("intent."),
                    "\(name) is spelled \(wire) — an intent's run must be separable from a screen")
        }
    }

    /// The vocabulary as a whole: one wire name per case, or two surfaces report as one.
    @Test func everyCrumbAndCounterNameIsUnique() {
        let crumbs = TranscriptionCrumb.allCases.map(\.diagName)
        #expect(Set(crumbs).count == crumbs.count)
        let counters = TranscriptionCounter.allCases.map(\.diagName)
        #expect(Set(counters).count == counters.count)
    }
}

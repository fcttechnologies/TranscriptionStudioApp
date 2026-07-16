// `errorDescription` switches for the small pure error enums that back the diarization/model
// stack. Each is deterministic, string-only logic with no hardware/network dependency, but
// wasn't exercised anywhere else since the happy paths never surface these messages to a test.

import Foundation
import Testing
import UniformTypeIdentifiers
@testable import TranscriptionKit

@Suite("SortformerModelError — errorDescription")
struct SortformerModelErrorDescriptionTests {
    @Test func sizeMismatchDescribesFileExpectedAndActual() {
        let error = SortformerModelError.sizeMismatch(file: "main.mlirb", expected: 100, got: 42)
        let message = error.errorDescription ?? ""
        #expect(message.contains("main.mlirb"))
        #expect(message.contains("42"))
        #expect(message.contains("100"))
    }

    @Test func hashMismatchNamesTheFile() {
        let error = SortformerModelError.hashMismatch(file: "mel.f32")
        #expect(error.errorDescription?.contains("mel.f32") == true)
        #expect(error.errorDescription?.contains("SHA-256") == true)
    }

    @Test func downloadFailedCarriesTheUnderlyingMessage() {
        struct Boom: Error, LocalizedError { var errorDescription: String? { "network gone" } }
        let error = SortformerModelError.downloadFailed(file: "metadata.json", underlying: Boom())
        #expect(error.errorDescription?.contains("metadata.json") == true)
        #expect(error.errorDescription?.contains("network gone") == true)
    }

    @Test func httpErrorCarriesTheStatusCode() {
        let error = SortformerModelError.httpError(file: "main.hash", status: 404)
        #expect(error.errorDescription?.contains("404") == true)
        #expect(error.errorDescription?.contains("main.hash") == true)
    }

    @Test func missingArtifactNamesWhatsMissing() {
        let error = SortformerModelError.missingArtifact("metadata.json")
        #expect(error.errorDescription?.contains("metadata.json") == true)
    }
}

@Suite("GraphRunnerError — errorDescription")
struct GraphRunnerErrorDescriptionTests {
    @Test func everyCaseProducesANonEmptyDistinctMessage() {
        let cases: [GraphRunnerError] = [
            .unavailable("no GPU"),
            .functionNotFound("main"),
            .statefulGraphUnsupported(["state_a", "state_b"]),
            .unknownInput("chunk_mel"),
            .shapeMismatch(input: "valid", expected: [1, 378], got: [1, 200]),
            .missingOutput("preds"),
            .unsupportedScalarType("int32"),
        ]
        let messages = cases.map { $0.errorDescription ?? "" }
        #expect(messages.allSatisfy { !$0.isEmpty })
        #expect(Set(messages).count == messages.count)   // every case reads distinctly

        #expect(messages[0].contains("no GPU"))
        #expect(messages[1].contains("main"))
        #expect(messages[2].contains("state_a"))
        #expect(messages[3].contains("chunk_mel"))
        #expect(messages[4].contains("valid"))
        #expect(messages[5].contains("preds"))
        #expect(messages[6].contains("int32"))
    }
}

@Suite("FileIngestError — errorDescription")
struct FileIngestErrorDescriptionTests {
    @Test func unsupportedExtensionNamesTheExtension() {
        let error = FileIngestError.unsupportedExtension("exe")
        #expect(error.errorDescription?.contains(".exe") == true)
    }

    @Test func unsupportedExtensionWithNoExtensionReadsGenerically() {
        let error = FileIngestError.unsupportedExtension("")
        #expect(error.errorDescription == "That file isn't a supported audio/video type.")
    }

    @Test func loadFailedCarriesTheUnderlyingMessage() {
        let error = FileIngestError.loadFailed("file not found")
        #expect(error.errorDescription?.contains("file not found") == true)
    }
}

@Suite("SupportedMediaExtensions.contentTypes")
struct SupportedMediaExtensionsContentTypesTests {
    @Test func includesTheAudioAndMovieSupertypesPlusEveryAllowedExtension() {
        let types = SupportedMediaExtensions.contentTypes
        #expect(types.contains(.audio))
        #expect(types.contains(.movie))
        // The less-standard containers the supertypes miss need their own per-extension type.
        #expect(types.contains(UTType(filenameExtension: "mkv")!))
        #expect(types.contains(UTType(filenameExtension: "flac")!))
        #expect(types.count >= 2)
    }
}

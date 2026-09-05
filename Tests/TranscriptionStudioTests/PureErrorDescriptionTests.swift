// `errorDescription` switches for the small pure error enums that back the diarization/model
// stack. Each is deterministic, string-only logic with no hardware/network dependency, but
// wasn't exercised anywhere else since the happy paths never surface these messages to a test.

import Foundation
import Testing
import UniformTypeIdentifiers
@testable import TranscriptionStudio

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

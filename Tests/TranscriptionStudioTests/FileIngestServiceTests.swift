import Foundation
import Testing
@testable import TranscriptionStudio

@Suite("FileIngestService — extension whitelist")
struct FileIngestServiceTests {

    @Test func acceptsKnownAudioAndVideoExtensions() {
        for ext in ["mp3", "wav", "m4a", "mp4", "ogg", "flac", "opus", "aac", "webm", "mov", "mkv"] {
            #expect(SupportedMediaExtensions.isSupported(URL(fileURLWithPath: "/tmp/clip.\(ext)")))
        }
    }

    @Test func isCaseInsensitive() {
        #expect(SupportedMediaExtensions.isSupported(URL(fileURLWithPath: "/tmp/clip.MP3")))
    }

    @Test func rejectsUnknownExtensions() {
        #expect(!SupportedMediaExtensions.isSupported(URL(fileURLWithPath: "/tmp/clip.exe")))
        #expect(!SupportedMediaExtensions.isSupported(URL(fileURLWithPath: "/tmp/clip")))
        #expect(!SupportedMediaExtensions.isSupported(URL(fileURLWithPath: "/tmp/clip.txt")))
    }

    // A rejected extension throws before ever touching the filesystem/decoder.
    @Test func loadSamplesThrowsForUnsupportedExtension() {
        #expect(throws: FileIngestError.self) {
            _ = try FileIngestService.loadSamples(from: URL(fileURLWithPath: "/tmp/definitely-not-audio.exe"))
        }
    }
}

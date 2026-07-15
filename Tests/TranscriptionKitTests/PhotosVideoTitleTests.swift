import Foundation
import Testing
@testable import TranscriptionKit

@Suite("PhotosVideoTitle — session title derivation")
struct PhotosVideoTitleTests {

    @Test func usesTheFilenameStem() {
        #expect(PhotosVideoTitle.sessionTitle(forFilename: "IMG_1234.MOV") == "IMG_1234")
    }

    @Test func handlesMultipleDotsByStrippingOnlyTheLastExtension() {
        #expect(PhotosVideoTitle.sessionTitle(forFilename: "vacation.clip.mp4") == "vacation.clip")
    }

    @Test func fallsBackWhenTheFilenameIsEmpty() {
        #expect(PhotosVideoTitle.sessionTitle(forFilename: "") == "Imported video")
    }
}

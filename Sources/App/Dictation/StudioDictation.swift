import FCTDictation
import Foundation

/// The two facts about a dictation that are this app's rather than the package's: the container a
/// dictation crosses processes through, and where a finished one is opened.
///
/// Everything else — the phases, the suspension between "start recording" and Done, cancel — is
/// `FCTDictation`'s `DictationController`, which `AppModel` holds one of.
enum StudioDictation {

    /// The container the recording and the finished result cross processes through. Declared on
    /// every target that dictates; `DictationStore` throws when it is missing rather than falling
    /// back to a private directory the app process could not read.
    static let appGroupID = "group.com.fcttechnologies.TranscriptionStudio"

    /// Where a finished dictation is opened. It rides the app's one registered scheme — the HOST
    /// is what separates a dictation hand-off from a share-ingest ping, so no second URL type is
    /// declared for it. Only the id crosses; the words stay in the container.
    static let route = DictationResultRoute(scheme: IngestURLScheme.scheme, host: "dictation")!
}

/// What `DictateIntent` says when a dictation hands back no text. The conformance is the app's
/// because the sentence is: the package would otherwise take an App Intents dependency to say it.
extension DictationControllerError: @retroactive CustomLocalizedStringResourceConvertible {
    public var localizedStringResource: LocalizedStringResource {
        switch self {
        case .cancelled: "Dictation was cancelled."
        case .busy: "A dictation is already in progress."
        }
    }
}

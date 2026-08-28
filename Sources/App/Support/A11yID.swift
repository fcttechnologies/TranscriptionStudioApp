import Foundation

/// Every accessibility identifier the app puts on an interactive control, in one place.
///
/// These are the **driving surface**, not labels: the simulator tools (`SimUI`/`SimTap`) and the
/// Mac tools (`UITree`/`Click`/`Type`) address controls by identifier, and a control without one is
/// invisible to an agent walking the app. They are deliberately separate from the user-facing
/// label — a label is translated ten ways and a test hook must not be.
///
/// Naming: `<surface>.<control>`, and a per-row identifier is the row's own stable id appended by
/// one of the functions below, never an index.
enum A11yID {
    // MARK: Front door
    static let onboardingContinue = "onboarding.continue"
    static let frontDoorLaunching = "frontDoor.launching"
    static let frontDoorRestoring = "frontDoor.restoring"
    static let frontDoorRestoreFailed = "frontDoor.restoreFailed"
    static let frontDoorRetry = "frontDoor.retry"
    static let debugTestAccountSignIn = "debug.testAccount.signIn"
    static let debugTestAccountStatus = "debug.testAccount.status"

    // MARK: Home
    static let homeFeed = "home.feed"
    static let homeActiveWork = "home.activeWork"
    static let homeMiniPlayerPlayback = "home.miniPlayer.playback"
    static let homeMiniPlayerRecording = "home.miniPlayer.recording"
    static let homeMiniPlayerSpeaking = "home.miniPlayer.speaking"

    static func homeSession(_ id: UUID) -> String { "home.session.\(id.uuidString)" }

    // MARK: Toolbar
    static let toolbarAskLibrary = "toolbar.askLibrary"
    static let toolbarCompose = "toolbar.compose"
    static let toolbarInspectorToggle = "toolbar.inspectorToggle"
    static let toolbarSettingsToggle = "toolbar.settingsToggle"
    static let toolbarStop = "toolbar.stop"

    // MARK: Recording
    static let recordCaptionToggle = "record.captionToggle"
    static let recordDiarizationUnavailable = "record.diarizationUnavailable"
    static let recordElapsed = "record.elapsed"
    static let recordFinishing = "record.finishing"
    static let recordJumpToLive = "record.jumpToLive"
    static let recordPreparing = "record.preparing"
    static let recordStop = "record.stop"

    // MARK: Captions
    static let captionJumpToLive = "caption.jumpToLive"
    static let captionSizeControl = "caption.sizeControl"

    // MARK: Session detail
    static let sessionConfidenceToggle = "session.confidenceToggle"
    static let sessionIntelligence = "session.intelligence"
    static let sessionLocation = "session.location"
    static let sessionMore = "session.more"
    static let sessionPlayPause = "session.playPause"
    static let sessionPrivacyToggle = "session.privacyToggle"
    static let sessionRenameField = "session.renameField"
    static let sessionScrubber = "session.scrubber"
    static let sessionSpeak = "session.speak"
    static let sessionSpeed = "session.speed"
    static let sessionTitle = "session.title"

    static func suggestion(_ id: String) -> String { "suggestion.\(id)" }
    static func suggestionDismiss(_ id: String) -> String { "suggestion.dismiss.\(id)" }

    // MARK: Ingest
    static let insertLinkStart = "insertLink.start"
    static let insertLinkURLField = "insertLink.urlField"

    // MARK: Intelligence
    static let askLibraryQuestion = "askLibrary.question"
    static let intelligenceQuestion = "intelligence.question"

    // MARK: Ecosystem drafts
    static let calendarDraftAdd = "calendarDraft.add"
    static let calendarDraftTitle = "calendarDraft.title"
    static let reminderDraftAdd = "reminderDraft.add"
    static let reminderDraftTitle = "reminderDraft.title"

    // MARK: Inspector
    static let inspectorABRun = "inspector.ab.run"
    static let inspectorPanel = "inspector.panel"

    // MARK: Settings
    static let settingsPermissionLocation = "settings.permission.location"
    static let settingsPermissionMicrophone = "settings.permission.microphone"
    static let settingsPermissionScreenRecording = "settings.permission.screenRecording"
    static let settingsSyncStatus = "settings.syncStatus"
    static let settingsRetryRefused = "settings.retryRefused"

    static func settingsStorageModel(_ id: String) -> String { "settings.storage.model.\(id)" }
}

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
    static let frontDoorSpeechModel = "frontDoor.speechModel"
    static let frontDoorSpeechModelDownload = "frontDoor.speechModel.download"
    static let frontDoorSpeechModelSkip = "frontDoor.speechModel.skip"
    static let debugTestAccountSignIn = "debug.testAccount.signIn"
    static let debugTestAccountStatus = "debug.testAccount.status"

    // MARK: Debug tools (Settings, Debug builds only)
    static let debugSeedLibrary = "debug.seedLibrary"
    static let debugResetLibrary = "debug.resetLibrary"
    static let debugToolsStatus = "debug.tools.status"
    static let debugResetConfirm = "debug.resetLibrary.confirm"

    // MARK: Home
    static let homeFeed = "home.feed"
    static let feedEmpty = "home.feed.empty"

    // MARK: Shared chrome
    /// Every sheet's close button, from the one shared toolbar.
    static let sheetClose = "sheet.close"
    static let homeActiveWork = "home.activeWork"
    static let homeMiniPlayerPlayback = "home.miniPlayer.playback"
    static let homeMiniPlayerRecording = "home.miniPlayer.recording"
    static let homeMiniPlayerSpeaking = "home.miniPlayer.speaking"
    static let miniPlayerRecordPauseToggle = "home.miniPlayer.recordPauseToggle"
    static let miniPlayerSpeakPauseToggle = "home.miniPlayer.speakPauseToggle"

    static func homeSession(_ id: UUID) -> String { "home.session.\(id.uuidString)" }

    // MARK: Mac menu-bar commands
    static let commandNewRecording = "command.newRecording"
    static let commandSettings = "command.settings"
    static let commandShowSessions = "command.showSessions"
    static let commandToggleInspector = "command.toggleInspector"

    // MARK: Toolbar
    static let toolbarAskLibrary = "toolbar.askLibrary"
    static let toolbarCompose = "toolbar.compose"

    // MARK: The compose menu's items
    static let composeStartRecording = "compose.startRecording"
    static let composeRecordMeeting = "compose.recordMeeting"
    static let composeChooseFile = "compose.chooseFile"
    static let composeInsertLink = "compose.insertLink"
    static let composeUploadFromPhotos = "compose.uploadFromPhotos"

    // MARK: Destructive confirmations
    static let confirmDeleteSession = "confirm.deleteSession"
    static let confirmDeleteCancel = "confirm.deleteSession.cancel"
    static let signOutKeepLibrary = "confirm.signOutKeepLibrary"
    static let signOutCancel = "confirm.signOut.cancel"
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
    static let sessionRenameSave = "session.rename.save"
    static let sessionRenameCancel = "session.rename.cancel"
    static let speakerClear = "speaker.clear"
    static let speakerChooseContact = "speaker.chooseContact"

    static func suggestion(_ id: String) -> String { "suggestion.\(id)" }
    static func suggestionDismiss(_ id: String) -> String { "suggestion.dismiss.\(id)" }

    // MARK: Ingest
    static let insertLinkStart = "insertLink.start"
    static let insertLinkURLField = "insertLink.urlField"

    // MARK: Intelligence
    static let askLibraryQuestion = "askLibrary.question"
    static let askLibrarySubmit = "askLibrary.submit"
    static let intelligenceQuestion = "intelligence.question"
    static let intelligenceSubmit = "intelligence.submit"
    static let intelligenceRegenerate = "intelligence.regenerate"

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
    static let settingsWordTimestamps = "settings.wordTimestamps"
    static let settingsAutoFollow = "settings.autoFollowTranscript"
    static let settingsOpenMicrophoneSettings = "settings.permission.microphone.open"
    static let settingsStorageConfirmDelete = "settings.storage.confirmDelete"
    static let settingsStorageDismiss = "settings.storage.dismissError"

    static func settingsStorageModel(_ id: String) -> String { "settings.storage.model.\(id)" }
}

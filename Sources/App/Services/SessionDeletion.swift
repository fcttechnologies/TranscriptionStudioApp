import SwiftData

/// Deleting a session is a domain transaction, not a `context.delete`.
///
/// A session fans out to four things the row itself cannot reach, and each one is a defect of its
/// own if it is skipped: the **staged recording** on the blob layer (released before the record
/// that names it goes, while the asset is still readable — afterwards nothing knows the object
/// exists and it is stranded in the account's storage forever), the **Spotlight item** (a hit that
/// opens nothing), the **finished job's card** (a row for a session that is gone), and **playback**
/// (a transport still scrubbing audio whose session no longer exists).
///
/// One implementation, because there are three callers — the feed's swipe and context menu, the
/// `DeleteTranscriptIntent` Siri/Shortcuts path, and the Debug reset — and a fan-out copied per
/// caller is one where the copies drift silently. They already had.
@MainActor
enum SessionDeletion {
    /// Delete one session and everything downstream of it. Saves the context.
    static func delete(_ session: TranscriptSession, in context: ModelContext, app: AppModel) {
        let deletedID = session.id
        // Before the record: the blob ref lives on the session, so releasing after the delete
        // means releasing a ref nothing can still read.
        app.sync?.discardRecording(session.audioAsset)
        if app.playback.nowPlaying?.sessionID == deletedID { app.playback.unload() }
        context.delete(session)
        try? context.save()
        TranscriptSpotlightIndex.deindex(id: deletedID)
        // A finished job's row would otherwise linger after its session is gone; a still-running
        // job has no resultSessionID yet, so it is untouched.
        app.jobs.removeJobs(forSessionID: deletedID)
    }
}

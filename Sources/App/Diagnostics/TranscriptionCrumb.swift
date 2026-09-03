import FCTMetrics

/// The names this app's own work travels under on the crash trail.
///
/// A `String`-backed enum, which is what makes every name a compile-time constant: `Diag` takes no
/// free text anywhere, so nothing a person said or typed can reach a field report through it.
enum TranscriptionCrumb: String, DiagBreadcrumb {
    case dictateIntent = "dictate.intent"
}

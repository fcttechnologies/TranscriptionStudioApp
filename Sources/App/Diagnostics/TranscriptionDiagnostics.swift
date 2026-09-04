import FCTAccount
import FCTMetrics
import Foundation

/// TranscriptionStudio's MetricKit collector and the launch call that starts the always-on diagnostics client.
///
/// The two halves report different things, and both are needed. ``service`` subscribes to
/// MetricKit and persists its payloads into the App Group, which is also the only path that feeds
/// crash and hang reports to ``Diag``; ``Diag`` uploads the anonymous field report — those
/// payloads with the breadcrumb trail that led to them, plus the sign-in, navigation and sync
/// breadcrumbs FCTFoundation already emits.
nonisolated enum TranscriptionDiagnostics {
    nonisolated enum Domain: String, MetricsDomain, CaseIterable {
        case app = "com.fcttechnologies.transcriptionstudio.app"
    }

    static let service = MetricsService<Domain>(
        configuration: MetricsConfiguration(
            appGroupID: AppModelContainer.appGroupID,
            exportFilePrefix: "TranscriptionStudio"
        )
    )

    /// Register MetricKit collection and start the FCT Diagnostics client. Called once at app
    /// init; both halves are idempotent and no-op where their platform pieces are unavailable.
    static func start() {
        service.register(enabledDomains: Domain.allCases)
        Diag.start(DiagConfiguration(
            projectURL: AccountEnvironment.fct.baseURL,
            publishableKey: AccountEnvironment.fct.publishableKey,
            appGroupID: AppModelContainer.appGroupID
        ))
    }
}

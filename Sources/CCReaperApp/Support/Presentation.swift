import CCReaperCore
import SwiftUI

extension MonitorStore {
    var menuBarIcon: String {
        guard let report else {
            return state == .loading ? "arrow.trianglehead.2.clockwise.rotate.90" : "questionmark.circle"
        }
        return switch report.health {
        case .healthy: "checkmark.circle.fill"
        case .attention: "exclamationmark.triangle.fill"
        case .critical: "flame.fill"
        }
    }

    var statusTitle: String {
        if state == .loading { return "Refreshing" }
        guard let report else { return "Status unavailable" }
        return switch report.health {
        case .healthy: "No cleanup needed"
        case .attention: "Cleanup available"
        case .critical: "Runaway process detected"
        }
    }

    var statusTint: Color {
        guard let report else { return .secondary }
        return switch report.health {
        case .healthy: .green
        case .attention: .orange
        case .critical: .red
        }
    }
}

extension FindingClassification {
    var title: String {
        return switch self {
        case .safeToReap: "Safe to reap"
        case .askBeforeKill: "Review first"
        case .doNotKill: "Protected"
        }
    }

    var tint: Color {
        return switch self {
        case .safeToReap: .green
        case .askBeforeKill: .orange
        case .doNotKill: .secondary
        }
    }
}

extension Date {
    var ccReaperTimestamp: String {
        formatted(date: .omitted, time: .standard)
    }
}

import Foundation
import Observation

public enum MonitorViewState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case unavailable(String)
}

public enum MonitorActivity: Equatable, Sendable {
    case idle
    case refreshing
    case previewing
    case cleaning
}

@MainActor
@Observable
public final class MonitorStore {
    public private(set) var state: MonitorViewState = .idle
    public private(set) var activity: MonitorActivity = .idle
    public private(set) var report: MonitorReport?
    public private(set) var lastUpdated: Date?
    public private(set) var errorMessage: String?
    public private(set) var actionOutput: String?
    public private(set) var actionError: String?
    public private(set) var actionTitle: String?
    public private(set) var isCleanupConfirmationRequested = false

    @ObservationIgnored private let service: any CLIServiceProviding
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var refreshLoop: Task<Void, Never>?

    public init(
        service: any CLIServiceProviding = CLIService(),
        defaults: UserDefaults = .standard
    ) {
        self.service = service
        self.defaults = defaults
    }

    public var configuration: AppConfiguration {
        AppConfiguration(defaults: defaults)
    }

    public var isBusy: Bool {
        activity != .idle
    }

    public func start() {
        guard refreshLoop == nil else { return }
        refreshLoop = Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            while !Task.isCancelled {
                let seconds = max(15, self.configuration.refreshInterval)
                do {
                    try await Task.sleep(for: .seconds(seconds))
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                await self.refresh()
            }
        }
    }

    public func stop() {
        refreshLoop?.cancel()
        refreshLoop = nil
    }

    public func refresh() async {
        guard activity == .idle else { return }
        activity = .refreshing
        state = .loading
        errorMessage = nil
        defer { activity = .idle }

        do {
            let configuration = self.configuration
            let report = try await service.scan(
                scriptRoot: configuration.scriptRoot,
                minimumCPU: configuration.minimumCPU
            )
            self.report = report
            self.lastUpdated = Date()
            self.state = .loaded
        } catch {
            let message = Self.message(for: error)
            self.report = nil
            self.state = .unavailable(message)
            self.errorMessage = message
        }
    }

    public func previewCleanup() async {
        guard activity == .idle else { return }
        activity = .previewing
        actionTitle = "Cleanup Preview"
        actionOutput = nil
        actionError = nil
        defer { activity = .idle }

        do {
            actionOutput = try await service.previewCleanup(scriptRoot: configuration.scriptRoot)
        } catch {
            actionError = Self.message(for: error)
        }
    }

    public func requestCleanupReview() {
        isCleanupConfirmationRequested = true
    }

    public func cancelCleanupReview() {
        isCleanupConfirmationRequested = false
    }

    public func confirmCleanup() async {
        isCleanupConfirmationRequested = false
        guard activity == .idle else { return }
        activity = .cleaning
        actionTitle = "Cleanup Result"
        actionOutput = nil
        actionError = nil

        do {
            actionOutput = try await service.runCleanup(scriptRoot: configuration.scriptRoot)
            activity = .idle
            await refresh()
        } catch {
            actionError = Self.message(for: error)
            activity = .idle
        }
    }

    public func clearActionResult() {
        actionTitle = nil
        actionOutput = nil
        actionError = nil
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}

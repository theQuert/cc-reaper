public struct AppLaunchConfiguration: Equatable, Sendable {
    public static let backgroundTestArgument = "--background-test"

    public let activatesForeground: Bool

    public init(arguments: [String]) {
        activatesForeground = !arguments.contains(Self.backgroundTestArgument)
    }
}

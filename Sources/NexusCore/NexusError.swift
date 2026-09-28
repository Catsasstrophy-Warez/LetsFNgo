import Foundation

/// The five error classes from the UX spec (docs/handoff/UX_18_SCREEN_SYSTEM.md,
/// "Errors"). Every error shown to a person is classified into one of them.
public enum ErrorCategory: String, Codable, Sendable, CaseIterable {
    /// The person gave input the system can't use: a malformed value, a missing field.
    case userInput
    /// A source or stored data is missing, unreadable, stale or corrupt.
    case dataSource
    /// The app, OS or runtime failed: storage, memory, cancellation, a bug.
    case systemRuntime
    /// An agent, model or tool failed, or was denied permission.
    case agentTool
    /// Evidence doesn't support a conclusion, or a verification check failed.
    case evidenceVerification

    /// A short human title for the category.
    public var title: String {
        switch self {
        case .userInput: "Input problem"
        case .dataSource: "Data or source problem"
        case .systemRuntime: "System problem"
        case .agentTool: "Agent or tool problem"
        case .evidenceVerification: "Evidence or verification problem"
        }
    }
}

/// Something the person can do next. `commandID` names a command the UI can
/// run directly (a palette command identifier); without one the action is advice.
public struct NextAction: Codable, Sendable, Hashable {
    public var title: String
    public var commandID: String?

    public init(_ title: String, commandID: String? = nil) {
        self.title = title
        self.commandID = commandID
    }
}

/// An error ready to show: what happened, what survived, and what to do next.
///
/// The spec requires all three for every error. `whatSurvived` lists preserved
/// state ("Your draft was kept", "Measurements up to 14:02 are saved"), so the
/// person knows what was *not* lost.
public struct ClassifiedError: Error, Codable, Sendable, Hashable, CustomStringConvertible {
    public var category: ErrorCategory
    public var whatHappened: String
    public var whatSurvived: [String]
    public var nextActions: [NextAction]
    /// `String(describing:)` of the original error, for diagnostics.
    public var underlyingDescription: String

    public init(
        category: ErrorCategory,
        whatHappened: String,
        whatSurvived: [String] = [],
        nextActions: [NextAction] = [],
        underlyingDescription: String = ""
    ) {
        self.category = category
        self.whatHappened = whatHappened
        self.whatSurvived = whatSurvived
        self.nextActions = nextActions
        self.underlyingDescription = underlyingDescription
    }

    public var description: String {
        "[\(category.rawValue)] \(whatHappened)"
    }

    /// A copy that also records `state` as preserved. Callers that know what
    /// they saved (a draft, a partial run) add it where the error is caught.
    public func preserving(_ state: String...) -> ClassifiedError {
        var copy = self
        copy.whatSurvived += state
        return copy
    }

    /// A copy with `action` appended to the next actions.
    public func suggesting(_ action: NextAction) -> ClassifiedError {
        var copy = self
        copy.nextActions.append(action)
        return copy
    }
}

/// An error type that knows its own classification. Module error types adopt
/// this when they can describe themselves; otherwise register a mapper.
public protocol ClassifiableError: Error {
    var classified: ClassifiedError { get }
}

/// Maps errors to `ClassifiedError`. Modules register mappers for error types
/// they own but cannot (or should not) make `ClassifiableError`, such as a
/// dependency's errors.
///
/// Lookup order: an error that already is a `ClassifiedError`; a
/// `ClassifiableError`; registered mappers, newest first; built-in rules for
/// cancellation, decoding and file errors; then a generic system error.
public final class ErrorClassifier: @unchecked Sendable {
    public typealias Mapper = @Sendable (any Error) -> ClassifiedError?

    public static let shared = ErrorClassifier()

    private let lock = NSLock()
    private var mappers: [(id: UUID, map: Mapper)] = []

    public init() {}

    /// Adds a mapper. It returns nil for errors it doesn't handle. Returns a
    /// token that `unregister` accepts.
    @discardableResult
    public func register(_ mapper: @escaping Mapper) -> UUID {
        let id = UUID()
        lock.withLock { mappers.append((id, mapper)) }
        return id
    }

    /// Adds a mapper for one concrete error type.
    @discardableResult
    public func register<E: Error>(_ type: E.Type, _ map: @escaping @Sendable (E) -> ClassifiedError) -> UUID {
        register { error in (error as? E).map(map) }
    }

    public func unregister(_ id: UUID) {
        lock.withLock { mappers.removeAll { $0.id == id } }
    }

    public func classify(_ error: any Error) -> ClassifiedError {
        if let classified = error as? ClassifiedError { return classified }
        if let classifiable = error as? any ClassifiableError {
            var classified = classifiable.classified
            if classified.underlyingDescription.isEmpty {
                classified.underlyingDescription = String(describing: error)
            }
            return classified
        }
        let registered = lock.withLock { mappers.map(\.map) }
        for map in registered.reversed() {
            if var classified = map(error) {
                if classified.underlyingDescription.isEmpty {
                    classified.underlyingDescription = String(describing: error)
                }
                return classified
            }
        }
        return Self.builtIn(error)
    }

    private static func builtIn(_ error: any Error) -> ClassifiedError {
        let underlying = String(describing: error)
        if error is CancellationError {
            return ClassifiedError(
                category: .systemRuntime, whatHappened: "The work was cancelled before it finished.",
                whatSurvived: ["Everything completed before cancelling was kept."],
                nextActions: [NextAction("Run it again")], underlyingDescription: underlying
            )
        }
        if error is DecodingError {
            return ClassifiedError(
                category: .dataSource, whatHappened: "Stored or received data couldn't be read.",
                nextActions: [NextAction("Check the source"), NextAction("Restore from a backup")],
                underlyingDescription: underlying
            )
        }
        if error is EncodingError {
            return ClassifiedError(
                category: .systemRuntime, whatHappened: "A value couldn't be saved in the expected format.",
                nextActions: [NextAction("Try again")], underlyingDescription: underlying
            )
        }
        if let cocoa = error as? CocoaError, cocoa.isFileError {
            return ClassifiedError(
                category: .dataSource, whatHappened: "A file couldn't be read or written.",
                nextActions: [NextAction("Check the file exists and is accessible"), NextAction("Try again")],
                underlyingDescription: underlying
            )
        }
        return ClassifiedError(
            category: .systemRuntime, whatHappened: "Something went wrong.",
            nextActions: [NextAction("Try again")], underlyingDescription: underlying
        )
    }
}

/// Classifies any error through the shared registry. This is the one
/// extension point screens and agents use before showing an error.
public func classify(_ error: any Error) -> ClassifiedError {
    ErrorClassifier.shared.classify(error)
}

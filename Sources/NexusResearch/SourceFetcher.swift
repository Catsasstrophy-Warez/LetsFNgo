import Foundation

/// A source retrieved from outside Nexus, before it is ingested.
public struct FetchedSource: Sendable, Hashable {
    public var url: URL
    public var title: String
    public var mediaType: String
    public var data: Data
    public var retrievedAt: Date

    public init(url: URL, title: String, mediaType: String, data: Data, retrievedAt: Date) {
        self.url = url
        self.title = title
        self.mediaType = mediaType
        self.data = data
        self.retrievedAt = retrievedAt
    }
}

/// Finds and retrieves sources beyond the local library (the web, a vendor
/// portal). Not implemented yet: research runs over local documents and
/// claims only.
///
/// An implementation reaches an external service, so whoever calls it must
/// hold an external-action (P4) permission scoped to that service. Fetched
/// bytes are ingested through `DocumentLibrary` first, so their passages
/// can be cited like any other document's.
public protocol SourceFetcher: Sendable {
    /// A name for permission scoping, e.g. "web".
    var service: String { get }
    func fetch(_ query: String, limit: Int) async throws -> [FetchedSource]
}

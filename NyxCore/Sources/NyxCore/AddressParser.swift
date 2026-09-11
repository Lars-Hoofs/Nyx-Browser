import Foundation

/// Decides what the user meant in the address field: a URL or a search.
public enum AddressParser {
    /// Returns the URL to load for raw address-field input,
    /// or nil when the input is empty.
    public static func destinationURL(for input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Anything with a space is a search phrase.
        if trimmed.contains(" ") { return searchURL(for: trimmed) }

        // Explicit scheme → take it as-is.
        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           ["http", "https", "file", "about"].contains(scheme) {
            return url
        }

        // Bare host heuristic: a dot, or localhost.
        let host = trimmed.split(separator: "/").first.map(String.init) ?? trimmed
        if host.lowercased() == "localhost" || host.lowercased().hasPrefix("localhost:") {
            return URL(string: "http://\(trimmed)")
        }
        if host.contains(".") {
            return URL(string: "https://\(trimmed)")
        }

        return searchURL(for: trimmed)
    }

    /// The search-fallback URL for `query`, unconditionally — public (M4
    /// launcher) because the launcher's trailing "search the web" result
    /// must SEARCH for exactly what the user typed: re-parsing the term
    /// through `destinationURL(for:)` would instead navigate whenever it
    /// happens to look like a bare domain ("example.com"), turning the
    /// explicit search row into a stealth navigation. One public entry
    /// point also keeps the search engine choice in a single place
    /// (LauncherRanker's `searchFallbackHost` already pins the host).
    public static func searchURL(for query: String) -> URL? {
        var components = URLComponents(string: "https://duckduckgo.com/")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url
    }
}

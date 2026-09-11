import ContentBlockerConverter
import CryptoKit
import Foundation

/// One WebKit content-blocker rule list, ready to hand to
/// `WKContentRuleListStore`.
public struct ConvertedRuleList: Equatable {
    /// Stable, content-addressed identifier: `"<name>-v<hash8>"` for a
    /// single-list result, or `"<name>-v<hash8>-<part>"` when the source
    /// had to be split across multiple lists.
    public var identifier: String
    /// WebKit content-blocker JSON (a JSON array, always parseable).
    public var json: String
    /// Number of rules actually represented in `json`.
    public var ruleCount: Int
    /// Number of source rules the converter could not express.
    public var discardedCount: Int
}

/// Wraps SafariConverterLib's `ContentBlockerConverter` behind a small,
/// content-addressed interface for turning AdBlock-syntax filter lists into
/// WebKit content-blocker JSON.
public enum FilterListConverter {
    /// Bump whenever the wrapper's identifier/mapping semantics change, so
    /// previously cached identifiers are never confused with new ones.
    private static let formatVersion = 1

    /// Safari version target used for conversion. Chosen for its 150k rule
    /// ceiling and `:has()` support, matching this app's macOS 26 baseline.
    private static let safariVersion = SafariVersion.safari16_4

    /// Converts AdBlock-syntax filter text to WebKit content-blocker JSON.
    /// Splits the source into chunks so no single result exceeds `maxRules`
    /// source lines (and, in turn, no single JSON list exceeds that many
    /// rules). Each result's `identifier` embeds a stable hash of the
    /// source text, `name`, and the wrapper's format version, so identical
    /// input always yields the same identifier and different input never
    /// collides.
    public static func convert(
        name: String,
        filterText: String,
        maxRules: Int = 150_000
    ) throws -> [ConvertedRuleList] {
        let hash8 = contentHash8(name: name, filterText: filterText)

        let lines = filterText
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        let chunks: [[String]]
        if lines.isEmpty {
            chunks = [[]]
        } else {
            chunks = stride(from: 0, to: lines.count, by: maxRules).map {
                Array(lines[$0..<Swift.min($0 + maxRules, lines.count)])
            }
        }

        let converter = ContentBlockerConverter()
        var results: [ConvertedRuleList] = []
        results.reserveCapacity(chunks.count)

        for (index, chunk) in chunks.enumerated() {
            let conversion = converter.convertArray(
                rules: chunk,
                safariVersion: safariVersion
            )

            guard let data = conversion.converted.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: data)) != nil
            else {
                throw FilterListConverterError.invalidJSON(conversion.converted)
            }

            let identifier = chunks.count == 1
                ? "\(name)-v\(hash8)"
                : "\(name)-v\(hash8)-\(index + 1)"

            results.append(ConvertedRuleList(
                identifier: identifier,
                json: conversion.converted,
                ruleCount: conversion.convertedCount,
                discardedCount: conversion.errorsCount
            ))
        }

        return results
    }

    /// SHA256-based, 8 hex char content hash of the format version, name,
    /// and source filter text.
    private static func contentHash8(name: String, filterText: String) -> String {
        let payload = "v\(formatVersion)\u{0}\(name)\u{0}\(filterText)"
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(8).description
    }
}

public enum FilterListConverterError: Error, Equatable {
    /// The underlying converter produced JSON that failed to parse. Should
    /// not happen in practice; guards against silently caching garbage.
    case invalidJSON(String)
}

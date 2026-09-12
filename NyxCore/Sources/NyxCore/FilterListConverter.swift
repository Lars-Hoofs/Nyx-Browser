import ContentBlockerConverter
import CryptoKit
import Foundation

/// One WebKit content-blocker rule list, ready to hand to
/// `WKContentRuleListStore`.
public struct ConvertedRuleList: Equatable {
    /// Stable, content-addressed identifier: `"<name>-v<hash8>"` for a
    /// single-list result, or `"<name>-v<hash8>-<part>"` when the source
    /// had to be split across multiple lists. Part numbers are assigned
    /// sequentially over the *final* list of results, after any
    /// maxRules-driven re-splitting — a source edit elsewhere in the list
    /// can therefore shift a later part's number even when its own text is
    /// untouched. Identifiers still only ever repeat for byte-identical
    /// `(name, filterText)` pairs.
    public var identifier: String
    /// WebKit content-blocker JSON (a JSON array). Note this is never the
    /// empty string, even for zero convertible rules: SafariConverterLib
    /// falls back to a placeholder single-entry "ignore-previous-rules"
    /// array (`ConversionResult.EMPTY_RESULT_JSON`) rather than `"[]"` in
    /// that case, so callers must trust `ruleCount`, not `json.isEmpty` or
    /// a parsed-array's element count, to know whether anything real is in
    /// here.
    public var json: String
    /// Number of rules actually represented in `json`. Always <= maxRules
    /// unless a single source line's own expansion (e.g. `$denyallow`
    /// across several domains) exceeds maxRules by itself — see
    /// `FilterListConverter.convert`'s splitting note.
    public var ruleCount: Int
    /// Number of source rules the converter could not express. Mirrors
    /// SafariConverterLib's `errorsCount` directly. This is approximate
    /// when the library's own internal per-Safari-version rule ceiling
    /// (150k for Safari >=15, 50k below) fires on a single conversion
    /// call: its `errorsCount` is bumped by a flat +1 sentinel in that
    /// case rather than the true number of truncated rules. In practice
    /// this wrapper keeps every conversion call's input well under that
    /// ceiling (see `maxRules`), so the internal limit is not expected to
    /// fire.
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
    ///
    /// Source lines are first batched into groups of at most `maxRules`
    /// lines each — a reasonable proxy for the output rule budget, since
    /// most source lines produce at most one output rule. Some rules
    /// don't hold to that 1:1 mapping, though: SafariConverterLib expands
    /// `$denyallow` into its blocking rule plus two exception rules per
    /// listed domain, and it splits some ABP snippet rules per statement.
    /// A line-count batch can therefore still convert to more than
    /// `maxRules` actual rules. After converting each batch, its rule
    /// count is checked; if it overshoots and the batch is more than one
    /// source line, the batch is bisected by source line and each half is
    /// converted (and, recursively, checked and re-bisected) on its own.
    /// A single source line whose own expansion alone exceeds `maxRules`
    /// cannot be split further — it is accepted as an oversized result
    /// (logged via NSLog) rather than silently dropping rules.
    ///
    /// Each result's `identifier` embeds a stable hash of the source
    /// text, `name`, and the wrapper's format version, so identical input
    /// always yields the same set of identifiers and different input
    /// never collides. See `ConvertedRuleList.identifier` for how part
    /// numbers are assigned when splitting occurs.
    public static func convert(
        name: String,
        filterText: String,
        maxRules: Int = 150_000
    ) throws -> [ConvertedRuleList] {
        let hash8 = contentHash8(name: name, filterText: filterText)

        let lines = filterText
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        let initialBatches: [[String]]
        if lines.isEmpty {
            initialBatches = [[]]
        } else {
            initialBatches = stride(from: 0, to: lines.count, by: maxRules).map {
                Array(lines[$0..<Swift.min($0 + maxRules, lines.count)])
            }
        }

        let converter = ContentBlockerConverter()
        var conversions: [(lines: [String], conversion: ConversionResult)] = []
        for batch in initialBatches {
            conversions.append(contentsOf: enforceMaxRules(
                lines: batch,
                maxRules: maxRules,
                converter: converter
            ))
        }

        let multiplePartsExpected = conversions.count > 1
        return try conversions.enumerated().map { index, entry in
            guard let data = entry.conversion.converted.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: data)) != nil
            else {
                throw FilterListConverterError.invalidJSON(entry.conversion.converted)
            }

            let identifier = multiplePartsExpected
                ? "\(name)-v\(hash8)-\(index + 1)"
                : "\(name)-v\(hash8)"

            return ConvertedRuleList(
                identifier: identifier,
                json: entry.conversion.converted,
                ruleCount: entry.conversion.convertedCount,
                discardedCount: entry.conversion.errorsCount
            )
        }
    }

    /// Converts `lines` as one batch, then, if the result's rule count
    /// exceeds `maxRules`, bisects `lines` by source line and recurses on
    /// each half until every returned batch either fits `maxRules` or
    /// cannot be split any further (a single source line whose own
    /// expansion alone overshoots `maxRules`).
    private static func enforceMaxRules(
        lines: [String],
        maxRules: Int,
        converter: ContentBlockerConverter
    ) -> [(lines: [String], conversion: ConversionResult)] {
        let conversion = converter.convertArray(rules: lines, safariVersion: safariVersion)

        guard conversion.convertedCount > maxRules, lines.count > 1 else {
            if conversion.convertedCount > maxRules {
                NSLog(
                    "FilterListConverter: a single source line expands to %d rules, " +
                    "exceeding maxRules (%d); accepting the oversized list rather than " +
                    "dropping rules.",
                    conversion.convertedCount, maxRules
                )
            }
            return [(lines, conversion)]
        }

        let mid = lines.count / 2
        let left = enforceMaxRules(
            lines: Array(lines[..<mid]),
            maxRules: maxRules,
            converter: converter
        )
        let right = enforceMaxRules(
            lines: Array(lines[mid...]),
            maxRules: maxRules,
            converter: converter
        )
        return left + right
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

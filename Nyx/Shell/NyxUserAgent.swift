/// Spec §2: the UA must be byte-identical to Safari on the running macOS.
/// WebKit builds "Mozilla/5.0 (…) AppleWebKit/605.1.15 (KHTML, like Gecko)"
/// itself; we append only Safari's own suffix. NEVER add a Nyx token here —
/// that is what triggers Netflix's app-install page and Google's login block.
/// Update the Version/ token alongside macOS releases (site-compat checklist,
/// spec §5.9).
enum NyxUserAgent {
    static let applicationName = "Version/26.0 Safari/605.1.15"
}

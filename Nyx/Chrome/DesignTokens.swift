import AppKit

/// "Night glass" tokens (spec §8). Accent is a token, not a hardcode.
enum DesignTokens {
    /// Warm charcoal base — never pure black.
    static let baseSurface = NSColor(srgbRed: 0x16 / 255.0,
                                     green: 0x16 / 255.0,
                                     blue: 0x14 / 255.0, alpha: 1)
    /// Moonlight-silver specular endpoints (metallic accent, spec §8).
    static let silverBright = NSColor(srgbRed: 0xF2 / 255.0,
                                      green: 0xF2 / 255.0,
                                      blue: 0xF4 / 255.0, alpha: 1)
    static let silverDeep = NSColor(srgbRed: 0xA8 / 255.0,
                                    green: 0xA8 / 255.0,
                                    blue: 0xB0 / 255.0, alpha: 1)
}

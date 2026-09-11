# Passkey entitlement request (user action required)

Nyx needs `com.apple.developer.web-browser.public-key-credential` for
passkeys/WebAuthn on arbitrary domains (spec §2, §5.8). Apple grants it
per-request to browser developers; Chrome and Firefox use the same one.
Until it is granted, passkey sites fail in Nyx with opaque
ASAuthorizationController errors — expected.

## Steps (requires the Apple Developer account holder)

1. Sign in at developer.apple.com with the team that will ship Nyx.
2. Request the "Web Browser Public Key Credential" (passkey) entitlement
   via Apple's request form:
   https://developer.apple.com/contact/request/web-browser-public-key-credential/
3. Suggested request text:

   > Nyx is a native macOS web browser built on WebKit (WKWebView).
   > We request the com.apple.developer.web-browser.public-key-credential
   > entitlement so users can sign in with passkeys (WebAuthn) on any
   > website, using iCloud Keychain and third-party credential providers,
   > as supported for third-party browsers via
   > ASAuthorizationWebBrowserPublicKeyCredentialManager.
   > Bundle ID: com.larshoofs.Nyx

4. After approval: add the entitlement key to `project.yml` under
   `entitlements → properties` and rebuild. Integration work is planned
   for milestone M7.

Status: ☐ requested · ☐ approved · ☐ integrated

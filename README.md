# SSHmply for iOS

Native SwiftUI port of SSHmply (SSH terminal + SFTP + snippets + keys).
Runs on iPhone 8 and newer (iOS 15+), built with the latest Xcode / iOS SDK on GitHub Actions.

- Terminal: [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) over SSH ([Citadel](https://github.com/orlandos-nl/Citadel) / SwiftNIO-SSH)
- SFTP browser with upload / download / preview / rename / delete
- Passwords and private keys in the iOS Keychain; trust-on-first-use host fingerprints
- Ed25519 and RSA (OpenSSH format) keys, in-app Ed25519 key generation
- Languages: es, en, zh, ja (generated from the desktop app's `translations.ts`: `node tools/gen_i18n.mjs <translations.ts> SSHmply/Resources/i18n`)

Project file is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen && xcodegen generate`.

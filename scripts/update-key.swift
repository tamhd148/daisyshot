// Signs update archives so Daisyshot can tell they came from you (Ed25519, CryptoKit).
//
//   swift scripts/update-key.swift generate        # once: creates the private key, prints the public key for the app
//   swift scripts/update-key.swift sign FILE       # prints FILE's signature (base64), for FILE.sig in the release
//   swift scripts/update-key.swift public          # prints the public key again
//
// The private key lives in ~/.config/daisyshot/update-signing-key (or $DAISYSHOT_UPDATE_KEY), never in the repository.
// Keep a backup: without it, installed copies can't verify (and so won't install) your next updates.
import CryptoKit
import Foundation

let keyURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DAISYSHOT_UPDATE_KEY"]
    ?? NSString(string: "~/.config/daisyshot/update-signing-key").expandingTildeInPath)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func loadKey() -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOf: keyURL, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else { fail("No signing key at \(keyURL.path). Run: swift scripts/update-key.swift generate") }
    return key
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "generate":
    if FileManager.default.fileExists(atPath: keyURL.path) { fail("A key already exists at \(keyURL.path); not replacing it.") }
    let key = Curve25519.Signing.PrivateKey()
    try FileManager.default.createDirectory(at: keyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try key.rawRepresentation.base64EncodedString().write(to: keyURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "public":
    print(loadKey().publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard let path = args.dropFirst().first, let data = FileManager.default.contents(atPath: path) else { fail("Usage: sign FILE") }
    print(try loadKey().signature(for: data).base64EncodedString())
default:
    fail("Usage: swift scripts/update-key.swift generate | public | sign FILE")
}

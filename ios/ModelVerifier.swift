import CryptoKit
import Foundation

/// One variant in the manifest (ModelManifest.swift, generated): where its model folder and
/// tokenizer files come from and the sha256 of every file. Paths are relative, "/"-separated.
struct ManifestEntry: Sendable {
  let repo: String
  let revision: String
  let folder: String
  let files: [String: String]
  let tokenizerRepo: String
  let tokenizerRevision: String
  let tokenizerFiles: [String: String]
}

/// Checks a downloaded folder against its manifest entry. No network.
enum ModelVerifier {
  /// Throws `download-failed` unless `folder` holds every file in `files` with the listed sha256
  /// and nothing else, apart from the Hub client's `.cache/` sidecars.
  static func verify(folder: URL, files: [String: String], model: String) throws {
    for (relative, expected) in files.sorted(by: { $0.key < $1.key }) {
      let url = folder.appendingPathComponent(relative)
      guard FileManager.default.fileExists(atPath: url.path) else {
        throw WhisperKitError(.downloadFailed, "Model \(model) failed verification: \(relative) is missing")
      }
      guard try sha256(of: url) == expected else {
        throw WhisperKitError(.downloadFailed, "Model \(model) failed verification: \(relative) does not match the manifest")
      }
    }
    for relative in try regularFiles(under: folder) where !relative.hasPrefix(".cache/") && files[relative] == nil {
      throw WhisperKitError(.downloadFailed, "Model \(model) failed verification: unexpected file \(relative)")
    }
  }

  /// Lowercase hex sha256 of a file, read in 1 MiB chunks so a 100 MB weight file is never
  /// held in memory at once.
  static func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// Every regular file under `folder` (hidden ones included), relative to it, sorted.
  static func regularFiles(under folder: URL) throws -> [String] {
    let root = folder.resolvingSymlinksInPath()
    let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
    guard let enumerator = FileManager.default.enumerator(
      at: root, includingPropertiesForKeys: [.isRegularFileKey], options: []
    ) else {
      return []
    }
    var result: [String] = []
    for case let url as URL in enumerator {
      guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
      let path = url.resolvingSymlinksInPath().path
      guard path.hasPrefix(prefix) else { continue }
      result.append(String(path.dropFirst(prefix.count)))
    }
    return result.sorted()
  }
}

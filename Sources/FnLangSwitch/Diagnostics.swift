import Foundation
// No typed text or ordinary key codes are recorded.
enum Diagnostics {
 static let queue = DispatchQueue(label: "FnLangSwitch.Diagnostics")
 static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/FnLangSwitch/diagnostics.log")
 static func log(_ text: String) {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  let line = formatter.string(from: Date()) + " pid=\(ProcessInfo.processInfo.processIdentifier) " + text + "\n"
  queue.async {
   do {
    let fm = FileManager.default
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let n = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? NSNumber, n.intValue > 2_000_000 {
     let old = url.appendingPathExtension("previous")
     // Keep four previous generations so a sleep/wake incident survives rotation.
     for index in stride(from: 3, through: 1, by: -1) {
      let source = index == 1 ? old : old.appendingPathExtension(String(index - 1))
      let destination = old.appendingPathExtension(String(index))
      if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
      if fm.fileExists(atPath: source.path) { try fm.moveItem(at: source, to: destination) }
     }
     try fm.moveItem(at: url, to: old)
    }
    if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
    let h = try FileHandle(forWritingTo: url)
    defer { try? h.close() }
    try h.seekToEnd()
    try h.write(contentsOf: Data(line.utf8))
   } catch { NSLog("Diagnostics error: %@", String(describing: error)) }
  }
 }
}

import Foundation

struct AppleAccountFailure: LocalizedError {
    let detail: String
    var errorDescription: String? { AuthDiagnostics.summary(detail) }
}

enum AuthDiagnostics {
    struct Entry: Codable, Identifiable {
        let id: UUID
        let date: Date
        let stage: String
        let message: String
    }
    private static let lock = NSLock()
    private static func file(_ paths: WorkspacePaths) -> URL { paths.support.appendingPathComponent("Diagnostics/apple-login.json") }
    static func entries(paths: WorkspacePaths = WorkspacePaths()) -> [Entry] {
        lock.withLock { (try? JSONDecoder().decode([Entry].self, from: Data(contentsOf: file(paths)))) ?? [] }
    }
    static func sanitized(_ value: String, secrets: [String] = []) -> String {
        var text = value
        for secret in secrets where secret.count >= 4 { text = text.replacingOccurrences(of: secret, with: "<redacted>") }
        let patterns: [(String, String)] = [
            (#"\u001B\[[0-9;]*m"#, ""),
            (#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, "<account>"),
            (#"(?s)<data>.*?</data>"#, "<data>redacted</data>"),
            (#"(?:/Users/[^\n]+|\bsrc/[^\s]+):[0-9]+"#, "<source>"),
            (#"(password|authorization|cookie|token|adi_pb|machine_id|one_time_password|private_key|X-Apple-I-MD(?:-[A-Z]+)?)[\"\s:=]+[\"']?[^\s\"'<,}]+"#, "$1=<redacted>"),
            (#"\b[A-Z0-9+/_=-]{64,}\b"#, "<redacted>")
        ]
        for (pattern, replacement) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
            }
        }
        return String(text.prefix(6000))
    }
    static func summary(_ value: String) -> String {
        let text = sanitized(value)
        if let regex = try? NSRegularExpression(pattern: #"Auth error (-?\d+): ([^\n]+)"#),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let code = Range(match.range(at: 1), in: text), let message = Range(match.range(at: 2), in: text) {
            return "Apple 认证返回 \(text[code])：\n\(text[message])\n\n可在「验证服务与诊断」中查看记录。"
        }
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ●├╰│─")) }.filter { !$0.isEmpty && $0 != "<source>" }
        return String((lines.last ?? "Apple ID 验证未完成，请查看诊断记录。").prefix(800))
    }
    static func detail(_ error: Error) -> String { (error as? AppleAccountFailure)?.detail ?? error.localizedDescription }
    static func record(stage: String, message: String, secrets: [String] = [], paths: WorkspacePaths = WorkspacePaths()) {
        lock.withLock {
            let url = file(paths)
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                var entries = (try? JSONDecoder().decode([Entry].self, from: Data(contentsOf: url))) ?? []
                entries.insert(Entry(id: UUID(), date: Date(), stage: stage, message: sanitized(message, secrets: secrets)), at: 0)
                try JSONEncoder().encode(Array(entries.prefix(80))).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                var directory = url.deletingLastPathComponent()
                var values = URLResourceValues(); values.isExcludedFromBackup = true; try directory.setResourceValues(values)
            } catch { /* Diagnostic persistence must not interrupt authentication. */ }
        }
    }
}

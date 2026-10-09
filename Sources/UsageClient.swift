import Foundation
import Security

// MARK: - Model

struct UsageWindow {
    let utilization: Double     // 0–100
    let resetsAt: Date?

    var fraction: Double { min(max(utilization / 100.0, 0), 1) }

    private static let time = formatter("HH:mm")
    private static let dayTime = formatter("EEE HH:mm")

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }

    /// "resets 14:30" or "resets Thu 09:00"
    var resetText: String? {
        guard let resetsAt else { return nil }
        let f = Calendar.current.isDateInToday(resetsAt) ? Self.time : Self.dayTime
        return "resets \(f.string(from: resetsAt))"
    }

    /// "2h 14m left" until reset
    var timeLeftText: String? {
        guard let resetsAt else { return nil }
        let s = resetsAt.timeIntervalSinceNow
        guard s > 0 else { return nil }
        let h = Int(s) / 3600, m = (Int(s) % 3600) / 60
        return h > 0 ? "\(h)h \(m)m left" : "\(m)m left"
    }
}

struct UsageSnapshot {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let fetchedAt: Date
}

enum UsageError: Error, CustomStringConvertible {
    case noToken
    case tokenUnreadable(OSStatus)
    case http(Int)
    case rateLimited
    case network(String)
    case badResponse

    var description: String {
        switch self {
        case .noToken:
            return "No Claude Code login found in the keychain. Sign in with `claude` in a terminal first."
        case .tokenUnreadable(let s):
            return "Could not read the keychain (status \(s)). Check that `security find-generic-password -s \"Claude Code-credentials\"` works in a terminal."
        case .http(let code):
            return "API error (HTTP \(code))."
        case .rateLimited:
            return "Too many requests — waiting longer before the next update."
        case .network(let msg):
            return "Network error: \(msg)"
        case .badResponse:
            return "Unexpected response from the API."
        }
    }
}

// MARK: - Client

enum UsageClient {

    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let keychainService = "Claude Code-credentials"

    // MARK: Keychain token

    /// Claude Code stores its OAuth credentials as a generic password item
    /// with the service name "Claude Code-credentials". The content is JSON
    /// with the field claudeAiOauth.accessToken.
    ///
    /// Reads go through /usr/bin/security instead of SecItemCopyMatching.
    /// The keychain ACL is bound to the calling binary's code signature. This
    /// app is ad hoc signed, so its cdhash changes on every build and "Always
    /// Allow" stops applying immediately. /usr/bin/security is Apple-signed and
    /// stable — and it is the same binary Claude Code writes the item with, so
    /// it is already in the ACL. No dialog.
    static func readToken() -> Result<String, UsageError> {
        switch readTokenViaSecurityCLI() {
        case .success(let blob):
            return parseCredentialBlob(blob)
        case .failure(let cliError):
            // Fallback: the keychain API directly. May trigger a dialog, but
            // better than failing if the security binary is missing.
            switch readTokenViaSecItem() {
            case .success(let blob): return parseCredentialBlob(blob)
            case .failure:          return .failure(cliError)
            }
        }
    }

    /// `security find-generic-password -s "Claude Code-credentials" -w`
    private static func readTokenViaSecurityCLI() -> Result<Data, UsageError> {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = ["find-generic-password", "-s", keychainService, "-w"]

        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr

        do {
            try task.run()
        } catch {
            return .failure(.network("Could not run /usr/bin/security: \(error.localizedDescription)"))
        }

        // Drain before waitUntilExit, otherwise the pipe can fill up and deadlock.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        _ = stderr.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard task.terminationStatus == 0 else {
            // 44 = SecKeychainSearchCopyNext: item not found
            return task.terminationStatus == 44
                ? .failure(.noToken)
                : .failure(.tokenUnreadable(OSStatus(task.terminationStatus)))
        }

        let trimmed = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let blob = trimmed.data(using: .utf8) else {
            return .failure(.noToken)
        }
        return .success(blob)
    }

    private static func readTokenViaSecItem() -> Result<Data, UsageError> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return .failure(.noToken) }
            return .success(data)
        case errSecItemNotFound:
            return .failure(.noToken)
        default:
            return .failure(.tokenUnreadable(status))
        }
    }

    private static func parseCredentialBlob(_ data: Data) -> Result<String, UsageError> {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            return .failure(.noToken)
        }
        return .success(token)
    }

    // MARK: Fetch usage

    /// Blocks while reading the keychain; call off the main thread.
    static func fetch(completion: @escaping (Result<UsageSnapshot, UsageError>) -> Void) {
        let token: String
        switch readToken() {
        case .success(let t): token = t
        case .failure(let e): completion(.failure(e)); return
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15

        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error {
                completion(.failure(.network(error.localizedDescription)))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(.badResponse))
                return
            }
            switch http.statusCode {
            case 200:
                break
            case 429:
                completion(.failure(.rateLimited))
                return
            default:
                completion(.failure(.http(http.statusCode)))
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure(.badResponse))
                return
            }
            completion(.success(parse(json)))
        }.resume()
    }

    // MARK: Parsing

    private static func parse(_ json: [String: Any]) -> UsageSnapshot {
        func window(_ any: Any?) -> UsageWindow? {
            guard let dict = any as? [String: Any] else { return nil }
            guard let util = dict["utilization"] as? Double
                    ?? (dict["utilization"] as? Int).map(Double.init) else { return nil }
            var resets: Date? = nil
            if let s = dict["resets_at"] as? String {
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                resets = iso.date(from: s)
                if resets == nil {
                    iso.formatOptions = [.withInternetDateTime]
                    resets = iso.date(from: s)
                }
            }
            return UsageWindow(utilization: util, resetsAt: resets)
        }

        return UsageSnapshot(
            fiveHour: window(json["five_hour"]),
            sevenDay: window(json["seven_day"]),
            fetchedAt: Date()
        )
    }
}

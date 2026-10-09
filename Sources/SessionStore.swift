import Foundation
import Combine

enum SessionState: String, Codable, Sendable {
    case waiting, working, done

    var rank: Int {
        switch self {
        case .waiting: 0
        case .working: 1
        case .done: 2
        }
    }

    var label: String {
        switch self {
        case .waiting: "Waiting for you"
        case .working: "Working"
        case .done: "Done"
        }
    }

    var emoji: String {
        switch self {
        case .waiting: "🔴"
        case .working: "🟡"
        case .done: "🟢"
        }
    }
}

private struct StatusFile: Codable {
    let session_id: String
    let state: SessionState
    let detail: String?
    let cwd: String?
    let transcript: String?
    let ts: Double
}

struct Session: Identifiable, Equatable, Sendable {
    let id: String
    var state: SessionState
    var detail: String
    var cwd: String
    var updated: Date
    var produced: Int   // output + newly written input tokens
    var context: Int    // latest request's context size
    var remoteURL: String?   // set when the session is connected to remote control

    var isRemote: Bool { remoteURL != nil }

    var name: String {
        let n = (cwd as NSString).lastPathComponent
        return n.isEmpty ? String(id.prefix(6)) : n
    }

    var contextPercent: Int? {
        guard context > 0 else { return nil }
        let limit = context > 200_000 ? 1_000_000 : 200_000
        return min(100, Int((Double(context) / Double(limit) * 100).rounded()))
    }
}

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []

    let dir: URL
    private let scanner: SessionScanner
    private var source: DispatchSourceFileSystemObject?
    private var timer: Timer?

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        dir = home.appendingPathComponent(".claude/lantern", isDirectory: true)
        scanner = SessionScanner(dir: dir,
                                 claudeSessionsDir: home.appendingPathComponent(".claude/sessions", isDirectory: true))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        watch()
        reload()
        // Picks up sessions whose process died without SessionEnd
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func watch() {
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        // Each hook run fires several events; let them settle into one scan
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.reload(after: 0.1) }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    func reload(after delay: TimeInterval = 0) {
        scanner.scan(after: delay) { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, result != self.sessions else { return }
                    self.sessions = result
                }
            }
        }
    }

    func remove(_ s: Session) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(s.id + ".json"))
        reload()
    }

    func removeDone() {
        for s in sessions where s.state == .done { remove(s) }
    }
}

/// Builds the session list from the status files, off the main thread.
/// Everything here runs on its own serial queue.
final class SessionScanner: @unchecked Sendable {
    private let dir: URL
    private let claudeSessionsDir: URL
    private let reader = TranscriptReader()
    private let queue = DispatchQueue(label: "lantern.scan", qos: .utility)
    private var pending = false

    /// Sessions not updated for this long are considered dead (VS Code closed without SessionEnd).
    private let staleAfter: TimeInterval = 12 * 3600

    init(dir: URL, claudeSessionsDir: URL) {
        self.dir = dir
        self.claudeSessionsDir = claudeSessionsDir
    }

    /// Requests made while a scan is waiting to run are folded into it.
    func scan(after delay: TimeInterval, done: @escaping ([Session]) -> Void) {
        queue.async { [self] in
            guard !pending else { return }
            pending = true
            queue.asyncAfter(deadline: .now() + delay) { [self] in
                pending = false
                done(scan())
            }
        }
    }

    private func scan() -> [Session] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        var result: [Session] = []
        let running = readRunningSessions()

        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let f = try? decoder.decode(StatusFile.self, from: data) else { continue }
            let updated = Date(timeIntervalSince1970: f.ts)
            if Date().timeIntervalSince(updated) > staleAfter {
                try? fm.removeItem(at: url)
                reader.forget(f.transcript ?? "")
                continue
            }
            // Claude Code has a registration for the session but the process is gone:
            // VS Code closed without SessionEnd. Remove now instead of waiting 12 h.
            let live = running[f.session_id]
            if let live, !live.alive {
                try? fm.removeItem(at: url)
                reader.forget(f.transcript ?? "")
                continue
            }
            let usage = reader.usage(for: f.transcript ?? "")
            result.append(Session(
                id: f.session_id,
                state: f.state,
                detail: f.detail ?? "",
                cwd: f.cwd ?? "",
                updated: updated,
                produced: usage.produced,
                context: usage.context,
                remoteURL: live?.bridgeID.map { "https://claude.ai/code/\($0)" }))
        }

        result.sort { ($0.state.rank, $0.name, $0.id) < ($1.state.rank, $1.name, $1.id) }
        return result
    }

    private struct RunningInfo { var alive: Bool; var bridgeID: String? }

    /// ~/.claude/sessions/<pid>.json is written by Claude Code for each running process.
    /// bridgeSessionId is present when the session is connected to remote control.
    private func readRunningSessions() -> [String: RunningInfo] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: claudeSessionsDir, includingPropertiesForKeys: nil)) ?? []
        var map: [String: RunningInfo] = [:]
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sid = obj["sessionId"] as? String else { continue }
            let pid = (obj["pid"] as? NSNumber)?.int32Value ?? 0
            let alive = pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
            let bridge = (obj["bridgeSessionId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            // The same session can appear in several files (e.g. resumed) – a live one wins.
            var info = map[sid] ?? RunningInfo(alive: false, bridgeID: nil)
            if alive {
                info.alive = true
                info.bridgeID = bridge
            }
            map[sid] = info
        }
        return map
    }
}

/// Reads Claude Code's transcript (JSONL) incrementally and sums token usage.
final class TranscriptReader {
    struct Usage { var produced = 0; var context = 0 }

    private struct Cache {
        var offset: UInt64 = 0
        var remainder = Data()
        var perMessage: [String: Int] = [:]   // the same message can be logged on several lines
        var usage = Usage()
    }

    private var cache: [String: Cache] = [:]
    // Most of a transcript is tool output; only assistant lines carry usage, so skip parsing the rest
    private static let marker = Data(#""type":"assistant""#.utf8)
    private static let usageKey = Data(#""usage":{"#.utf8)
    private static let idKey = Data(#""id":""#.utf8)
    private static let sidechainKey = Data(#""isSidechain":true"#.utf8)

    func forget(_ path: String) { cache[path] = nil }

    func usage(for path: String) -> Usage {
        guard !path.isEmpty, let h = FileHandle(forReadingAtPath: path) else { return Usage() }
        defer { try? h.close() }

        var c = cache[path] ?? Cache()
        let size = (try? h.seekToEnd()) ?? 0
        if size < c.offset { c = Cache() }   // the file was rewritten

        if size > c.offset {
            try? h.seek(toOffset: c.offset)
            // Without the pool every chunk stays alive until the run loop drains, i.e. the whole file
            while let chunk = autoreleasepool(invoking: { try? h.read(upToCount: 4 << 20) }), !chunk.isEmpty {
                c.offset += UInt64(chunk.count)
                let data = c.remainder + chunk
                var start = 0
                // memchr: Data.firstIndex(of:) is about 10× slower on large transcripts
                while let nl = data.withUnsafeBytes({ b in
                    memchr(b.baseAddress! + start, 0x0A, b.count - start).map { UnsafeRawPointer($0) - b.baseAddress! }
                }) {
                    let line = data[start..<nl]
                    if line.range(of: Self.marker) != nil { process(line, &c) }
                    start = nl + 1
                }
                c.remainder = Data(data[start...])   // incomplete last line, read next time
            }
        }

        cache[path] = c
        return c.usage
    }

    /// Parses only message.usage, not the whole line, which can hold large tool inputs.
    /// usage comes after the content, so it is the last "usage" key on the line.
    private func process(_ line: Data, _ c: inout Cache) {
        guard let key = line.range(of: Self.usageKey, options: .backwards) else { return }
        let open = key.upperBound - 1
        var depth = 0
        guard let close = line[open...].firstIndex(where: {
                  if $0 == UInt8(ascii: "{") { depth += 1 } else if $0 == UInt8(ascii: "}") { depth -= 1 }
                  return depth == 0
              }),
              let u = try? JSONSerialization.jsonObject(with: line[open...close]) as? [String: Any] else { return }

        func n(_ k: String) -> Int { (u[k] as? NSNumber)?.intValue ?? 0 }
        let input = n("input_tokens")
        let cacheWrite = n("cache_creation_input_tokens")
        let cacheRead = n("cache_read_input_tokens")
        let output = n("output_tokens")

        // Subagents count toward usage but don't affect the main session's context
        if line.range(of: Self.sidechainKey) == nil {
            c.usage.context = input + cacheWrite + cacheRead + output
        }

        let id = line.range(of: Self.idKey).flatMap { r in
            line[r.upperBound...].firstIndex(of: UInt8(ascii: "\"")).map {
                String(decoding: line[r.upperBound..<$0], as: UTF8.self)
            }
        } ?? UUID().uuidString
        let value = input + cacheWrite + output
        c.usage.produced += value - (c.perMessage[id] ?? 0)
        c.perMessage[id] = value
    }
}

import Foundation

/// What resuming a conversation will cost before it says anything new.
///
/// Every request carries the whole conversation, so the price of a turn turns on whether the
/// prompt cache still holds it. Claude Code keeps a cached prefix for an hour, refreshed by
/// each read; past that, the next message writes the whole history back into the cache at a
/// premium. A session's transcript records what that history came to, so omux can say so
/// before the session is opened rather than after the bill.
enum SessionCacheNote {
    /// How long a cached prefix lives without being read. Which one applies is recorded in
    /// the transcript, turn by turn.
    static func life(ofTTL ttl: String) -> TimeInterval? {
        switch ttl {
        case "5m": return 5 * 60
        case "1h": return 60 * 60
        default: return nil
        }
    }

    /// What a session's transcript says about its last turn.
    struct Reading: Equatable {
        /// The conversation as the model last saw it: what was sent, read from cache and
        /// written to it.
        let contextTokens: Int
        /// When that turn happened — the cached copy's clock starts here.
        let at: Date
        /// How long that turn asked the cache to hold it: "5m" or "1h".
        let ttl: String?
    }

    /// What the cached copy is doing now.
    enum State: Equatable {
        /// Nothing has been sent in this session yet, or the transcript doesn't say.
        case unknown
        /// Still held, with this many whole minutes left.
        case warm(minutesLeft: Int)
        /// Gone: the next message writes the conversation back into the cache.
        case cold(idle: TimeInterval, tokens: Int?)
    }

    static func state(for reading: Reading?, now: Date = Date()) -> State {
        guard let reading, let ttl = reading.ttl, let life = life(ofTTL: ttl) else { return .unknown }
        let left = min(life, reading.at.addingTimeInterval(life).timeIntervalSince(now))
        if left > 0 { return .warm(minutesLeft: Int(ceil(left / 60))) }
        return .cold(idle: now.timeIntervalSince(reading.at), tokens: reading.contextTokens > 0 ? reading.contextTokens : nil)
    }

    /// The line to show under a session, or nothing while the cache is still warm or the
    /// session has no conversation behind it yet.
    static func note(for reading: Reading?, now: Date = Date()) -> String? {
        guard case let .cold(idle, tokens) = state(for: reading, now: now) else { return nil }
        let what = tokens.map { "about \(tokenText($0)) tokens" } ?? "the conversation"
        return "Idle \(idleText(idle)). The prompt cache has likely expired, so your next message will re-cache \(what)."
    }

    /// "3d 23h", "2h 5m", "14m" — the two largest units, as the agent's own editors say it.
    static func idleText(_ idle: TimeInterval) -> String {
        let minutes = max(0, Int(idle / 60))
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }

    /// "711k", "1.2M" — as the agent's own warning counts them.
    static func tokenText(_ tokens: Int) -> String {
        if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
        if tokens >= 1_000 { return "\(Int((Double(tokens) / 1_000).rounded()))k" }
        return "\(tokens)"
    }

    /// The last turn recorded in a transcript. Only the end of the file is read: a long
    /// conversation runs to megabytes and the answer is in its last lines.
    static func reading(ofTranscriptAt url: URL, tailBytes: Int = 1 << 18) -> Reading? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let from = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: from)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        return reading(inTranscriptTail: text)
    }

    /// The same, from the text of a transcript's tail.
    static func reading(inTranscriptTail tail: String) -> Reading? {
        // A tail can start mid-line; that line simply fails to parse and is skipped.
        for row in tail.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let data = row.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }
            let tokens = (usage["input_tokens"] as? Int ?? 0)
                + (usage["cache_read_input_tokens"] as? Int ?? 0)
                + (usage["cache_creation_input_tokens"] as? Int ?? 0)
            guard tokens > 0 else { continue }
            let at = (object["timestamp"] as? String).flatMap(stamp(_:)) ?? Date()
            return Reading(contextTokens: tokens, at: at, ttl: object["promptCacheRequested"] as? String)
        }
        return nil
    }

    private static let clock: ISO8601DateFormatter = {
        let clock = ISO8601DateFormatter()
        clock.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return clock
    }()

    private static func stamp(_ text: String) -> Date? {
        clock.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// Keeps each session's last-turn reading up to date, off the main thread.
///
/// A transcript is read at most every half minute and only at its end, so a sidebar full of
/// long conversations costs nothing to draw.
@MainActor
final class SessionCacheMonitor: ObservableObject {
    static let shared = SessionCacheMonitor()

    @Published private(set) var readings: [UUID: SessionCacheNote.Reading] = [:]
    private var lookedAt: [UUID: Date] = [:]
    private var reading: Set<UUID> = []
    private let interval: TimeInterval = 30
    private let queue = DispatchQueue(label: "net.pf1.omux.cache-note", qos: .utility)

    /// The note for a session, asking for a fresh reading when one is due.
    func note(for id: UUID, transcript: @autoclosure () -> URL?) -> String? {
        if !reading.contains(id), Date().timeIntervalSince(lookedAt[id] ?? .distantPast) > interval {
            lookedAt[id] = Date()
            if let url = transcript() {
                reading.insert(id)
                queue.async { [weak self] in
                    let found = SessionCacheNote.reading(ofTranscriptAt: url)
                    Task { @MainActor in
                        guard let self else { return }
                        self.reading.remove(id)
                        if let found { self.readings[id] = found }
                    }
                }
            }
        }
        return SessionCacheNote.note(for: readings[id])
    }
}

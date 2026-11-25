import Foundation

/// Compact now-playing payload for an unsandboxed notch helper (Vorssaint).
/// Petrichor is sandboxed, so the file lives in the app container; the helper
/// reads it by path (including via the distributed notification).
enum NotchBridgeSnapshot {
    static let formatVersion = 1
    static let fileName = "vorssaint-bridge.json"
    static let stateChanged = Notification.Name("org.Petrichor.stateChanged")
    static let playQueueIndex = Notification.Name("org.Petrichor.playQueueIndex")
    static let maximumUpcoming = 20
    static let maximumLyricLines = 2000
    static let maximumBytes = 256 * 1024

    struct Track: Equatable {
        let index: Int
        let title: String
        let artist: String
        let duration: Double
    }

    struct Line: Equatable {
        let time: Double
        let text: String
    }

    struct Lyrics: Equatable {
        let timed: Bool
        let instrumental: Bool
        let plain: String
        let lines: [Line]
    }

    struct Payload: Equatable {
        let version: Int
        let bundleIdentifier: String
        let currentIndex: Int
        let current: Track?
        let lyrics: Lyrics?
        let queue: [Track]
    }

    static func payload(
        bundleIdentifier: String,
        currentIndex: Int,
        tracks: [Track],
        lyrics: Lyrics?
    ) -> Payload {
        let current = tracks.indices.contains(currentIndex) ? tracks[currentIndex] : nil
        return Payload(
            version: formatVersion,
            bundleIdentifier: bundleIdentifier,
            currentIndex: current.map { $0.index } ?? -1,
            current: current,
            lyrics: lyrics,
            queue: tracks
        )
    }

    static func encode(_ payload: Payload) throws -> Data {
        var object: [String: Any] = [
            "version": payload.version,
            "bundleIdentifier": payload.bundleIdentifier,
            "currentIndex": payload.currentIndex,
            "queue": upcoming(in: payload).map(trackObject)
        ]
        if let current = payload.current {
            object["current"] = trackObject(current)
        }
        if let lyrics = payload.lyrics {
            object["lyrics"] = [
                "timed": lyrics.timed,
                "instrumental": lyrics.instrumental,
                "plain": String(lyrics.plain.prefix(maximumBytes / 2)),
                "lines": lyrics.lines.prefix(maximumLyricLines).map {
                    ["time": $0.time, "text": String($0.text.prefix(4096))] as [String: Any]
                }
            ]
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func playIndex(from userInfo: [AnyHashable: Any]?) -> Int? {
        let value: Int?
        if let number = userInfo?["index"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            value = Int(exactly: number.doubleValue)
        } else {
            value = userInfo?["index"] as? Int
        }
        guard let value, value >= 0, value <= 10_000 else { return nil }
        return value
    }

    private static func upcoming(in payload: Payload) -> [Track] {
        let start = payload.currentIndex >= 0 ? payload.currentIndex : 0
        return Array(payload.queue.dropFirst(min(start, payload.queue.count)).prefix(maximumUpcoming + 1))
    }

    private static func trackObject(_ track: Track) -> [String: Any] {
        [
            "index": track.index,
            "title": String(track.title.prefix(4096)),
            "artist": String(track.artist.prefix(1024)),
            "duration": track.duration.isFinite ? track.duration : 0
        ]
    }
}

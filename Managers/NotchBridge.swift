import AppKit
import Combine
import Foundation

/// Publishes Petrichor's lyrics and playback queue for Vorssaint's notch, and
/// plays a queue row when that helper asks. File I/O stays inside the sandbox
/// container (`Application Support/<bundle id>/`); the helper is not sandboxed
/// and reads the path from a distributed notification. Nothing is written or
/// preloaded unless Vorssaint is running.
@MainActor
final class NotchBridge {
    private nonisolated static let helperBundleIdentifiers: Set<String> = ["com.vorssaint.utils", "com.vorssaint.utils.dev"]

    private let playbackManager: PlaybackManager
    private let playlistManager: PlaylistManager
    private let libraryManager: LibraryManager
    private var cancellables = Set<AnyCancellable>()
    private var playObserver: NSObjectProtocol?
    private var launchObserver: NSObjectProtocol?
    private var lyricsTask: Task<Void, Never>?
    private var lastData: Data?
    private let ioQueue = DispatchQueue(label: "org.petrichor.notch-bridge", qos: .utility)
    private let fileURL: URL?

    init(playbackManager: PlaybackManager, playlistManager: PlaylistManager, libraryManager: LibraryManager) {
        self.playbackManager = playbackManager
        self.playlistManager = playlistManager
        self.libraryManager = libraryManager
        fileURL = Self.makeFileURL()

        playObserver = DistributedNotificationCenter.default().addObserver(
            forName: NotchBridgeSnapshot.playQueueIndex,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let index = NotchBridgeSnapshot.playIndex(from: notification.userInfo)
            Task { @MainActor in
                self?.playQueueIndex(index)
            }
        }

        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard Self.isHelper(app) else { return }
            Task { @MainActor in
                self?.publish()
            }
        }

        playbackManager.$currentTrack
            .combineLatest(
                playbackManager.$currentStation,
                playlistManager.$currentQueue,
                playlistManager.$currentQueueIndex
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _, _ in
                self?.publish()
            }
            .store(in: &cancellables)

        LyricsStore.shared.$cached
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.writeSnapshot()
            }
            .store(in: &cancellables)

        publish()
    }

    func clear() {
        lyricsTask?.cancel()
        lyricsTask = nil
        lastData = nil
        guard let fileURL else { return }
        ioQueue.sync {
            try? FileManager.default.removeItem(at: fileURL)
        }
        postStateChanged(path: fileURL.path)
    }

    private nonisolated static func isHelper(_ app: NSRunningApplication?) -> Bool {
        app?.bundleIdentifier.map(helperBundleIdentifiers.contains) ?? false
    }

    private var helperIsRunning: Bool {
        NSWorkspace.shared.runningApplications.contains(where: Self.isHelper)
    }

    private func publish() {
        writeSnapshot()
        loadLyricsIfNeeded()
    }

    private func loadLyricsIfNeeded() {
        guard helperIsRunning, playbackManager.currentStation == nil,
              let track = playbackManager.currentTrack else {
            lyricsTask?.cancel()
            lyricsTask = nil
            return
        }
        if let cached = LyricsStore.shared.cachedLyrics(for: track.id), cached.trackId == track.id {
            return
        }
        lyricsTask?.cancel()
        let trackId = track.id
        lyricsTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await LyricsStore.shared.lyrics(
                    for: track,
                    using: self.libraryManager.databaseManager.dbQueue,
                    databaseManager: self.libraryManager.databaseManager
                )
            } catch is CancellationError {
                return
            } catch {
                Logger.warning("Notch bridge lyrics load failed: \(error)")
            }
            guard !Task.isCancelled, self.playbackManager.currentTrack?.id == trackId else { return }
            self.writeSnapshot()
        }
    }

    private func writeSnapshot() {
        guard let fileURL, helperIsRunning else { return }
        let payload = makePayload()
        let data: Data
        do {
            data = try NotchBridgeSnapshot.encode(payload)
        } catch {
            Logger.warning("Notch bridge encode failed: \(error)")
            return
        }
        guard data != lastData else { return }
        lastData = data
        let path = fileURL.path
        ioQueue.async { [weak self] in
            do {
                try data.write(to: fileURL, options: .atomic)
                Logger.info("Notch bridge wrote snapshot (\(data.count) bytes)")
                DispatchQueue.main.async {
                    self?.postStateChanged(path: path)
                }
            } catch {
                Logger.warning("Notch bridge write failed: \(error)")
            }
        }
    }

    private func makePayload() -> NotchBridgeSnapshot.Payload {
        let bundle = AppInfo.bundleIdentifier
        if playbackManager.currentStation != nil {
            return NotchBridgeSnapshot.payload(
                bundleIdentifier: bundle,
                currentIndex: -1,
                tracks: [],
                lyrics: nil
            )
        }
        let tracks = playlistManager.currentQueue.enumerated().map { index, track in
            NotchBridgeSnapshot.Track(
                index: index,
                title: track.title,
                artist: track.displayArtist,
                duration: track.duration
            )
        }
        let index = playlistManager.currentQueueIndex
        let lyrics = lyricsPayload(for: playbackManager.currentTrack)
        return NotchBridgeSnapshot.payload(
            bundleIdentifier: bundle,
            currentIndex: index,
            tracks: tracks,
            lyrics: lyrics
        )
    }

    private func lyricsPayload(for track: Track?) -> NotchBridgeSnapshot.Lyrics? {
        guard let track, let cached = LyricsStore.shared.cachedLyrics(for: track.id),
              !cached.lines.isEmpty else { return nil }
        let lines = cached.lines.prefix(NotchBridgeSnapshot.maximumLyricLines).map {
            NotchBridgeSnapshot.Line(time: $0.startTime, text: $0.text)
        }
        let plain = cached.lines.map(\.text).joined(separator: "\n")
        return NotchBridgeSnapshot.Lyrics(
            timed: cached.hasTimed,
            instrumental: false,
            plain: plain,
            lines: cached.hasTimed ? Array(lines) : []
        )
    }

    private func playQueueIndex(_ index: Int?) {
        guard let index else { return }
        Logger.info("Notch bridge play request for queue index \(index)")
        playlistManager.playFromQueue(at: index)
    }

    private func postStateChanged(path: String) {
        DistributedNotificationCenter.default().postNotificationName(
            NotchBridgeSnapshot.stateChanged,
            object: nil,
            userInfo: [
                "path": path,
                "bundleIdentifier": AppInfo.bundleIdentifier
            ],
            deliverImmediately: true
        )
    }

    private static func makeFileURL() -> URL? {
        do {
            let root = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let directory = root.appendingPathComponent(AppInfo.bundleIdentifier, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory.appendingPathComponent(NotchBridgeSnapshot.fileName)
        } catch {
            Logger.error("Failed to prepare notch bridge storage: \(error)")
            return nil
        }
    }
}

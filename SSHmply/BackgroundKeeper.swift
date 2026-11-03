import UIKit
import AVFoundation

/// Keeps the app (and therefore the SSH sockets) running while it is in the background / the phone is locked.
///
/// iOS has no official "keep this TCP connection open" mode, so, like other terminal apps, this combines:
///  1. a looping silent audio track under the `audio` background mode (stops iOS from suspending the app),
///  2. a UIKit background task as a safety net when the app is sent to the background,
/// while the terminal sessions add SSH keepalives and automatic reconnection on top.
@MainActor
final class BackgroundKeeper {
    static let shared = BackgroundKeeper()

    private var player: AVAudioPlayer?
    private var taskId: UIBackgroundTaskIdentifier = .invalid
    private(set) var isKeepingAlive = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            Task { @MainActor in self?.resumeIfNeeded() }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.player = nil
                self?.resumeIfNeeded()
            }
        })
        observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resumeIfNeeded() }
        })
    }

    /// Turns the keep-alive audio on or off (on while there are open sessions and the setting is enabled).
    func setActive(_ active: Bool) {
        guard active != isKeepingAlive else { return }
        isKeepingAlive = active
        if active { startAudio() } else { stopAudio() }
    }

    private func resumeIfNeeded() {
        guard isKeepingAlive else { return }
        if player?.isPlaying != true { startAudio() }
    }

    // MARK: Audio

    private func startAudio() {
        do {
            let session = AVAudioSession.sharedInstance()
            // mixWithOthers: never interrupts the user's music / podcasts.
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            if player == nil {
                let p = try AVAudioPlayer(data: Self.silentWav())
                p.numberOfLoops = -1
                p.volume = 1.0 // the data itself is silence
                p.prepareToPlay()
                player = p
            }
            player?.play()
        } catch {
            // Without audio the background task below still gives the connection some extra time.
        }
    }

    private func stopAudio() {
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// One second of 16-bit mono silence at 8 kHz, as an in-memory WAV file.
    static func silentWav(seconds: Int = 1, sampleRate: Int = 8000) -> Data {
        let samples = sampleRate * seconds
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!)
        u32(UInt32(36 + samples * 2))
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append("data".data(using: .ascii)!)
        u32(UInt32(samples * 2))
        d.append(Data(count: samples * 2))
        return d
    }

    // MARK: Background task (safety net)

    func beginTask() {
        guard taskId == .invalid else { return }
        taskId = UIApplication.shared.beginBackgroundTask(withName: "sshmply-keepalive") { [weak self] in
            Task { @MainActor in self?.endTask() }
        }
    }

    func endTask() {
        guard taskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taskId)
        taskId = .invalid
    }
}

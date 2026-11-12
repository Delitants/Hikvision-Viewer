import Foundation

public enum PlaybackEngineState { case opening, buffering, playing, paused, stopped, ended, failed }

public struct PlaybackRecovery {
    public enum Action: Equatable {
        case none
        case retry(elapsed: TimeInterval, attempt: Int, cacheMilliseconds: Int)
        case finished
    }
    public struct Update {
        public var progress: TimeInterval?
        public var resumed = false
        public var action: Action = .none
    }

    public private(set) var confirmedElapsed: TimeInterval = 0
    private let duration: TimeInterval?
    private var lastFrameAt: TimeInterval
    private var lastRetryAt = -Double.infinity
    private var stableSince: TimeInterval?
    private var previousPictures: Int?
    private var previousMediaTime: TimeInterval = 0
    private var frameClock: TimeInterval = 0
    private var attemptOffset: TimeInterval = 0
    private var sawFrame = false
    private var recovering = false
    private var wasPaused = false
    private var finished = false
    private var attempts = 0

    public init(now: TimeInterval, duration: TimeInterval?) {
        lastFrameAt = now
        self.duration = duration
    }

    public mutating func observe(now: TimeInterval, mediaTime: TimeInterval, pictures: Int?,
                                 state: PlaybackEngineState) -> Update {
        var update = Update()
        guard !finished else { return update }
        if state == .paused { wasPaused = true; return update }
        if wasPaused { lastFrameAt = now; stableSince = nil; wasPaused = false }

        let advanced: Bool
        if let pictures {
            advanced = pictures > (previousPictures ?? 0)
            previousPictures = pictures
        } else {
            advanced = state == .playing && mediaTime > previousMediaTime
        }
        previousMediaTime = mediaTime
        if advanced {
            if sawFrame && now - lastFrameAt <= 3 { frameClock += max(0, now - lastFrameAt) }
            if now - lastFrameAt > 5 { stableSince = nil }
            stableSince = stableSince ?? now
            lastFrameAt = now
            sawFrame = true
            // The playback clock can keep running over a frozen picture. Only commit
            // its time when a new video frame was actually displayed.
            confirmedElapsed = max(confirmedElapsed, attemptOffset + max(frameClock, mediaTime))
            if let duration { confirmedElapsed = min(confirmedElapsed, duration) }
            update.progress = confirmedElapsed
            if recovering { update.resumed = true; recovering = false }
            if now - (stableSince ?? now) >= 15 { attempts = 0 }
        }

        let nearEnd = duration.map { sawFrame && confirmedElapsed >= max(0, $0 - 2) } ?? false
        if (nearEnd && (state == .ended || state == .stopped || now - lastFrameAt >= 3)) ||
            (duration == nil && sawFrame && state == .ended) {
            finished = true
            update.action = .finished
            return update
        }

        let stale = now - lastFrameAt > (sawFrame ? 12 : 30)
        guard stale || state == .failed || state == .stopped || state == .ended else { return update }
        let backoff = min(30, pow(2, Double(min(attempts, 5))))
        guard now - lastRetryAt >= backoff else { return update }
        attempts += 1
        // Re-request the last confirmed second, preserving video around the stall.
        attemptOffset = floor(max(0, confirmedElapsed - 0.5))
        lastRetryAt = now
        lastFrameAt = now
        previousPictures = nil
        previousMediaTime = 0
        frameClock = 0
        stableSince = nil
        sawFrame = false
        recovering = true
        update.action = .retry(elapsed: attemptOffset, attempt: attempts,
                               cacheMilliseconds: min(10000, 3000 + attempts * 2000))
        return update
    }
}

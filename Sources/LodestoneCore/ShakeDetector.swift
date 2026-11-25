/// Recognizes a quick left-right shake of the pointer during a drag (the drop shelf's trigger).
///
/// Fed every dragged mouse event, so it only does arithmetic on a few stored values: no allocation.
/// A shake is `reversalsNeeded` changes of direction, each after at least `minTravel` points of
/// movement, with no more than `maxInterval` seconds between them.
public struct ShakeDetector: Sendable {
    public var minTravel: Double
    public var maxInterval: Double
    public var reversalsNeeded: Int

    /// +1 moving right, -1 moving left, 0 not decided yet.
    private var direction = 0
    /// Where the current stroke started (or the first point, before a direction is known).
    private var anchor = 0.0
    /// The furthest point reached in the current direction.
    private var extreme = 0.0
    private var started = false
    private var reversals = 0
    private var lastReversal = 0.0

    public init(minTravel: Double = 30, maxInterval: Double = 0.4, reversalsNeeded: Int = 3) {
        self.minTravel = minTravel
        self.maxInterval = maxInterval
        self.reversalsNeeded = reversalsNeeded
    }

    public mutating func reset() {
        direction = 0
        started = false
        reversals = 0
    }

    /// Adds a pointer position (`time` in seconds, any monotonic clock). Returns true when this point
    /// completes a shake; the detector then starts over.
    public mutating func add(x: Double, time: Double) -> Bool {
        guard started else {
            started = true
            anchor = x
            extreme = x
            return false
        }
        switch direction {
        case 0:
            if abs(x - anchor) >= minTravel {
                direction = x > anchor ? 1 : -1
                extreme = x
            }
            return false
        case 1 where x > extreme, -1 where x < extreme:
            extreme = x
            return false
        default:
            // Moving back. It's a reversal once it has come back far enough from the extreme.
            guard abs(extreme - x) >= minTravel else { return false }
            if reversals > 0 && time - lastReversal > maxInterval { reversals = 0 }
            reversals += 1
            lastReversal = time
            direction = -direction
            anchor = extreme
            extreme = x
            if reversals >= reversalsNeeded {
                reset()
                return true
            }
            return false
        }
    }
}

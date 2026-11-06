/// Numbers each pointer flight so a timer left over from an earlier flight cannot end, or move the label
/// of, a later one. A flight's hold timer, return timer and finish act only while its token is current.
public struct PointerFlightTokens: Sendable {
    private var latest = 0
    private var currentFlight: Int?
    private var flightAskedToReturn: Int?

    public init() {}

    /// Starts a flight; every earlier flight's token stops being current.
    public mutating func begin() -> Int {
        latest += 1
        currentFlight = latest
        return latest
    }

    public func isCurrent(_ token: Int) -> Bool {
        currentFlight == token
    }

    /// Ends the flight when `token` is the current one. False (and no change) for a stale token.
    public mutating func finish(_ token: Int) -> Bool {
        guard currentFlight == token else { return false }
        currentFlight = nil
        return true
    }

    /// Asks the current flight to end by flying back to the cursor now. Returns its token the first time
    /// only; nil when no flight is current or it was already asked.
    public mutating func requestReturnToCursor() -> Int? {
        guard let currentFlight, flightAskedToReturn != currentFlight else { return nil }
        flightAskedToReturn = currentFlight
        return currentFlight
    }

    /// Stop or quit: no flight is current, so every timer still waiting does nothing.
    public mutating func cancel() {
        currentFlight = nil
    }
}

/// Finite half-open loop interval in seconds. The session validates asset bounds.
public struct LoopRange: Equatable, Sendable {
    public let start: Double
    public let end: Double

    public init(start: Double, end: Double) throws {
        guard start.isFinite, end.isFinite, start >= 0, end > start else { throw CadenzaError.invalidLoopRange }
        self.start = start
        self.end = end
    }
}

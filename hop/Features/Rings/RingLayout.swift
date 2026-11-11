import Foundation

/// Where a ring's slices sit and which one the pointer aims at. Pure geometry, in points,
/// y up (screen coordinates).
nonisolated struct RingLayout: Equatable, Sendable {
    var center: CGPoint
    var count: Int
    var radius: Double
    var bubble: Double
    var deadZone: Double
    /// nil: a full ring, slice 0 at the top, going clockwise. Otherwise a fan of `arcSpread`
    /// radians around this direction (a group's children, pointing away from its parent).
    var facing: Double?
    var arcSpread = Double.pi

    init(center: CGPoint, count: Int, scale: Double, deadZone: Double, facing: Double? = nil, arcSpread: Double = Double.pi * 0.9) {
        self.center = center
        self.count = max(1, count)
        radius = 96 * scale
        bubble = 25 * scale
        self.deadZone = deadZone
        self.facing = facing
        self.arcSpread = arcSpread
        if facing != nil {
            // Far enough out that neighbours don't touch.
            radius = max(82 * scale, count > 1 ? bubble * 2.3 / step : 0)
        }
    }

    /// Angle between neighbours in a fan.
    var step: Double { count > 1 ? min(Double.pi / 5, arcSpread / Double(count - 1)) : Double.pi / 3 }

    /// Angle of slice `i`, radians, counter-clockwise from +x.
    func angle(_ i: Int) -> Double {
        if let facing {
            guard count > 1 else { return facing }
            return facing + step * (Double(count - 1) / 2 - Double(i))
        }
        return Double.pi / 2 - Double(i) * 2 * Double.pi / Double(count)
    }

    func position(_ i: Int) -> CGPoint {
        let a = angle(i)
        return CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius)
    }

    func distance(_ p: CGPoint) -> Double { hypot(p.x - center.x, p.y - center.y) }

    /// The slice the pointer aims at: nothing inside the dead zone, else the nearest direction.
    /// A fan only answers within its arc (plus half a step).
    func aimed(at p: CGPoint) -> Int? {
        guard distance(p) > deadZone else { return nil }
        let a = atan2(p.y - center.y, p.x - center.x)
        var best: (Int, Double)?
        for i in 0..<count {
            let d = Self.angularDistance(a, angle(i))
            if best == nil || d < best!.1 { best = (i, d) }
        }
        guard let best else { return nil }
        if facing != nil {
            if best.1 > step * 0.75 + 0.2 { return nil }
        }
        return best.0
    }

    /// The pointer has gone past the slice ring: a group under it opens its children.
    func isBeyond(_ p: CGPoint) -> Bool { distance(p) > radius + bubble * 1.1 }

    static func angularDistance(_ a: Double, _ b: Double) -> Double {
        var d = (a - b).truncatingRemainder(dividingBy: 2 * Double.pi)
        if d < 0 { d += 2 * Double.pi }
        return min(d, 2 * Double.pi - d)
    }
}

import AppKit
import Testing
@testable import hop

struct StatusItemTests {
    /// The menu bar bunny, a leaping silhouette: 1x and 2x, opaque body, see-through corners and eye.
    @Test func bunnyIsASilhouetteWithItsEyesCutOut() throws {
        let image = try #require(StatusItem.bunny())
        let reps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        #expect(reps.map(\.pixelsWide) == [18, 36])
        let rep = try #require(reps.last)
        func alpha(_ x: Int, _ y: Int) -> CGFloat { rep.colorAt(x: x, y: y)?.alphaComponent ?? 0 }
        #expect(alpha(0, 0) == 0)
        #expect(alpha(15, 20) > 0.9) // body
        #expect(alpha(25, 12) > 0.9) // head
        let eye = (26...30).flatMap { x in (8...12).map { alpha(x, $0) } }.min() ?? 1
        #expect(eye < 0.3)
        #expect(alpha(30, 30) == 0) // under the head
    }
}

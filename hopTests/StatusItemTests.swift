import AppKit
import Testing
@testable import hop

struct StatusItemTests {
    /// The menu bar bunny: 1x and 2x, opaque face, see-through corners and eyes.
    @Test func bunnyIsASilhouetteWithItsEyesCutOut() throws {
        let image = try #require(StatusItem.bunny())
        let reps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        #expect(reps.map(\.pixelsWide) == [18, 36])
        let rep = try #require(reps.last)
        func alpha(_ x: Int, _ y: Int) -> CGFloat { rep.colorAt(x: x, y: y)?.alphaComponent ?? 0 }
        #expect(alpha(0, 0) == 0)
        #expect(alpha(18, 18) > 0.9) // forehead
        let leftEye = (12...14).flatMap { x in (23...24).map { alpha(x, $0) } }.min() ?? 1
        #expect(leftEye < 0.3)
        #expect(min(alpha(18, 29), alpha(19, 29)) < 0.3) // nose
    }
}

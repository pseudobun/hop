import Foundation
import Testing
@testable import hop

struct CalculatorTests {
    static let posix = Locale(identifier: "en_US_POSIX")

    @Test(arguments: [
        ("2+2*3", "8"), ("(2+2)*3", "12"), ("10/4", "2.5"), ("2^10", "1024"), ("-2^2", "-4"),
        ("2^-1", "0.5"), ("2^3^2", "512"), ("200 + 10%", "220"), ("200 - 10%", "180"), ("50%", "0.5"),
        ("10% * 200", "20"), ("sqrt(16)", "4"), ("abs(-3.5)", "3.5"), ("1,5 + 1", "2.5"),
        ("3 × 4 ÷ 2", "6"), ("2 − 5", "-3"), ("ln(e)", "1"), ("log(1000)", "3"), ("sin(0)", "0"),
        ("0.1 + 0.2", "0.3"), ("pi * 2", "6.2831853072"),
    ])
    func evaluates(_ input: String, _ expected: String) throws {
        #expect(Calculator.format(try Calculator.evaluate(input), locale: Self.posix) == expected)
    }

    @Test(arguments: ["2+", "(1", "1)", "foo(2)", "2 2", "", "*"])
    func rejectsSyntax(_ input: String) {
        #expect(throws: Calculator.CalcError.self) { try Calculator.evaluate(input) }
    }

    @Test func divisionByZero() {
        #expect(throws: Calculator.CalcError.divisionByZero) { try Calculator.evaluate("1/0") }
    }

    @Test(arguments: ["safari", "2", "xcode", "visual studio code", "fix 2"])
    func plainTextIsNotAnExpression(_ input: String) {
        #expect(Calculator.evaluateIfExpression(input) == nil)
    }

    @Test func expressionDetected() {
        #expect(Calculator.evaluateIfExpression("2+2*3") == 8)
        #expect(Calculator.evaluateIfExpression("sqrt(2)") != nil)
    }

    @Test(arguments: [
        ("1280*1,2+15%", "1280 × 1.2 + 15%"), ("-2^2", "−2^2"), ("(1+2)*3", "(1 + 2) × 3"),
        ("10/4", "10 ÷ 4"), ("sqrt(16)", "sqrt(16)"), ("2 pi", "2 π"), ("3-1", "3 − 1"),
    ])
    func pretty(_ input: String, _ expected: String) {
        #expect(Calculator.pretty(input, locale: Self.posix) == expected)
    }
}

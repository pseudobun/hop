import Foundation

/// Small expression evaluator: `+ − × ÷ ^ %`, parentheses, functions, `pi`/`e`.
/// Integer powers stay exact in `Decimal`; transcendental functions go through `Double`.
nonisolated enum Calculator {
    enum CalcError: Error, Equatable { case syntax, divisionByZero, domain }

    /// Returns a result only for inputs that look like a calculation (an operator,
    /// function or parenthesis next to a number), so plain words never produce a row.
    static func evaluateIfExpression(_ input: String) -> Decimal? {
        let s = input.trimmingCharacters(in: .whitespaces)
        guard s.contains(where: \.isNumber) || s.lowercased().contains("pi") || s.contains("π") else { return nil }
        guard s.contains(where: { "+-−*×/÷^%()".contains($0) }) || functionNames.contains(where: { s.lowercased().contains($0 + "(") })
        else { return nil }
        return try? evaluate(s)
    }

    static func evaluate(_ input: String) throws -> Decimal {
        var parser = Parser(tokens: try tokenize(input))
        let node = try parser.expression(0)
        guard parser.isAtEnd else { throw CalcError.syntax }
        return try node.eval()
    }

    /// Plain string for the clipboard and the result row.
    static func format(_ value: Decimal, locale: Locale = .current) -> String {
        var v = value, rounded = Decimal()
        NSDecimalRound(&rounded, &v, 10, .plain)
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.maximumFractionDigits = 10
        f.minimumFractionDigits = 0
        return f.string(from: rounded as NSDecimalNumber) ?? "\(rounded)"
    }

    // MARK: - Tokens

    enum Token: Equatable { case number(Decimal), ident(String), op(Character), lparen, rparen }

    static let functionNames = ["sqrt", "sin", "cos", "tan", "log", "ln", "abs"]

    static func tokenize(_ input: String) throws -> [Token] {
        var tokens: [Token] = []
        let chars = Array(input)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch.isWhitespace { i += 1; continue }
            if ch.isNumber || ((ch == "." || ch == ",") && i + 1 < chars.count && chars[i + 1].isNumber) {
                var j = i, text = "", seenPoint = false
                while j < chars.count {
                    let c = chars[j]
                    if c.isNumber { text.append(c) }
                    else if (c == "." || c == ",") && !seenPoint { seenPoint = true; text.append(".") }
                    else { break }
                    j += 1
                }
                guard let d = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else { throw CalcError.syntax }
                tokens.append(.number(d))
                i = j
                continue
            }
            if ch.isLetter || ch == "π" {
                var j = i, text = ""
                while j < chars.count, chars[j].isLetter || chars[j] == "π" { text.append(chars[j]); j += 1 }
                tokens.append(.ident(text.lowercased()))
                i = j
                continue
            }
            switch ch {
            case "+": tokens.append(.op("+"))
            case "-", "−": tokens.append(.op("-"))
            case "*", "×": tokens.append(.op("*"))
            case "/", "÷": tokens.append(.op("/"))
            case "^": tokens.append(.op("^"))
            case "%": tokens.append(.op("%"))
            case "(": tokens.append(.lparen)
            case ")": tokens.append(.rparen)
            default: throw CalcError.syntax
            }
            i += 1
        }
        return tokens
    }

    // MARK: - AST

    indirect enum Node {
        case number(Decimal)
        case negate(Node)
        case percent(Node)
        case binary(Character, Node, Node)
        case call(String, Node)

        func eval() throws -> Decimal {
            switch self {
            case .number(let d): return d
            case .negate(let n): return -(try n.eval())
            case .percent(let n): return try n.eval() / 100
            case .binary(let op, let l, let r):
                let a = try l.eval()
                // `a ± b%` means a ± a·b/100.
                if op == "+" || op == "-", case .percent(let inner) = r {
                    let delta = a * (try inner.eval()) / 100
                    return op == "+" ? a + delta : a - delta
                }
                let b = try r.eval()
                switch op {
                case "+": return a + b
                case "-": return a - b
                case "*": return a * b
                case "/":
                    guard b != 0 else { throw CalcError.divisionByZero }
                    return a / b
                case "^": return try power(a, b)
                default: throw CalcError.syntax
                }
            case .call(let name, let arg):
                let x = try arg.eval()
                let d = NSDecimalNumber(decimal: x).doubleValue
                let result: Double
                switch name {
                case "sqrt":
                    guard d >= 0 else { throw CalcError.domain }
                    result = d.squareRoot()
                case "sin": result = sin(d)
                case "cos": result = cos(d)
                case "tan": result = tan(d)
                case "log":
                    guard d > 0 else { throw CalcError.domain }
                    result = log10(d)
                case "ln":
                    guard d > 0 else { throw CalcError.domain }
                    result = log(d)
                case "abs": return x < 0 ? -x : x
                default: throw CalcError.syntax
                }
                guard result.isFinite else { throw CalcError.domain }
                return roundedDecimal(result)
            }
        }
    }

    static func power(_ a: Decimal, _ b: Decimal) throws -> Decimal {
        var b = b, rounded = Decimal()
        NSDecimalRound(&rounded, &b, 0, .plain)
        if rounded == b, abs(NSDecimalNumber(decimal: b).doubleValue) <= 1000 {
            let n = NSDecimalNumber(decimal: b).intValue
            if n >= 0 { return pow(a, n) }
            let p = pow(a, -n)
            guard p != 0 else { throw CalcError.divisionByZero }
            return 1 / p
        }
        let r = Foundation.pow(NSDecimalNumber(decimal: a).doubleValue, NSDecimalNumber(decimal: b).doubleValue)
        guard r.isFinite else { throw CalcError.domain }
        return roundedDecimal(r)
    }

    static func roundedDecimal(_ d: Double) -> Decimal {
        var v = Decimal(string: String(format: "%.15g", d), locale: Locale(identifier: "en_US_POSIX")) ?? Decimal(d)
        var out = Decimal()
        NSDecimalRound(&out, &v, 12, .plain)
        return out
    }

    // MARK: - Pratt parser

    struct Parser {
        let tokens: [Token]
        var pos = 0
        var isAtEnd: Bool { pos >= tokens.count }

        mutating func next() -> Token? {
            guard pos < tokens.count else { return nil }
            defer { pos += 1 }
            return tokens[pos]
        }

        func peek() -> Token? { pos < tokens.count ? tokens[pos] : nil }

        static func infixPower(_ op: Character) -> (left: Int, right: Int)? {
            switch op {
            case "+", "-": (10, 11)
            case "*", "/": (20, 21)
            case "^": (41, 40) // right-associative, binds tighter than prefix minus
            default: nil
            }
        }

        mutating func expression(_ minPower: Int) throws -> Node {
            var lhs = try prefix()
            while let token = peek() {
                if case .op("%") = token {
                    guard 50 >= minPower else { break }
                    pos += 1
                    lhs = .percent(lhs)
                    continue
                }
                guard case .op(let op) = token, let p = Self.infixPower(op), p.left >= minPower else { break }
                pos += 1
                let rhs = try expression(p.right)
                lhs = .binary(op, lhs, rhs)
            }
            return lhs
        }

        mutating func prefix() throws -> Node {
            guard let token = next() else { throw CalcError.syntax }
            switch token {
            case .number(let d): return .number(d)
            case .op("-"): return .negate(try expression(30))
            case .op("+"): return try expression(30)
            case .lparen:
                let inner = try expression(0)
                guard case .rparen? = next() else { throw CalcError.syntax }
                return inner
            case .ident(let name):
                if name == "pi" || name == "π" { return .number(Decimal(string: "3.14159265358979323846264338327950288")!) }
                if name == "e" { return .number(Decimal(string: "2.71828182845904523536028747135266250")!) }
                guard Calculator.functionNames.contains(name), case .lparen? = next() else { throw CalcError.syntax }
                let arg = try expression(0)
                guard case .rparen? = next() else { throw CalcError.syntax }
                return .call(name, arg)
            default:
                throw CalcError.syntax
            }
        }
    }
}

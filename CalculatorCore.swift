import Foundation

// The calculator never calls the network. Decimal keeps ordinary decimal arithmetic exact.
struct ScientificEngine {
    var entry = "0"
    var expression = ""
    var degrees = true
    var memory = Decimal.zero
    var hasMemory = false
    private var accumulator: Decimal?
    private var operation: String?
    private var repeatedOperation: String?
    private var repeatedOperand: Decimal?
    private var newEntry = true
    private var failed = false
    private static let maximum = Decimal(string: "79228162514264337593543950335")!

    var value: Decimal { Decimal(string: entry, locale: Locale(identifier: "en_US_POSIX")) ?? 0 }
    var display: String {
        if failed { return entry }
        if entry.count <= 18 { return entry }
        return String(format: "%.12g", NSDecimalNumber(decimal: value).doubleValue)
    }
    mutating func clear() {
        entry = "0"; expression = ""; accumulator = nil; operation = nil
        repeatedOperation = nil; repeatedOperand = nil; newEntry = true; failed = false
    }
    private mutating func error(_ message: String) {
        clear(); entry = message; failed = true
    }
    private mutating func set(_ result: Decimal) {
        guard !result.isNaN, abs(result) <= Self.maximum else { error("범위 초과"); return }
        entry = NSDecimalNumber(decimal: result).stringValue; newEntry = true; failed = false
    }
    private mutating func setDouble(_ result: Double) {
        guard result.isFinite, result == 0 || abs(result) >= 1e-28,
              abs(result) <= NSDecimalNumber(decimal: Self.maximum).doubleValue,
              let decimal = Decimal(string: String(format: "%.16g", result), locale: Locale(identifier: "en_US_POSIX")) else {
            error("범위 초과"); return
        }
        set(decimal)
    }
    private static func calculate(_ left: Decimal, _ op: String, _ right: Decimal) -> Decimal? {
        var l = left, r = right, result = Decimal.zero
        let status: Decimal.CalculationError
        switch op {
        case "+": status = NSDecimalAdd(&result, &l, &r, .plain)
        case "−": status = NSDecimalSubtract(&result, &l, &r, .plain)
        case "×": status = NSDecimalMultiply(&result, &l, &r, .plain)
        case "÷":
            if r == 0 { return nil }
            status = NSDecimalDivide(&result, &l, &r, .plain)
        case "mod":
            if r == 0 { return nil }
            var quotient = l / r, truncated = Decimal.zero
            // Remainder has the dividend's sign (truncation toward zero).
            NSDecimalRound(&truncated, &quotient, 0, quotient < 0 ? .up : .down)
            result = l - truncated * r; status = .noError
        case "xʸ":
            let d = pow(NSDecimalNumber(decimal: l).doubleValue, NSDecimalNumber(decimal: r).doubleValue)
            guard d.isFinite, d == 0 || abs(d) >= 1e-28,
                  let converted = Decimal(string: String(format: "%.16g", d)) else { return nil }
            result = converted; status = .noError
        default: return nil
        }
        guard status == .noError || status == .lossOfPrecision,
              !result.isNaN, abs(result) <= maximum else { return nil }
        return result
    }
    mutating func press(_ key: String) {
        if key == "C" { clear(); return }
        if key == "DEG" { degrees.toggle(); return }
        if key.count == 1, key.first!.isNumber {
            if newEntry || failed { entry = "0"; newEntry = false; failed = false }
            if entry.filter({ $0.isNumber }).count < 18 {
                entry = entry == "0" ? key : entry + key
            }
            return
        }
        if key == "." {
            if newEntry || failed { entry = "0"; newEntry = false; failed = false }
            if !entry.contains(".") { entry += "." }; return
        }
        if key == "CE" { entry = "0"; newEntry = true; failed = false; return }
        if failed { return }
        switch key {
        case "⌫":
            if !newEntry { entry.removeLast(); if entry.isEmpty || entry == "-" { entry = "0" } }
        case "±": if value != 0 { entry = entry.hasPrefix("-") ? String(entry.dropFirst()) : "-" + entry }
        case "MC": memory = 0; hasMemory = false
        case "MR", "M⌄": set(memory)
        case "MS": memory = value; hasMemory = true; newEntry = true
        case "M+", "M−":
            guard let next = Self.calculate(memory, key == "M+" ? "+" : "−", value) else { error("범위 초과"); return }
            memory = next; hasMemory = true; newEntry = true
        case "+", "−", "×", "÷", "mod", "xʸ":
            if let op = operation, let left = accumulator, !newEntry {
                guard let result = Self.calculate(left, op, value) else { error("계산할 수 없음"); return }
                set(result)
            }
            accumulator = value; operation = key; expression = "\(display) \(key)"; newEntry = true
            repeatedOperation = nil; repeatedOperand = nil
        case "=":
            let op = operation ?? repeatedOperation
            let left = operation != nil ? (accumulator ?? value) : value
            let right = operation != nil ? value : (repeatedOperand ?? value)
            if let op {
                guard let result = Self.calculate(left, op, right) else { error("계산할 수 없음"); return }
                expression = "\(NSDecimalNumber(decimal: left).stringValue) \(op) \(NSDecimalNumber(decimal: right).stringValue) ="
                set(result); repeatedOperation = op; repeatedOperand = right; operation = nil; accumulator = nil
            } else { expression = "\(display) ="; newEntry = true }
        case "%":
            if let op = operation, (op == "+" || op == "−"), let left = accumulator { set(left * value / 100) }
            else { set(value / 100) }
        case "π": setDouble(Double.pi)
        case "e": setDouble(M_E)
        default: unary(key)
        }
    }
    private mutating func unary(_ key: String) {
        let v = value, d = NSDecimalNumber(decimal: v).doubleValue
        switch key {
        case "x²", "x³":
            guard let square = Self.calculate(v, "×", v),
                  let answer = key == "x²" ? square : Self.calculate(square, "×", v) else { error("범위 초과"); return }
            set(answer)
        case "√x": if v < 0 { error("잘못된 입력") } else { setDouble(sqrt(d)) }
        case "1/x": if v == 0 { error("0으로 나눌 수 없음") } else { set(1 / v) }
        case "|x|": set(abs(v))
        case "⌊x⌋", "⌈x⌉":
            var input = v, rounded = Decimal.zero
            NSDecimalRound(&rounded, &input, 0, key == "⌊x⌋" ? .down : .up); set(rounded)
        case "n!":
            guard d >= 0, d <= 27, d.rounded(.towardZero) == d else { error("잘못된 입력"); return }
            var result = Decimal(1)
            if d >= 2 { for n in 2...Int(d) { result *= Decimal(n) } }; set(result)
        case "log", "ln":
            if d <= 0 { error("잘못된 입력") } else { setDouble(key == "ln" ? log(d) : log10(d)) }
        case "10ˣ": setDouble(pow(10, d))
        case "eˣ": setDouble(exp(d))
        case "sin", "cos", "tan":
            let angle = degrees ? d * Double.pi / 180 : d
            if key == "tan", abs(cos(angle)) < 1e-14 { error("정의되지 않음"); return }
            var result = key == "sin" ? sin(angle) : (key == "cos" ? cos(angle) : tan(angle))
            if degrees, d.truncatingRemainder(dividingBy: 90) == 0, abs(result) < 1e-14 { result = 0 }
            setDouble(result)
        default: break
        }
    }
}

enum CalculatorKeys {
    static let rows = [
        ["sin", "cos", "tan", "log", "ln"], ["π", "e", "x²", "√x", "1/x"],
        ["xʸ", "10ˣ", "eˣ", "n!", "|x|"], ["mod", "CE", "C", "⌫", "÷"],
        ["7", "8", "9", "x³", "×"], ["4", "5", "6", "⌊x⌋", "−"],
        ["1", "2", "3", "⌈x⌉", "+"], ["±", "0", ".", "%", "="]
    ]
    static let secret = ["ln", "n!", "mod", "ln"]
}

struct HiddenSequence {
    private(set) var index = 0
    private var began = TimeInterval.zero
    mutating func accept(_ key: String, now: TimeInterval) -> Bool {
        if index > 0, now - began > 4 { index = 0 }
        if key == CalculatorKeys.secret[index] {
            if index == 0 { began = now }; index += 1
            if index == CalculatorKeys.secret.count { index = 0; return true }
        } else { index = key == CalculatorKeys.secret[0] ? 1 : 0; began = now }
        return false
    }
    mutating func reset() { index = 0 }
}

enum AnswerPages {
    // Newlines inside matrices/cases belong to the same expression.
    static func split(_ answer: String) -> [String] {
        let normalized = answer.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        var pages: [String] = [], buffer = "", depth = 0, displayMath = false
        for line in normalized.components(separatedBy: "\n") {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine == "\\[" || (trimmedLine == "$$" && !displayMath) { displayMath = true }
            else if trimmedLine == "\\]" || (trimmedLine == "$$" && displayMath) { displayMath = false }
            depth += line.components(separatedBy: "\\begin{").count - 1
            depth -= line.components(separatedBy: "\\end{").count - 1
            buffer += buffer.isEmpty ? line : "\n" + line
            if depth <= 0 && !displayMath {
                let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, trimmed != "$$", trimmed != "\\[", trimmed != "\\]" { pages.append(trimmed) }
                buffer = ""; depth = 0
            }
        }
        if !buffer.isEmpty { pages.append(buffer) }
        return pages
    }
}

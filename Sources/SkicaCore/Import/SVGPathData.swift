import CoreGraphics
import Foundation

/// The `d` attribute of SVG paths (all commands, arcs included) as a Core Graphics path.
enum SVGPathData {
    static func path(_ data: String) -> CGMutablePath {
        var scanner = NumberScanner(data)
        let path = CGMutablePath()
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint?
        var lastCommand: Character = " "
        var command: Character?

        while let next = scanner.nextCommand(default: command) {
            command = next
            let relative = next.isLowercase
            let base = relative ? current : .zero
            func point() -> CGPoint? {
                guard let x = scanner.number(), let y = scanner.number() else { return nil }
                return CGPoint(x: base.x + x, y: base.y + y)
            }
            var control: CGPoint?
            switch next.uppercased().first! {
            case "M":
                guard let target = point() else { return path }
                path.move(to: target)
                current = target
                start = target
                // Coordinates after a moveto are implicit linetos.
                command = relative ? "l" : "L"
            case "L":
                guard let target = point() else { return path }
                addLine(path, to: target)
                current = target
            case "H":
                guard let x = scanner.number() else { return path }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                addLine(path, to: current)
            case "V":
                guard let y = scanner.number() else { return path }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                addLine(path, to: current)
            case "C":
                guard let c1 = point(), let c2 = point(), let target = point() else { return path }
                addCurve(path, to: target, c1, c2, from: current)
                control = c2
                current = target
            case "S":
                let c1 = reflected(lastControl, around: current, if: "CS".contains(lastCommand.uppercased()))
                guard let c2 = point(), let target = point() else { return path }
                addCurve(path, to: target, c1, c2, from: current)
                control = c2
                current = target
            case "Q":
                guard let c = point(), let target = point() else { return path }
                addQuad(path, to: target, c, from: current)
                control = c
                current = target
            case "T":
                let c = reflected(lastControl, around: current, if: "QT".contains(lastCommand.uppercased()))
                guard let target = point() else { return path }
                addQuad(path, to: target, c, from: current)
                control = c
                current = target
            case "A":
                guard let rx = scanner.number(), let ry = scanner.number(), let angle = scanner.number(),
                      let large = scanner.flag(), let sweep = scanner.flag(), let target = point() else { return path }
                if path.isEmpty { path.move(to: current) }
                addArc(path, from: current, to: target, rx: rx, ry: ry, angle: angle, large: large, sweep: sweep)
                current = target
            case "Z":
                if !path.isEmpty { path.closeSubpath() }
                current = start
                command = nil
            default:
                return path
            }
            lastControl = control
            lastCommand = next
        }
        return path
    }

    private static func addLine(_ path: CGMutablePath, to point: CGPoint) {
        if path.isEmpty { path.move(to: point) } else { path.addLine(to: point) }
    }

    private static func addCurve(_ path: CGMutablePath, to point: CGPoint, _ c1: CGPoint, _ c2: CGPoint, from current: CGPoint) {
        if path.isEmpty { path.move(to: current) }
        path.addCurve(to: point, control1: c1, control2: c2)
    }

    private static func addQuad(_ path: CGMutablePath, to point: CGPoint, _ control: CGPoint, from current: CGPoint) {
        if path.isEmpty { path.move(to: current) }
        path.addQuadCurve(to: point, control: control)
    }

    private static func reflected(_ control: CGPoint?, around point: CGPoint, if follows: Bool) -> CGPoint {
        guard follows, let control else { return point }
        return CGPoint(x: 2 * point.x - control.x, y: 2 * point.y - control.y)
    }

    /// An elliptical arc as cubic curves (SVG implementation notes, F.6).
    static func addArc(_ path: CGMutablePath, from p1: CGPoint, to p2: CGPoint, rx: Double, ry: Double, angle: Double, large: Bool, sweep: Bool) {
        var rx = abs(rx)
        var ry = abs(ry)
        guard rx > 0, ry > 0, p1 != p2 else { return path.addLine(to: p2) }
        let phi = angle * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)
        let dx = (p1.x - p2.x) / 2
        let dy = (p1.y - p2.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy
        let y1 = -sinPhi * dx + cosPhi * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 {
            rx *= lambda.squareRoot()
            ry *= lambda.squareRoot()
        }
        let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var factor = denominator == 0 ? 0 : max(numerator / denominator, 0).squareRoot()
        if large == sweep { factor = -factor }
        let cx1 = factor * rx * y1 / ry
        let cy1 = -factor * ry * x1 / rx
        let center = CGPoint(x: cosPhi * cx1 - sinPhi * cy1 + (p1.x + p2.x) / 2, y: sinPhi * cx1 + cosPhi * cy1 + (p1.y + p2.y) / 2)

        func angleBetween(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let sign: Double = ux * vy - uy * vx < 0 ? -1 : 1
            let dot = (ux * vx + uy * vy) / ((ux * ux + uy * uy).squareRoot() * (vx * vx + vy * vy).squareRoot())
            return sign * acos(max(-1, min(1, dot)))
        }
        let theta1 = angleBetween(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angleBetween((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }

        let segments = max(Int(ceil(abs(delta) / (.pi / 2))), 1)
        let step = delta / Double(segments)
        let k = 4.0 / 3.0 * tan(step / 4)
        func point(_ t: Double) -> CGPoint {
            CGPoint(x: center.x + rx * cos(t) * cosPhi - ry * sin(t) * sinPhi, y: center.y + rx * cos(t) * sinPhi + ry * sin(t) * cosPhi)
        }
        func derivative(_ t: Double) -> CGPoint {
            CGPoint(x: -rx * sin(t) * cosPhi - ry * cos(t) * sinPhi, y: -rx * sin(t) * sinPhi + ry * cos(t) * cosPhi)
        }
        var t = theta1
        for index in 0..<segments {
            let next = t + step
            let start = point(t)
            let end = index == segments - 1 ? p2 : point(next)
            let d1 = derivative(t)
            let d2 = derivative(next)
            path.addCurve(to: end, control1: CGPoint(x: start.x + k * d1.x, y: start.y + k * d1.y),
                          control2: CGPoint(x: end.x - k * d2.x, y: end.y - k * d2.y))
            t = next
        }
    }
}

/// Reads SVG numbers, which may run together (`1.5.5`, `10-5`, `1e-3`), and arc flags (`0`/`1`,
/// possibly without separators).
struct NumberScanner {
    private let characters: [Character]
    private var index = 0

    init(_ text: String) {
        characters = Array(text)
    }

    /// The next command letter, or `fallback` when numbers follow (implicit repetition).
    mutating func nextCommand(default fallback: Character?) -> Character? {
        skipSeparators()
        guard index < characters.count else { return nil }
        let character = characters[index]
        if character.isLetter, character != "e", character != "E" {
            index += 1
            return character
        }
        return fallback
    }

    mutating func number() -> Double? {
        skipSeparators()
        let start = index
        if index < characters.count, characters[index] == "-" || characters[index] == "+" { index += 1 }
        var seenDot = false
        var seenDigit = false
        while index < characters.count {
            let character = characters[index]
            if character.isNumber {
                seenDigit = true
            } else if character == ".", !seenDot {
                seenDot = true
            } else if (character == "e" || character == "E"), seenDigit {
                index += 1
                if index < characters.count, characters[index] == "-" || characters[index] == "+" { index += 1 }
                continue
            } else {
                break
            }
            index += 1
        }
        guard seenDigit else {
            index = start
            return nil
        }
        return Double(String(characters[start..<index]))
    }

    mutating func flag() -> Bool? {
        skipSeparators()
        guard index < characters.count, characters[index] == "0" || characters[index] == "1" else { return nil }
        defer { index += 1 }
        return characters[index] == "1"
    }

    /// Numbers of a list like `points="0,0 10 20"` or `stroke-dasharray`.
    static func numbers(in text: String) -> [Double] {
        var scanner = NumberScanner(text)
        var values: [Double] = []
        while let value = scanner.number() { values.append(value) }
        return values
    }

    private mutating func skipSeparators() {
        while index < characters.count, characters[index].isWhitespace || characters[index] == "," { index += 1 }
    }
}

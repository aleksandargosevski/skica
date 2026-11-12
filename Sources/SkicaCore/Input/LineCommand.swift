import Foundation

/// One command typed after `:`, e.g. `w 200`, `fill #ff6600`, `font Inter 16 600`.
/// Number arguments are kept as text and evaluated per layer, so `w +20` adds to each width.
public enum LineCommand: Equatable, Sendable {
    case x(String), y(String), width(String), height(String)
    /// `size 200x120 @ 40,80` or `size iphone`, as in the size prompt.
    case geometry(String)
    case rotation(String), opacity(String), radius(String)
    case fill(Color?)
    case border(width: Double?, color: Color?, position: Border.Position?)
    case removeBorders
    case shadow(Shadow?)
    case blur(Double?)
    case blend(BlendMode)
    case name(String)
    case font(family: String?, size: Double?, weight: Int?)
    case fontSize(String)
    case textColor(Color)
    case align(AlignEdge)
    /// Even spacing, or exactly `spacing` apart.
    case distribute(horizontally: Bool, spacing: Double?)
    /// Applies the shared style with this name.
    case sharedStyle(String)
    case stack(StackLayout?)
    case gap(Double)
    case padding(Insets)
    /// New constraints for one or both axes (nil leaves an axis as it is).
    case pin(horizontal: Constraints.Pin?, vertical: Constraints.Pin?)
    case visible(Bool)
    case locked(Bool)
    case action(CommandID)

    /// Verbs for completion and help, with what they take.
    public static let reference: [(verb: String, usage: String)] = [
        ("x", "x 100, x +20"), ("y", "y 40"), ("w", "w 200, w *2"), ("h", "h 120"),
        ("size", "size 200x120 @ 40,80, size iphone"), ("r", "r 8 (corner radius)"), ("rot", "rot 45"), ("op", "op 50"),
        ("fill", "fill #ff6600, fill none"), ("border", "border 2 #000 inside, border none"),
        ("shadow", "shadow 0 4 12 #0003, shadow none"), ("blur", "blur 8, blur none"), ("blend", "blend multiply"),
        ("name", "name Header"), ("font", "font Inter 16 600"), ("fs", "fs 18"), ("color", "color #333"),
        ("align", "align left|center|right|top|middle|bottom"), ("distribute", "distribute h|v [gap]"),
        ("style", "style Primary Button"), ("stack", "stack h 8 16 center, stack off"), ("gap", "gap 12"), ("pad", "pad 8 16"),
        ("pin", "pin left right top, pin hcenter, pin vscale"), ("hide", "hide, show"), ("lock", "lock, unlock"), ("group", "group, ungroup"),
        ("bool", "bool union|subtract|intersect|difference"), ("mask", "mask"), ("flatten", "flatten (to paths)"),
        ("outline", "outline (border to shape)"), ("duplicate", "duplicate"), ("delete", "delete"), ("front", "front, back, forward, backward"),
    ]
}

public enum LineCommandParser {
    /// Parses commands separated by `;`. Colors can name swatches of `assets` as `$name`.
    public static func parse(_ text: String, assets: DocumentAssets = DocumentAssets()) throws -> [LineCommand] {
        let parts = text.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { throw InputError.invalid("Type a command, e.g. w 200 or fill #ff6600.") }
        return try parts.map { try parseOne($0, assets: assets) }
    }

    private static func parseOne(_ text: String, assets: DocumentAssets) throws -> LineCommand {
        func color(_ text: String) throws -> Color { try self.color(text, assets: assets) }
        var words = text.split(separator: " ").map(String.init)
        let verb = words.removeFirst().lowercased()
        let rest = words.joined(separator: " ")
        func value() throws -> String {
            guard !rest.isEmpty else { throw InputError.invalid("\(verb) needs a value.") }
            return rest
        }

        switch verb {
        case "x": return .x(try value())
        case "y": return .y(try value())
        case "w", "width": return .width(try value())
        case "h", "height": return .height(try value())
        case "size", "pos", "frame": return .geometry(verb == "pos" ? "@ " + (try value()) : try value())
        case "r", "radius": return .radius(try value())
        case "rot", "rotate", "rotation": return .rotation(try value())
        case "op", "opacity", "alpha": return .opacity(try value())
        case "fill", "bg":
            if rest.lowercased() == "none" { return .fill(nil) }
            return .fill(try color(try value()))
        case "border", "stroke":
            if rest.lowercased() == "none" { return .removeBorders }
            return try border(words, assets: assets)
        case "shadow":
            if rest.lowercased() == "none" { return .shadow(nil) }
            return try shadow(words, assets: assets)
        case "blur":
            if rest.lowercased() == "none" || rest == "0" { return .blur(nil) }
            return .blur(try number(try value()))
        case "blend":
            let wanted = rest.lowercased().filter { !$0.isWhitespace }
            guard let mode = BlendMode.allCases.first(where: { $0.rawValue.lowercased() == wanted || $0.title.lowercased().filter({ !$0.isWhitespace }) == wanted }) else {
                throw InputError.invalid("Unknown blend mode \"\(rest)\".")
            }
            return .blend(mode)
        case "name", "rename": return .name(try value())
        case "style": return .sharedStyle(try value())
        case "stack": return try stack(words)
        case "gap", "spacing": return .gap(try number(try value()))
        case "pad", "padding":
            guard let insets = Insets(parsing: rest) else { throw InputError.invalid("Use pad 8, pad 8 16 or pad 8 16 8 16.") }
            return .padding(insets)
        case "pin", "constraints": return try pin(words)
        case "font": return try font(words)
        case "fs", "fontsize": return .fontSize(try value())
        case "color", "textcolor": return .textColor(try color(try value()))
        case "align": return .align(try alignEdge(try value()))
        case "distribute", "dist":
            let usage = InputError.invalid("Use distribute h or distribute v, with a gap for exact spacing (distribute h 16).")
            guard let axis = words.first?.lowercased() else { throw usage }
            let spacing = try words.dropFirst().first.map { try number($0) }
            switch axis {
            case "h", "horizontal", "horizontally": return .distribute(horizontally: true, spacing: spacing)
            case "v", "vertical", "vertically": return .distribute(horizontally: false, spacing: spacing)
            default: throw usage
            }
        case "hide": return .visible(false)
        case "show": return .visible(true)
        case "lock": return .locked(true)
        case "unlock": return .locked(false)
        case "group": return .action(.group)
        case "ungroup": return .action(.ungroup)
        case "duplicate", "dup": return .action(.duplicate)
        case "delete", "del", "rm": return .action(.delete)
        case "bool", "boolean":
            switch rest.lowercased() {
            case "union", "add": return .action(.booleanUnion)
            case "subtract", "minus": return .action(.booleanSubtract)
            case "intersect": return .action(.booleanIntersect)
            case "difference", "xor": return .action(.booleanDifference)
            default: throw InputError.invalid("Use bool union, subtract, intersect or difference.")
            }
        case "mask": return .action(.toggleMask)
        case "outline": return .action(.outlineStroke)
        case "flatten", "paths": return .action(.convertToPaths)
        case "front": return .action(.bringToFront)
        case "back": return .action(.sendToBack)
        case "forward": return .action(.bringForward)
        case "backward": return .action(.sendBackward)
        default:
            throw InputError.invalid("Unknown command \"\(verb)\".")
        }
    }

    static func color(_ text: String, assets: DocumentAssets = DocumentAssets()) throws -> Color {
        if text.hasPrefix("$") {
            guard let swatch = assets.swatch(named: String(text.dropFirst())) else {
                throw InputError.invalid("No color named \"\(text.dropFirst())\" in the palette.")
            }
            return swatch.color
        }
        switch text.lowercased() {
        case "white": return .white
        case "black": return .black
        case "clear", "transparent": return Color(red: 0, green: 0, blue: 0, alpha: 0)
        default:
            guard let color = Color(hex: text) else { throw InputError.invalid("\"\(text)\" is not a color; use #rrggbb.") }
            return color
        }
    }

    private static func number(_ text: String) throws -> Double {
        guard let value = Double(text.replacingOccurrences(of: ",", with: ".")) else {
            throw InputError.invalid("\"\(text)\" is not a number.")
        }
        return value
    }

    private static func border(_ words: [String], assets: DocumentAssets) throws -> LineCommand {
        var width: Double?
        var color: Color?
        var position: Border.Position?
        for word in words {
            if let value = Double(word) {
                width = value
            } else if let named = Border.Position(rawValue: word.lowercased()) {
                position = named
            } else {
                color = try self.color(word, assets: assets)
            }
        }
        return .border(width: width, color: color, position: position)
    }

    private static func shadow(_ words: [String], assets: DocumentAssets) throws -> LineCommand {
        var numbers: [Double] = []
        var shadow = Shadow()
        for word in words {
            if let value = Double(word) { numbers.append(value) } else { shadow.color = try color(word, assets: assets) }
        }
        guard numbers.count <= 4 else { throw InputError.invalid("Use shadow x y blur [spread] [#color].") }
        if numbers.count > 0 { shadow.x = numbers[0] }
        if numbers.count > 1 { shadow.y = numbers[1] }
        if numbers.count > 2 { shadow.blur = numbers[2] }
        if numbers.count > 3 { shadow.spread = numbers[3] }
        return .shadow(shadow)
    }

    /// `font Inter`, `font Inter 16`, `font Inter 16 600`, `font 18`, `font bold`.
    private static func font(_ words: [String]) throws -> LineCommand {
        let weightNames: [String: Int] = ["thin": 100, "light": 300, "regular": 400, "medium": 500, "semibold": 600, "bold": 700, "black": 900]
        var family: [String] = []
        var numbers: [Double] = []
        var weight: Int?
        for word in words {
            if let value = Double(word) {
                numbers.append(value)
            } else if let named = weightNames[word.lowercased()] {
                weight = named
            } else {
                family.append(word)
            }
        }
        let size = numbers.first
        if numbers.count > 1 { weight = Int(numbers[1]) }
        guard !family.isEmpty || size != nil || weight != nil else { throw InputError.invalid("Use font Family [size] [weight].") }
        return .font(family: family.isEmpty ? nil : family.joined(separator: " "), size: size, weight: weight)
    }

    /// `stack h`, `stack v 12`, `stack h 8 16 center`, `stack h 8 4 12 fixed`, `stack off`.
    private static func stack(_ words: [String]) throws -> LineCommand {
        if words.first?.lowercased() == "off" || words.first?.lowercased() == "none" { return .stack(nil) }
        var stack = StackLayout()
        var numbers: [Double] = []
        for word in words.map({ $0.lowercased() }) {
            switch word {
            case "h", "horizontal", "row": stack.direction = .horizontal
            case "v", "vertical", "column": stack.direction = .vertical
            case "start", "top", "left": stack.alignment = .start
            case "center", "middle": stack.alignment = .center
            case "end", "bottom", "right": stack.alignment = .end
            case "fixed": stack.hugsContents = false
            case "hug": stack.hugsContents = true
            default:
                guard let value = Double(word) else { throw InputError.invalid("Use stack h|v [gap] [padding] [start|center|end] [hug|fixed].") }
                numbers.append(value)
            }
        }
        if let gap = numbers.first { stack.spacing = gap }
        if numbers.count > 1, let insets = Insets(parsing: numbers.dropFirst().map { String($0) }.joined(separator: " ")) {
            stack.padding = insets
        }
        return .stack(stack)
    }

    /// `pin left right` stretches, `pin right` sticks to the right, `pin hcenter`, `pin vscale`…
    private static func pin(_ words: [String]) throws -> LineCommand {
        let set = Set(words.map { $0.lowercased() })
        guard !set.isEmpty else { throw InputError.invalid("Use pin left|right|top|bottom|hcenter|vcenter|hscale|vscale.") }
        let known: Set<String> = ["left", "right", "top", "bottom", "hcenter", "vcenter", "hscale", "vscale"]
        if let unknown = set.subtracting(known).first { throw InputError.invalid("Unknown pin \"\(unknown)\".") }
        func axis(_ start: String, _ end: String, _ center: String, _ scale: String) -> Constraints.Pin? {
            if set.contains(scale) { return .scale }
            if set.contains(center) { return .center }
            switch (set.contains(start), set.contains(end)) {
            case (true, true): return .both
            case (true, false): return .start
            case (false, true): return .end
            default: return nil
            }
        }
        return .pin(horizontal: axis("left", "right", "hcenter", "hscale"), vertical: axis("top", "bottom", "vcenter", "vscale"))
    }

    private static func alignEdge(_ text: String) throws -> AlignEdge {
        switch text.lowercased() {
        case "left", "l": return .left
        case "center", "hcenter", "c": return .horizontalCenter
        case "right", "r": return .right
        case "top", "t": return .top
        case "middle", "vcenter", "m": return .verticalCenter
        case "bottom", "b": return .bottom
        default: throw InputError.invalid("Use align left, center, right, top, middle or bottom.")
        }
    }
}

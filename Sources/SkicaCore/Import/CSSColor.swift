import Foundation

/// CSS color values: `#rgb`, `#rrggbb`, `#rrggbbaa`, `rgb()`, `rgba()`, `hsl()` and named colors.
enum CSSColor {
    static func parse(_ text: String) -> Color? {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        if value.hasPrefix("#") { return hex(String(value.dropFirst())) }
        if value.hasPrefix("rgb") { return rgb(value) }
        if value.hasPrefix("hsl") { return hsl(value) }
        if value == "transparent" { return Color(red: 0, green: 0, blue: 0, alpha: 0) }
        return named[value].flatMap { hex($0) }
    }

    private static func hex(_ digits: String) -> Color? {
        let expanded = digits.count == 3 || digits.count == 4 ? digits.map { "\($0)\($0)" }.joined() : digits
        return Color(hex: "#" + expanded)
    }

    private static func arguments(_ value: String) -> [String] {
        guard let open = value.firstIndex(of: "("), let close = value.lastIndex(of: ")"), open < close else { return [] }
        return value[value.index(after: open)..<close]
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
            .map(String.init)
    }

    private static func rgb(_ value: String) -> Color? {
        let parts = arguments(value)
        guard parts.count >= 3 else { return nil }
        let channels = parts.prefix(3).map { part -> Double in
            part.hasSuffix("%") ? (Double(part.dropLast()) ?? 0) * 2.55 : Double(part) ?? 0
        }
        return Color(red: byte(channels[0]), green: byte(channels[1]), blue: byte(channels[2]),
                     alpha: byte(alpha(parts.count > 3 ? parts[3] : nil) * 255))
    }

    private static func hsl(_ value: String) -> Color? {
        let parts = arguments(value)
        guard parts.count >= 3 else { return nil }
        let hue = (Double(parts[0].replacingOccurrences(of: "deg", with: "")) ?? 0) / 360
        let saturation = (Double(parts[1].replacingOccurrences(of: "%", with: "")) ?? 0) / 100
        let lightness = (Double(parts[2].replacingOccurrences(of: "%", with: "")) ?? 0) / 100
        let q = lightness < 0.5 ? lightness * (1 + saturation) : lightness + saturation - lightness * saturation
        let p = 2 * lightness - q
        func channel(_ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        return Color(red: byte(channel(hue + 1 / 3) * 255), green: byte(channel(hue) * 255), blue: byte(channel(hue - 1 / 3) * 255),
                     alpha: byte(alpha(parts.count > 3 ? parts[3] : nil) * 255))
    }

    private static func alpha(_ text: String?) -> Double {
        guard let text else { return 1 }
        if text.hasSuffix("%") { return (Double(text.dropLast()) ?? 100) / 100 }
        return Double(text) ?? 1
    }

    private static func byte(_ value: Double) -> UInt8 {
        UInt8(max(0, min(255, value.rounded())))
    }

    private static let named: [String: String] = {
        let table = """
        aliceblue f0f8ff antiquewhite faebd7 aqua 00ffff aquamarine 7fffd4 azure f0ffff beige f5f5dc bisque ffe4c4 black 000000 \
        blanchedalmond ffebcd blue 0000ff blueviolet 8a2be2 brown a52a2a burlywood deb887 cadetblue 5f9ea0 chartreuse 7fff00 \
        chocolate d2691e coral ff7f50 cornflowerblue 6495ed cornsilk fff8dc crimson dc143c cyan 00ffff darkblue 00008b \
        darkcyan 008b8b darkgoldenrod b8860b darkgray a9a9a9 darkgreen 006400 darkgrey a9a9a9 darkkhaki bdb76b darkmagenta 8b008b \
        darkolivegreen 556b2f darkorange ff8c00 darkorchid 9932cc darkred 8b0000 darksalmon e9967a darkseagreen 8fbc8f \
        darkslateblue 483d8b darkslategray 2f4f4f darkslategrey 2f4f4f darkturquoise 00ced1 darkviolet 9400d3 deeppink ff1493 \
        deepskyblue 00bfff dimgray 696969 dimgrey 696969 dodgerblue 1e90ff firebrick b22222 floralwhite fffaf0 forestgreen 228b22 \
        fuchsia ff00ff gainsboro dcdcdc ghostwhite f8f8ff gold ffd700 goldenrod daa520 gray 808080 green 008000 greenyellow adff2f \
        grey 808080 honeydew f0fff0 hotpink ff69b4 indianred cd5c5c indigo 4b0082 ivory fffff0 khaki f0e68c lavender e6e6fa \
        lavenderblush fff0f5 lawngreen 7cfc00 lemonchiffon fffacd lightblue add8e6 lightcoral f08080 lightcyan e0ffff \
        lightgoldenrodyellow fafad2 lightgray d3d3d3 lightgreen 90ee90 lightgrey d3d3d3 lightpink ffb6c1 lightsalmon ffa07a \
        lightseagreen 20b2aa lightskyblue 87cefa lightslategray 778899 lightslategrey 778899 lightsteelblue b0c4de lightyellow ffffe0 \
        lime 00ff00 limegreen 32cd32 linen faf0e6 magenta ff00ff maroon 800000 mediumaquamarine 66cdaa mediumblue 0000cd \
        mediumorchid ba55d3 mediumpurple 9370db mediumseagreen 3cb371 mediumslateblue 7b68ee mediumspringgreen 00fa9a \
        mediumturquoise 48d1cc mediumvioletred c71585 midnightblue 191970 mintcream f5fffa mistyrose ffe4e1 moccasin ffe4b5 \
        navajowhite ffdead navy 000080 oldlace fdf5e6 olive 808000 olivedrab 6b8e23 orange ffa500 orangered ff4500 orchid da70d6 \
        palegoldenrod eee8aa palegreen 98fb98 paleturquoise afeeee palevioletred db7093 papayawhip ffefd5 peachpuff ffdab9 \
        peru cd853f pink ffc0cb plum dda0dd powderblue b0e0e6 purple 800080 rebeccapurple 663399 red ff0000 rosybrown bc8f8f \
        royalblue 4169e1 saddlebrown 8b4513 salmon fa8072 sandybrown f4a460 seagreen 2e8b57 seashell fff5ee sienna a0522d \
        silver c0c0c0 skyblue 87ceeb slateblue 6a5acd slategray 708090 slategrey 708090 snow fffafa springgreen 00ff7f \
        steelblue 4682b4 tan d2b48c teal 008080 thistle d8bfd8 tomato ff6347 turquoise 40e0d0 violet ee82ee wheat f5deb3 \
        white ffffff whitesmoke f5f5f5 yellow ffff00 yellowgreen 9acd32
        """
        let words = table.split(whereSeparator: \.isWhitespace).map(String.init)
        return Dictionary(uniqueKeysWithValues: stride(from: 0, to: words.count - 1, by: 2).map { (words[$0], words[$0 + 1]) })
    }()
}

import Foundation

/// Documents for trying the app out and for benchmarks.
public enum SampleDocuments {
    public static func showcase() -> Document {
        var builder = Builder(pageName: "Page 1")

        let phone = builder.add(.artboard("iPhone", Rect(x: 0, y: 0, width: 393, height: 852)))
        builder.add(.rectangle("Header", Rect(x: 0, y: 0, width: 393, height: 120), fill: "#5B5BD6"), in: phone)
        var card = Layer.rectangle("Card", Rect(x: 24, y: 152, width: 345, height: 200), radius: 16, fill: "#FFFFFF")
        card.style.shadows = [Shadow(color: Color(hex: "#1B1B3A26")!, x: 0, y: 8, blur: 24)]
        let cardID = builder.add(card, in: phone)
        builder.add(.oval("Avatar", Rect(x: 48, y: 176, width: 64, height: 64), fill: "#FF8A65"), in: phone)
        builder.add(.rectangle("Title", Rect(x: 128, y: 188, width: 180, height: 14), radius: 7, fill: "#C7C7D1"), in: phone)
        builder.add(.rectangle("Subtitle", Rect(x: 128, y: 214, width: 120, height: 10), radius: 5, fill: "#DCDCE4"), in: phone)
        let button = builder.add(.rectangle("Background", Rect(x: 24, y: 764, width: 345, height: 52), radius: 12, fill: "#111114"), in: phone)
        builder.add(.text("Greeting", "Good morning", at: (24, 64), size: 28, weight: "HelveticaNeue-Bold", color: "#FFFFFF"), in: phone)
        let buttonLabel = builder.add(.text("Label", "Get started", at: (24, 779), width: 345, size: 17, weight: "HelveticaNeue-Medium", color: "#FFFFFF", alignment: .center), in: phone)

        let desktop = builder.add(.artboard("Desktop", Rect(x: 473, y: 0, width: 1440, height: 1024)))
        builder.add(.rectangle("Navigation", Rect(x: 0, y: 0, width: 1440, height: 72), fill: "#FFFFFF", border: "#E6E6EC"), in: desktop)
        builder.add(.oval("Logo", Rect(x: 40, y: 20, width: 32, height: 32), fill: "#5B5BD6"), in: desktop)
        let menu = ["Product", "Pricing", "Docs", "Sign in"].enumerated().map { index, title in
            builder.add(.text(title, title, at: (1060 + Double(index) * 90, 26), size: 15, weight: "HelveticaNeue-Medium", color: "#111114"), in: desktop)
        }
        var hero = Layer.rectangle("Hero", Rect(x: 40, y: 112, width: 1360, height: 420), radius: 24, fill: "#EEF0FF")
        hero.style.fills = [Fill(Color(hex: "#5B5BD6")!, gradient: Gradient(
            from: UnitPoint(x: 0, y: 0), to: UnitPoint(x: 1, y: 1),
            stops: [GradientStop(position: 0, color: Color(hex: "#5B5BD6")!), GradientStop(position: 1, color: Color(hex: "#E54666")!)]
        ))]
        builder.add(hero, in: desktop)
        builder.add(.text("Headline", "Design at the speed of thought", at: (96, 220), size: 56, weight: "HelveticaNeue-Bold", color: "#FFFFFF"), in: desktop)
        builder.add(.text("Subhead", "Every tool, every property and every layer is a few keys away.", at: (96, 300), width: 560, size: 22, weight: "HelveticaNeue", color: "#FFFFFFCC"), in: desktop)
        for index in 0..<3 {
            let x = 40 + Double(index) * 464
            builder.add(.rectangle("Card \(index + 1)", Rect(x: x, y: 572, width: 432, height: 300), radius: 16, fill: "#F7F7FA", border: "#E6E6EC"), in: desktop)
        }

        var iconArtboard = Layer.artboard("App Icon", Rect(x: 1993, y: 0, width: 512, height: 512))
        iconArtboard.exports = [
            ExportPreset(),
            ExportPreset(size: .scale(2), suffix: "@2x"),
            ExportPreset(format: .svg),
        ]
        let icon = builder.add(iconArtboard)
        builder.add(.rectangle("Background", Rect(x: 0, y: 0, width: 512, height: 512), radius: 112, fill: "#FFC53D"), in: icon)
        builder.add(.oval("Sun", Rect(x: 136, y: 136, width: 240, height: 240), fill: "#FF6B3D"), in: icon)

        builder.add(.oval("Loose Oval", Rect(x: 0, y: 952, width: 120, height: 120), fill: "#30A46C"))
        var transaction = Transaction(builder.document)
        for id in builder.document.layers.keys where builder.document.layers[id]?.textContent != nil {
            transaction.update(id) { _ in }
        }
        transaction.fitText()
        // The menu is a row that grows with its items; the button stretches with its instances.
        if let stack = transaction.addStack(menu) {
            transaction.update(stack) { $0.name = "Menu"; $0.stack?.spacing = 32 }
            transaction.layoutStack(stack)
        }
        transaction.update(button) { $0.constraints = Constraints(horizontal: .both, vertical: .both) }
        transaction.update(buttonLabel) { $0.constraints = Constraints(horizontal: .both, vertical: .center) }
        // The button becomes a symbol, the palette gets the brand colors, the card a shared style.
        if let symbol = transaction.createSymbol(from: [button, buttonLabel], name: "Button/Primary"), let instance = symbol.instance {
            transaction.update(instance) { $0.name = "Get Started Button" }
        }
        transaction.addSwatch(Color(hex: "#5B5BD6")!, name: "Brand")
        transaction.addSwatch(Color(hex: "#E54666")!, name: "Accent")
        transaction.addSwatch(Color(hex: "#111114")!, name: "Ink")
        transaction.createSharedStyle(from: cardID, name: "Card/Elevated")
        return transaction.document
    }

    /// `count` small shapes spread over artboards of 500 shapes each.
    public static func stress(count: Int = 5_000) -> Document {
        var builder = Builder(pageName: "Stress Test")
        let perArtboard = 500
        let columns = 25
        let palette = ["#5B5BD6", "#FF8A65", "#30A46C", "#FFC53D", "#E5484D", "#0090FF", "#8E4EC6"]

        var artboard: LayerID?
        for index in 0..<count {
            if index % perArtboard == 0 {
                let number = index / perArtboard
                let frame = Rect(x: Double(number % 5) * 1100, y: Double(number / 5) * 900, width: 1000, height: 800)
                artboard = builder.add(.artboard("Artboard \(number + 1)", frame))
            }
            let local = index % perArtboard
            let frame = Rect(x: 20 + Double(local % columns) * 39, y: 20 + Double(local / columns) * 39, width: 32, height: 32)
            let fill = palette[index % palette.count]
            let layer: Layer = index.isMultiple(of: 2)
                ? .rectangle("Rectangle \(index + 1)", frame, radius: 6, fill: fill)
                : .oval("Oval \(index + 1)", frame, fill: fill)
            builder.add(layer, in: artboard)
        }
        return builder.document
    }

    private struct Builder {
        var document: Document

        init(pageName: String) {
            document = Document(pages: [Page(name: pageName)])
        }

        @discardableResult
        mutating func add(_ layer: Layer, in parent: LayerID? = nil) -> LayerID {
            var layer = layer
            layer.parent = parent
            document.layers[layer.id] = layer
            if let parent {
                document.layers[parent]?.children.append(layer.id)
            } else {
                document.pages[0].layers.append(layer.id)
            }
            return layer.id
        }
    }
}

extension Layer {
    static func artboard(_ name: String, _ frame: Rect) -> Layer {
        Layer(name: name, kind: .artboard, frame: frame, style: Style(fills: [Fill(.white)]))
    }

    static func rectangle(_ name: String, _ frame: Rect, radius: Double = 0, fill: String, border: String? = nil) -> Layer {
        Layer(name: name, kind: .rectangle(cornerRadius: radius), frame: frame, style: style(fill: fill, border: border))
    }

    static func oval(_ name: String, _ frame: Rect, fill: String, border: String? = nil) -> Layer {
        Layer(name: name, kind: .oval, frame: frame, style: style(fill: fill, border: border))
    }

    /// Text at a top-left point; with `width` it wraps (auto height), otherwise it sizes itself.
    static func text(_ name: String, _ text: String, at origin: (Double, Double), width: Double? = nil, size: Double,
                     weight: String, color: String, alignment: TextContent.Alignment = .left) -> Layer {
        let style = TextStyle(fontName: weight, fontSize: size, color: Color(hex: color) ?? .black)
        let content = TextContent(text, style: style, alignment: alignment, sizing: width == nil ? .autoWidth : .autoHeight)
        return Layer(name: name, kind: .text(content), frame: Rect(x: origin.0, y: origin.1, width: width ?? 0, height: 0))
    }

    private static func style(fill: String, border: String?) -> Style {
        Style(
            fills: Color(hex: fill).map { [Fill($0)] } ?? [],
            borders: border.flatMap(Color.init(hex:)).map { [Border($0)] } ?? []
        )
    }
}

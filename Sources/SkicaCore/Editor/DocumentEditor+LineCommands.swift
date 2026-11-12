import CoreGraphics
import CoreText
import Foundation

extension DocumentEditor {
    /// Runs a command line on the selection. Values are checked for every layer before
    /// anything changes, so a mistake leaves the document as it was.
    /// Commands that are not editing actions (e.g. group) return them for the caller to run.
    @discardableResult
    public func run(commandLine text: String) throws -> [CommandID] {
        let commands = try LineCommandParser.parse(text, assets: document.assets)
        guard !selection.isEmpty else { throw InputError.invalid("Select layers first.") }
        var actions: [CommandID] = []
        for command in commands {
            if case .action(let id) = command {
                actions.append(id)
            } else {
                try run(command, title: text)
            }
        }
        return actions
    }

    private func run(_ command: LineCommand, title: String) throws {
        let layers = selectedLayers
        switch command {
        case .x(let text): try setNumber(text, layers, \.frame.x) { $0.frame.x = $1 }
        case .y(let text): try setNumber(text, layers, \.frame.y) { $0.frame.y = $1 }
        case .width(let text): try setNumber(text, layers, \.frame.width, minimum: 0) { $0.frame.width = $1 }
        case .height(let text): try setNumber(text, layers, \.frame.height, minimum: 0) { $0.frame.height = $1 }
        case .rotation(let text): try setNumber(text, layers, \.rotation) { $0.rotation = $1.truncatingRemainder(dividingBy: 360) }
        case .opacity(let text):
            let values = try layers.map { min(max(try NumericExpression.evaluate(text, current: $0.opacity * 100), 0), 100) / 100 }
            apply(values, to: layers, "Change Opacity") { $0.opacity = $1 }
        case .radius(let text):
            let rectangles = layers.filter { if case .rectangle = $0.kind { true } else { false } }
            guard !rectangles.isEmpty else { throw InputError.invalid("Corner radius applies to rectangles.") }
            let values = try rectangles.map { layer -> Double in
                guard case .rectangle(let radius) = layer.kind else { return 0 }
                return max(try NumericExpression.evaluate(text, current: radius), 0)
            }
            apply(values, to: rectangles, "Change Radius") { $0.kind = .rectangle(cornerRadius: $1) }
        case .geometry(let text):
            let inputs = try layers.map { try GeometryPrompt.parse(text, current: $0.frame) }
            apply(inputs, to: layers, "Change Size and Position") { $0.frame = $1.applied(to: $0.frame) }
        case .fill(let color):
            updateSelection("Change Fill") { layer in
                guard let color else { return layer.style.fills = [] }
                if layer.style.fills.isEmpty {
                    layer.style.fills = [Fill(color)]
                } else {
                    layer.style.fills[0].color = color
                    layer.style.fills[0].gradient = nil
                    layer.style.fills[0].isEnabled = true
                }
            }
        case .border(let width, let color, let position):
            updateSelection("Change Border") { layer in
                if layer.style.borders.isEmpty { layer.style.borders = [Border(Tool.defaultBorder)] }
                if let width { layer.style.borders[0].width = width }
                if let color { layer.style.borders[0].color = color }
                if let position { layer.style.borders[0].position = position }
                layer.style.borders[0].isEnabled = true
            }
        case .removeBorders:
            updateSelection("Remove Borders") { $0.style.borders = [] }
        case .shadow(let shadow):
            updateSelection(shadow == nil ? "Remove Shadows" : "Change Shadow") { layer in
                guard let shadow else { return layer.style.shadows = [] }
                if layer.style.shadows.isEmpty { layer.style.shadows = [shadow] } else { layer.style.shadows[0] = shadow }
            }
        case .blur(let radius):
            updateSelection(radius == nil ? "Remove Blur" : "Change Blur") { layer in
                layer.style.blur = radius.map { Blur(radius: $0) }
            }
        case .blend(let mode):
            updateSelection("Change Blend Mode") { $0.style.blendMode = mode }
        case .name(let name):
            updateSelection("Rename") { $0.name = name }
        case .font(let family, let size, let weight):
            let texts = try textLayers(layers)
            var faces: [LayerID: String] = [:]
            if family != nil || weight != nil {
                for layer in texts {
                    let current = layer.textContent?.leadingStyle ?? TextStyle()
                    let wantedFamily = family ?? currentFamily(of: current)
                    guard let face = FontFaces.face(family: wantedFamily, weight: weight) else {
                        throw InputError.invalid("No installed font family \"\(wantedFamily)\".")
                    }
                    faces[layer.id] = face
                }
            }
            perform("Change Font") { transaction in
                for layer in texts {
                    transaction.update(layer.id) { layer in
                        guard var content = layer.textContent else { return }
                        content.updateStyles { style in
                            if let face = faces[layer.id] { style.fontName = face }
                            if let size { style.fontSize = size }
                        }
                        layer.kind = .text(content)
                    }
                }
            }
        case .fontSize(let text):
            let texts = try textLayers(layers)
            let sizes = try texts.map { max(try NumericExpression.evaluate(text, current: $0.textContent?.leadingStyle.fontSize), 1) }
            apply(sizes, to: texts, "Change Font Size") { layer, size in
                guard var content = layer.textContent else { return }
                content.updateStyles { $0.fontSize = size }
                layer.kind = .text(content)
            }
        case .textColor(let color):
            let texts = try textLayers(layers)
            perform("Change Text Color") { transaction in
                for layer in texts {
                    transaction.update(layer.id) { layer in
                        guard var content = layer.textContent else { return }
                        content.updateStyles { $0.color = color }
                        layer.kind = .text(content)
                    }
                }
            }
        case .align(let edge):
            perform("Align") { $0.align(selection, edge) }
        case .distribute(let horizontally, let spacing):
            guard selection.count >= (spacing == nil ? 3 : 2) else {
                throw InputError.invalid(spacing == nil ? "Distribute needs three or more layers." : "Spacing needs two or more layers.")
            }
            distribute(horizontally: horizontally, spacing: spacing)
        case .sharedStyle(let name):
            let wanted = name.lowercased()
            guard let shared = document.assets.sharedStyles.first(where: { $0.name.lowercased() == wanted })
                ?? document.assets.sharedStyles.first(where: { FuzzyMatch.score(name, in: $0.name) != nil }) else {
                throw InputError.invalid("No shared style named \"\(name)\".")
            }
            perform("Apply Style") { $0.applySharedStyle(shared.id, to: selection) }
        case .stack(let stack):
            if let stack {
                let containers = layers.filter(\.isContainer)
                if containers.count == layers.count {
                    updateSelection("Stack") { $0.stack = stack }
                } else {
                    performSelecting("Stack") { transaction in
                        guard let id = transaction.addStack(selection) else { return selection }
                        transaction.update(id) { $0.stack = stack }
                        transaction.layoutStack(id)
                        return [id]
                    }
                }
            } else {
                removeStack()
            }
        case .gap(let gap):
            guard layers.contains(where: { $0.stack != nil }) else { throw InputError.invalid("Select a stack first.") }
            updateStack("Change Gap") { $0.spacing = gap }
        case .padding(let insets):
            guard layers.contains(where: { $0.stack != nil }) else { throw InputError.invalid("Select a stack first.") }
            updateStack("Change Padding") { $0.padding = insets }
        case .pin(let horizontal, let vertical):
            updateSelection("Change Constraints") { layer in
                if let horizontal { layer.constraints.horizontal = horizontal }
                if let vertical { layer.constraints.vertical = vertical }
            }
        case .visible(let visible):
            updateSelection(visible ? "Show" : "Hide") { $0.isVisible = visible }
        case .locked(let locked):
            updateSelection(locked ? "Lock" : "Unlock") { $0.isLocked = locked }
        case .action:
            break
        }
    }

    private func setNumber(_ text: String, _ layers: [Layer], _ keyPath: KeyPath<Layer, Double>, minimum: Double? = nil,
                           _ set: (inout Layer, Double) -> Void) throws {
        let values = try layers.map { layer -> Double in
            let value = try NumericExpression.evaluate(text, current: layer[keyPath: keyPath])
            return minimum.map { max(value, $0) } ?? value
        }
        apply(values, to: layers, "Change Value", set)
    }

    private func apply<Value>(_ values: [Value], to layers: [Layer], _ name: String, _ set: (inout Layer, Value) -> Void) {
        perform(name) { transaction in
            for (layer, value) in zip(layers, values) {
                transaction.update(layer.id) { set(&$0, value) }
            }
        }
    }

    private func textLayers(_ layers: [Layer]) throws -> [Layer] {
        let texts = layers.filter { $0.textContent != nil }
        guard !texts.isEmpty else { throw InputError.invalid("Select text layers first.") }
        return texts
    }

    private func currentFamily(of style: TextStyle) -> String {
        CTFontCopyFamilyName(TextLayout.font(for: style)) as String
    }
}

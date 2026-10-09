import Foundation

/// A wallpaper put together from a background and layers on top of it — text, pictures, shapes
/// and free-form web code. It is stored as `scene.json` in the wallpaper's folder and drawn by
/// the web runtime (`SceneProject`), so everything the editor makes is plain HTML in the end.
///
/// Positions and sizes are percentages of the screen and lengths are pixels of a 1080-pixel-high
/// screen, so a scene looks the same on every display.
public struct WallpaperScene: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var background: Background
    public var layers: [Layer]
    /// What the scene lets be changed without the editor, see `Variable`.
    public var variables: [Variable]

    public init(background: Background = Background(), layers: [Layer] = [], variables: [Variable] = []) {
        version = Self.currentVersion
        self.background = background
        self.layers = layers
        self.variables = variables
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = values.value(.version, or: Self.currentVersion)
        background = values.value(.background, or: Background())
        layers = values.value(.layers, or: [])
        variables = values.value(.variables, or: [])
    }

    /// A key no other variable of the scene has: the wanted one, or it with a number added.
    public func uniqueKey(_ wanted: String, for id: UUID? = nil) -> String {
        let base = Variable.key(from: wanted)
        let taken = Set(variables.filter { $0.id != id }.map(\.key))
        guard taken.contains(base) else { return base }
        var number = 2
        while taken.contains("\(base)\(number)") {
            number += 1
        }
        return "\(base)\(number)"
    }

    // MARK: - Background

    public struct Background: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, CaseIterable, Sendable {
            case video, image, color
        }

        public enum Fit: String, Codable, CaseIterable, Sendable {
            /// Fills the screen, cropping the edges.
            case cover
            /// Shows the whole picture with bars around it.
            case contain
            /// Stretches to the screen.
            case fill
        }

        public var kind: Kind
        /// The video or picture, relative to the wallpaper's folder.
        public var source: String?
        /// Shown behind the media and wherever it does not reach.
        public var color: String
        public var fit: Fit
        /// Which part stays in view when covering the screen crops the media, in percent:
        /// 0 keeps the left or the top, 100 the right or the bottom.
        public var position: Double
        /// In pixels of a 1080-pixel-high screen.
        public var blur: Double
        /// Percent; 100 leaves the picture as it is.
        public var brightness: Double
        public var contrast: Double
        public var saturation: Double
        /// Degrees around the colour wheel.
        public var hue: Double

        public init(kind: Kind = .color, source: String? = nil, color: String = "#000000", fit: Fit = .cover,
                    position: Double = 50, blur: Double = 0, brightness: Double = 100, contrast: Double = 100,
                    saturation: Double = 100, hue: Double = 0) {
            self.kind = kind
            self.source = source
            self.color = color
            self.fit = fit
            self.position = position
            self.blur = blur
            self.brightness = brightness
            self.contrast = contrast
            self.saturation = saturation
            self.hue = hue
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Background()
            kind = values.value(.kind, or: defaults.kind)
            source = try? values.decodeIfPresent(String.self, forKey: .source)
            color = values.value(.color, or: defaults.color)
            fit = values.value(.fit, or: defaults.fit)
            position = values.value(.position, or: defaults.position)
            blur = values.value(.blur, or: defaults.blur)
            brightness = values.value(.brightness, or: defaults.brightness)
            contrast = values.value(.contrast, or: defaults.contrast)
            saturation = values.value(.saturation, or: defaults.saturation)
            hue = values.value(.hue, or: defaults.hue)
        }
    }

    // MARK: - Layers

    /// One thing on top of the background. Every kind shares the placement and the look; the rest
    /// of the fields belong to one kind each and are ignored by the others.
    public struct Layer: Codable, Equatable, Identifiable, Sendable {
        public enum Kind: String, Codable, CaseIterable, Sendable {
            case text, image, shape, code
        }

        public var id: UUID
        public var kind: Kind
        public var name: String
        public var isVisible: Bool
        /// Whether the layer is part of the still picture macOS shows on the lock screen and in
        /// Mission Control. A clock is better left out of it: it would stand still there.
        public var showsOnLockScreen: Bool

        /// The centre, in percent of the screen.
        public var x: Double
        public var y: Double
        /// In percent of the screen's width. Text wraps at it; pictures keep their proportions.
        public var width: Double
        /// In percent of the screen's height; used by shapes and code.
        public var height: Double
        public var rotation: Double
        /// Percent.
        public var opacity: Double
        /// A CSS `mix-blend-mode`.
        public var blendMode: String
        /// "none", "pulse", "float", "spin" or "blink".
        public var animation: String
        /// Seconds for one round of the animation.
        public var animationDuration: Double
        public var shadowColor: String
        /// Zero means no shadow.
        public var shadowBlur: Double
        public var shadowX: Double
        public var shadowY: Double

        // Text. `{HH}`, `{mm}`, `{weekday}`, `{date}` and the like are replaced with the time and
        // date; the runtime has the full list.
        public var text: String
        public var fontFamily: String
        /// In percent of the screen's height.
        public var fontSize: Double
        public var fontWeight: Int
        public var isItalic: Bool
        public var color: String
        /// "left", "center" or "right".
        public var alignment: String
        /// In ems.
        public var letterSpacing: Double
        public var lineHeight: Double

        // Image: a file relative to the wallpaper's folder.
        public var source: String

        // Shape.
        /// "rectangle" or "ellipse".
        public var shape: String
        public var fill: String
        public var cornerRadius: Double
        public var borderColor: String
        public var borderWidth: Double

        // Code: anything the web can do, placed in the layer's box.
        public var html: String
        public var css: String
        public var javaScript: String

        public init(kind: Kind, name: String, id: UUID = UUID()) {
            self.id = id
            self.kind = kind
            self.name = name
            isVisible = true
            showsOnLockScreen = true
            x = 50
            y = 50
            width = kind == .text ? 60 : 30
            height = 30
            rotation = 0
            opacity = 100
            blendMode = "normal"
            animation = "none"
            animationDuration = 4
            shadowColor = "#00000099"
            shadowBlur = kind == .text ? 12 : 0
            shadowX = 0
            shadowY = 0
            text = "{HH}:{mm}"
            fontFamily = "-apple-system"
            fontSize = 12
            fontWeight = 700
            isItalic = false
            color = "#FFFFFF"
            alignment = "center"
            letterSpacing = 0
            lineHeight = 1.1
            source = ""
            shape = "rectangle"
            fill = "#FFFFFF33"
            cornerRadius = 24
            borderColor = "#FFFFFF"
            borderWidth = 0
            html = ""
            css = ""
            javaScript = ""
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try values.decode(Kind.self, forKey: .kind)
            let defaults = Layer(kind: kind, name: kind.rawValue.capitalized)
            id = values.value(.id, or: defaults.id)
            self.kind = kind
            name = values.value(.name, or: defaults.name)
            isVisible = values.value(.isVisible, or: defaults.isVisible)
            showsOnLockScreen = values.value(.showsOnLockScreen, or: defaults.showsOnLockScreen)
            x = values.value(.x, or: defaults.x)
            y = values.value(.y, or: defaults.y)
            width = values.value(.width, or: defaults.width)
            height = values.value(.height, or: defaults.height)
            rotation = values.value(.rotation, or: defaults.rotation)
            opacity = values.value(.opacity, or: defaults.opacity)
            blendMode = values.value(.blendMode, or: defaults.blendMode)
            animation = values.value(.animation, or: defaults.animation)
            animationDuration = values.value(.animationDuration, or: defaults.animationDuration)
            shadowColor = values.value(.shadowColor, or: defaults.shadowColor)
            shadowBlur = values.value(.shadowBlur, or: defaults.shadowBlur)
            shadowX = values.value(.shadowX, or: defaults.shadowX)
            shadowY = values.value(.shadowY, or: defaults.shadowY)
            text = values.value(.text, or: defaults.text)
            fontFamily = values.value(.fontFamily, or: defaults.fontFamily)
            fontSize = values.value(.fontSize, or: defaults.fontSize)
            fontWeight = values.value(.fontWeight, or: defaults.fontWeight)
            isItalic = values.value(.isItalic, or: defaults.isItalic)
            color = values.value(.color, or: defaults.color)
            alignment = values.value(.alignment, or: defaults.alignment)
            letterSpacing = values.value(.letterSpacing, or: defaults.letterSpacing)
            lineHeight = values.value(.lineHeight, or: defaults.lineHeight)
            source = values.value(.source, or: defaults.source)
            shape = values.value(.shape, or: defaults.shape)
            fill = values.value(.fill, or: defaults.fill)
            cornerRadius = values.value(.cornerRadius, or: defaults.cornerRadius)
            borderColor = values.value(.borderColor, or: defaults.borderColor)
            borderWidth = values.value(.borderWidth, or: defaults.borderWidth)
            html = values.value(.html, or: defaults.html)
            css = values.value(.css, or: defaults.css)
            javaScript = values.value(.javaScript, or: defaults.javaScript)
        }
    }
}

extension WallpaperScene {
    /// A value the scene's author has put up for changing without the editor. It shows in the
    /// wallpaper's settings under its title, and the scene reads it by its key: `var(--key)` in
    /// CSS, `wallaero.variables.key` in JavaScript, `{key}` in the text of a text layer.
    public struct Variable: Codable, Equatable, Identifiable, Sendable {
        public enum Kind: String, Codable, CaseIterable, Sendable {
            case color, number, toggle, text, choice
        }

        public var id: UUID
        public var kind: Kind
        /// What the setting is called in the wallpaper's settings.
        public var title: String
        /// The name the scene's code knows it by: letters, digits and underscores.
        public var key: String

        // The value is in the field of the variable's kind; the others are ignored.
        public var color: String
        public var number: Double
        public var minimum: Double
        public var maximum: Double
        public var step: Double
        public var isOn: Bool
        /// The text, or the chosen one of `options` for a choice.
        public var text: String
        public var options: [String]

        public init(kind: Kind, title: String, key: String, id: UUID = UUID()) {
            self.id = id
            self.kind = kind
            self.title = title
            self.key = key
            color = "#FFFFFF"
            number = 50
            minimum = 0
            maximum = 100
            step = 1
            isOn = true
            text = ""
            options = []
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try values.decode(Kind.self, forKey: .kind)
            let defaults = Variable(kind: kind, title: "", key: "variable")
            id = values.value(.id, or: defaults.id)
            self.kind = kind
            key = Self.key(from: values.value(.key, or: defaults.key))
            title = values.value(.title, or: key)
            color = values.value(.color, or: defaults.color)
            number = values.value(.number, or: defaults.number)
            minimum = values.value(.minimum, or: defaults.minimum)
            maximum = values.value(.maximum, or: defaults.maximum)
            step = values.value(.step, or: defaults.step)
            isOn = values.value(.isOn, or: defaults.isOn)
            text = values.value(.text, or: defaults.text)
            options = values.value(.options, or: defaults.options)
        }

        /// Any text made into a key that CSS, JavaScript and a text layer all accept: Latin
        /// letters, digits and underscores, not starting with a digit. "цвет полос" becomes
        /// "cvet_polos".
        public static func key(from text: String) -> String {
            let latin = text.applyingTransform(.toLatin, reverse: false)?
                .applyingTransform(.stripDiacritics, reverse: false) ?? text
            var key = ""
            for scalar in latin.unicodeScalars {
                let isLetter = ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
                let isDigit = ("0"..."9").contains(scalar)
                if isLetter || isDigit || scalar == "_" {
                    key.unicodeScalars.append(scalar)
                } else if !key.isEmpty, !key.hasSuffix("_") {
                    key.append("_")
                }
            }
            while key.hasSuffix("_") {
                key.removeLast()
            }
            if key.isEmpty {
                return "variable"
            }
            return key.first!.isNumber ? "_" + key : key
        }
    }
}

private extension KeyedDecodingContainer {
    /// A scene file written by hand, or by another version of the app, may lack keys or hold a
    /// value of the wrong type; either way the default stands in rather than the scene failing.
    func value<T: Decodable>(_ key: Key, or fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}

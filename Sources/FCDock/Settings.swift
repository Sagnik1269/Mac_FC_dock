import Foundation

/// The wheel's adjustable look and feel. `shared` is what the real wheel uses and is saved in
/// UserDefaults; the dashboard edits a `draft` copy and only writes it back on Save Changes.
final class Settings: ObservableObject {
    static let shared = Settings(persists: true)

    /// A tunable value: its allowed range and the value v1 shipped with.
    struct Option {
        let key: String
        let range: ClosedRange<Double>
        let defaultValue: Double
    }

    enum Options {
        /// Overall wheel size; 1 = the v1 size. Capped at 200%.
        static let wheelScale = Option(key: "wheelScale", range: 0.5...2, defaultValue: 1)
        /// Cover size relative to the wheel.
        static let coverScale = Option(key: "coverScale", range: 0.6...1.2, defaultValue: 1)
        /// How much of the blur shows through the glass (0 = clear, 1 = fully frosted).
        static let blur = Option(key: "blur", range: 0...1, defaultValue: 0.45)
        /// Dark tint behind the labels.
        static let tint = Option(key: "tint", range: 0...0.6, defaultValue: 0.18)
        /// Accent fill on the hovered arc.
        static let highlight = Option(key: "highlight", range: 0.15...1, defaultValue: 0.55)
        /// Width of the gap between arcs, in points.
        static let arcGap = Option(key: "arcGap", range: 0...12, defaultValue: 5)
        /// How far the hovered arc moves out, in points.
        static let popDistance = Option(key: "popDistance", range: 0...16, defaultValue: 4)
        /// How long Shift must be held before the wheel opens, in seconds.
        static let holdDelay = Option(key: "holdDelay", range: 0.2...1, defaultValue: 0.4)

        static let all = [wheelScale, coverScale, blur, tint, highlight, arcGap, popDistance, holdDelay]
    }

    @Published var wheelScale: Double { didSet { save(wheelScale, Options.wheelScale) } }
    @Published var coverScale: Double { didSet { save(coverScale, Options.coverScale) } }
    @Published var blur: Double { didSet { save(blur, Options.blur) } }
    @Published var tint: Double { didSet { save(tint, Options.tint) } }
    @Published var highlight: Double { didSet { save(highlight, Options.highlight) } }
    @Published var arcGap: Double { didSet { save(arcGap, Options.arcGap) } }
    @Published var popDistance: Double { didSet { save(popDistance, Options.popDistance) } }
    @Published var holdDelay: Double { didSet { save(holdDelay, Options.holdDelay) } }

    private let persists: Bool
    private let defaults = UserDefaults.standard

    private init(persists: Bool) {
        self.persists = persists
        func load(_ option: Option) -> Double {
            guard persists, let value = UserDefaults.standard.object(forKey: option.key) as? Double else { return option.defaultValue }
            return min(max(value, option.range.lowerBound), option.range.upperBound)
        }
        wheelScale = load(Options.wheelScale)
        coverScale = load(Options.coverScale)
        blur = load(Options.blur)
        tint = load(Options.tint)
        highlight = load(Options.highlight)
        arcGap = load(Options.arcGap)
        popDistance = load(Options.popDistance)
        holdDelay = load(Options.holdDelay)
    }

    /// An unsaved copy to edit; changes to it go nowhere until `copy(from:)` is called on `shared`.
    func draft() -> Settings {
        let draft = Settings(persists: false)
        draft.copy(from: self)
        return draft
    }

    func copy(from other: Settings) {
        wheelScale = other.wheelScale
        coverScale = other.coverScale
        blur = other.blur
        tint = other.tint
        highlight = other.highlight
        arcGap = other.arcGap
        popDistance = other.popDistance
        holdDelay = other.holdDelay
    }

    func matches(_ other: Settings) -> Bool {
        values == other.values
    }

    private var values: [Double] {
        [wheelScale, coverScale, blur, tint, highlight, arcGap, popDistance, holdDelay]
    }

    func resetToDefaults() {
        wheelScale = Options.wheelScale.defaultValue
        coverScale = Options.coverScale.defaultValue
        blur = Options.blur.defaultValue
        tint = Options.tint.defaultValue
        highlight = Options.highlight.defaultValue
        arcGap = Options.arcGap.defaultValue
        popDistance = Options.popDistance.defaultValue
        holdDelay = Options.holdDelay.defaultValue
    }

    private func save(_ value: Double, _ option: Option) {
        guard persists else { return }
        defaults.set(value, forKey: option.key)
    }
}

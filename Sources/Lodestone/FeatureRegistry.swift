/// Every feature, in the order of the menu bar menu and the Settings tabs.
/// Adding a feature: create `Features/<Name>/<Name>Feature.swift` conforming to `Feature`, then add it here.
@MainActor
enum FeatureRegistry {
    static func make() -> [Feature] {
        [
            SnappingFeature(),
            ScreenTextFeature(),
            ColorPickerFeature(),
            TextTransformsFeature(),
        ]
    }
}

import AppKit

struct GaugeIconStyle {
  let fableStarSize: CGFloat
  let fableStarRadius: CGFloat
  let fastHandLength: CGFloat
  let fastHandWidth: CGFloat
  let fastHandRadius: CGFloat
  let weeklyHandLength: CGFloat
  let weeklyHandWidth: CGFloat
  let weeklyHandRadius: CGFloat
  let scaleDotSize: CGFloat
  let scaleRadius: CGFloat
  let redlineWidth: CGFloat
  let hubSize: CGFloat
  let codexColor: NSColor
  let claudeColor: NSColor
  let antigravityColor: NSColor
  let redlineColor: NSColor
}

enum DisplayMode: String, CaseIterable, Sendable {
  case gauge
  case meters

  var menuTitle: String {
    switch self {
    case .gauge: "Gauge"
    case .meters: "Meters"
    }
  }
}

enum MeterFillMode: String, CaseIterable, Sendable {
  case fill
  case empty

  var menuTitle: String {
    switch self {
    case .fill: "Fill (Used)"
    case .empty: "Empty (Remaining)"
    }
  }
}

enum MeterDirection: String, CaseIterable, Sendable {
  case leftToRight
  case rightToLeft

  var menuTitle: String {
    switch self {
    case .leftToRight: "Left to Right"
    case .rightToLeft: "Right to Left"
    }
  }
}

enum MeterLabelMode: String, CaseIterable, Sendable {
  /// A small provider-coloured square at the left of each card.
  case swatch
  case none

  var menuTitle: String {
    switch self {
    case .swatch: "Color Swatch"
    case .none: "None (Bars Only)"
    }
  }
}

struct MeterIconStyle: Sendable {
  let width: CGFloat
  let fillMode: MeterFillMode
  let direction: MeterDirection
  let labelMode: MeterLabelMode
  let codexColor: NSColor
  let claudeColor: NSColor
  let antigravityColor: NSColor
  /// Kept for the gauge-shared colour settings; Meters mode does not draw it.
  var redlineColor: NSColor = GaugeColorChoice.red.nsColor
}

enum IconSliderSetting: String, CaseIterable, Sendable {
  case fableStarSize
  case fableStarRadius
  case fastHandLength
  case fastHandWidth
  case fastHandRadius
  case weeklyHandLength
  case weeklyHandWidth
  case weeklyHandRadius
  case scaleDotSize
  case scaleRadius
  case redlineWidth
  case hubSize
  case meterWidth

  var menuTitle: String {
    switch self {
    case .fableStarSize: "Fable Star Size"
    case .fableStarRadius: "Fable Star Radius"
    case .fastHandLength: "Short Hand Length"
    case .fastHandWidth: "Short Hand Width"
    case .fastHandRadius: "Short Hand Radius"
    case .weeklyHandLength: "Weekly Hand Length"
    case .weeklyHandWidth: "Weekly Hand Width"
    case .weeklyHandRadius: "Weekly Hand Radius"
    case .scaleDotSize: "Scale Dot Size"
    case .scaleRadius: "Scale Radius"
    case .redlineWidth: "Redline Width"
    case .hubSize: "Hub Dot Size"
    case .meterWidth: "Meter Width"
    }
  }

  var range: ClosedRange<Double> {
    switch self {
    case .fableStarSize: 0.5...8.0
    case .fableStarRadius: 0.0...18.0
    case .fastHandLength: 0.0...18.0
    case .fastHandWidth: 0.2...7.0
    case .fastHandRadius: 0.0...18.0
    case .weeklyHandLength: 0.0...22.0
    case .weeklyHandWidth: 0.2...7.0
    case .weeklyHandRadius: 0.0...18.0
    case .scaleDotSize: 0.25...1.4
    case .scaleRadius: 0.0...18.0
    case .redlineWidth: 0.8...3.8
    case .hubSize: 0.0...1.4
    case .meterWidth: 20.0...72.0
    }
  }

  var defaultValue: Double {
    switch self {
    case .fableStarSize: 3.70
    case .fableStarRadius: 7.10
    case .fastHandLength: 2.80
    case .fastHandWidth: 2.10
    case .fastHandRadius: 10.30
    case .weeklyHandLength: 10.60
    case .weeklyHandWidth: 1.90
    case .weeklyHandRadius: 9.40
    case .scaleDotSize: 0.62
    case .scaleRadius: 8.60
    case .redlineWidth: 2.30
    case .hubSize: 0.55
    case .meterWidth: 36.0
    }
  }
}

enum GaugeColorChoice: String, CaseIterable, Sendable {
  case teal
  case cyan
  case mint
  case blue
  case purple
  case coral
  case orange
  case amber
  case pink
  case red

  var menuTitle: String {
    switch self {
    case .teal: "Teal"
    case .cyan: "Cyan"
    case .mint: "Mint"
    case .blue: "Blue"
    case .purple: "Purple"
    case .coral: "Coral"
    case .orange: "Orange"
    case .amber: "Amber"
    case .pink: "Pink"
    case .red: "Red"
    }
  }

  var nsColor: NSColor {
    switch self {
    case .teal:
      NSColor(calibratedRed: 0.16, green: 0.82, blue: 0.84, alpha: 1)
    case .cyan:
      NSColor(calibratedRed: 0.22, green: 0.68, blue: 1.00, alpha: 1)
    case .mint:
      NSColor(calibratedRed: 0.24, green: 0.86, blue: 0.55, alpha: 1)
    case .blue:
      NSColor(calibratedRed: 0.31, green: 0.56, blue: 1.00, alpha: 1)
    case .purple:
      NSColor(calibratedRed: 0.67, green: 0.45, blue: 1.00, alpha: 1)
    case .coral:
      NSColor(calibratedRed: 1.00, green: 0.55, blue: 0.34, alpha: 1)
    case .orange:
      NSColor(calibratedRed: 1.00, green: 0.45, blue: 0.18, alpha: 1)
    case .amber:
      NSColor(calibratedRed: 1.00, green: 0.72, blue: 0.25, alpha: 1)
    case .pink:
      NSColor(calibratedRed: 1.00, green: 0.39, blue: 0.66, alpha: 1)
    case .red:
      NSColor(calibratedRed: 1.00, green: 0.00, blue: 0.00, alpha: 1)
    }
  }
}

enum AppSettings {
  private static let codexColorKey = "codexColor"
  private static let claudeColorKey = "claudeColor"
  private static let antigravityColorKey = "antigravityColor"
  private static let redlineColorKey = "redlineColor"
  private static let displayModeKey = "displayMode"
  private static let meterFillModeKey = "meterFillMode"
  private static let meterDirectionKey = "meterDirection"
  private static let meterLabelModeKey = "meterLabelMode"
  // Text labels were removed from Meters mode; these keys are only cleared.
  private static let legacyCodexMeterLabelKey = "codexMeterLabel"
  private static let legacyClaudeMeterLabelKey = "claudeMeterLabel"
  private static let legacyAntigravityMeterLabelKey = "antigravityMeterLabel"
  private static let legacyFableStarScaleKey = "fableStarScale"
  private static let legacyHandScaleKey = "handScale"
  private static let legacyScaleDotScaleKey = "scaleDotScale"
  private static let legacyHubScaleKey = "hubScale"

  static let defaultCodexColor = GaugeColorChoice.teal
  static let defaultClaudeColor = GaugeColorChoice.coral
  static let defaultAntigravityColor = GaugeColorChoice.purple
  static let defaultRedlineColor = GaugeColorChoice.red
  static let defaultDisplayMode = DisplayMode.gauge
  static let defaultMeterFillMode = MeterFillMode.fill
  static let defaultMeterDirection = MeterDirection.leftToRight
  static let defaultMeterLabelMode = MeterLabelMode.swatch

  static var displayMode: DisplayMode {
    get {
      guard
        let raw = UserDefaults.standard.string(forKey: displayModeKey),
        let mode = DisplayMode(rawValue: raw)
      else {
        return defaultDisplayMode
      }
      return mode
    }
    set {
      UserDefaults.standard.set(newValue.rawValue, forKey: displayModeKey)
    }
  }

  static var meterFillMode: MeterFillMode {
    get {
      guard
        let raw = UserDefaults.standard.string(forKey: meterFillModeKey),
        let mode = MeterFillMode(rawValue: raw)
      else {
        return defaultMeterFillMode
      }
      return mode
    }
    set {
      UserDefaults.standard.set(newValue.rawValue, forKey: meterFillModeKey)
    }
  }

  static var meterDirection: MeterDirection {
    get {
      guard
        let raw = UserDefaults.standard.string(forKey: meterDirectionKey),
        let direction = MeterDirection(rawValue: raw)
      else {
        return defaultMeterDirection
      }
      return direction
    }
    set {
      UserDefaults.standard.set(newValue.rawValue, forKey: meterDirectionKey)
    }
  }

  static var meterLabelMode: MeterLabelMode {
    get {
      guard
        let raw = UserDefaults.standard.string(forKey: meterLabelModeKey),
        let mode = MeterLabelMode(rawValue: raw)
      else {
        return defaultMeterLabelMode
      }
      return mode
    }
    set {
      UserDefaults.standard.set(newValue.rawValue, forKey: meterLabelModeKey)
    }
  }

  static var meterWidth: CGFloat {
    CGFloat(value(for: .meterWidth))
  }

  static var meterStyle: MeterIconStyle {
    MeterIconStyle(
      width: meterWidth,
      fillMode: meterFillMode,
      direction: meterDirection,
      labelMode: meterLabelMode,
      codexColor: codexColor.nsColor,
      claudeColor: claudeColor.nsColor,
      antigravityColor: antigravityColor.nsColor,
      redlineColor: redlineColor.nsColor
    )
  }

  static var iconStyle: GaugeIconStyle {
    GaugeIconStyle(
      fableStarSize: CGFloat(value(for: .fableStarSize)),
      fableStarRadius: CGFloat(value(for: .fableStarRadius)),
      fastHandLength: CGFloat(value(for: .fastHandLength)),
      fastHandWidth: CGFloat(value(for: .fastHandWidth)),
      fastHandRadius: CGFloat(value(for: .fastHandRadius)),
      weeklyHandLength: CGFloat(value(for: .weeklyHandLength)),
      weeklyHandWidth: CGFloat(value(for: .weeklyHandWidth)),
      weeklyHandRadius: CGFloat(value(for: .weeklyHandRadius)),
      scaleDotSize: CGFloat(value(for: .scaleDotSize)),
      scaleRadius: CGFloat(value(for: .scaleRadius)),
      redlineWidth: CGFloat(value(for: .redlineWidth)),
      hubSize: CGFloat(value(for: .hubSize)),
      codexColor: codexColor.nsColor,
      claudeColor: claudeColor.nsColor,
      antigravityColor: antigravityColor.nsColor,
      redlineColor: redlineColor.nsColor
    )
  }

  static func value(for setting: IconSliderSetting) -> Double {
    guard UserDefaults.standard.object(forKey: setting.rawValue) != nil else {
      return setting.defaultValue
    }
    let value = UserDefaults.standard.double(forKey: setting.rawValue)
    return clamped(value, to: setting.range)
  }

  static func setValue(_ value: Double, for setting: IconSliderSetting) {
    UserDefaults.standard.set(clamped(value, to: setting.range), forKey: setting.rawValue)
  }

  static var codexColor: GaugeColorChoice {
    get {
      color(forKey: codexColorKey, defaultValue: defaultCodexColor)
    }
    set {
      UserDefaults.standard.set(newValue.rawValue, forKey: codexColorKey)
    }
  }

  static var claudeColor: GaugeColorChoice {
    get {
      color(forKey: claudeColorKey, defaultValue: defaultClaudeColor)
    }
    set {
      UserDefaults.standard.set(newValue.rawValue, forKey: claudeColorKey)
    }
  }

  static var antigravityColor: GaugeColorChoice {
    get {
      color(forKey: antigravityColorKey, defaultValue: defaultAntigravityColor)
    }
    set {
      UserDefaults.standard.set(newValue.rawValue, forKey: antigravityColorKey)
    }
  }

  static var redlineColor: GaugeColorChoice {
    get {
      color(forKey: redlineColorKey, defaultValue: defaultRedlineColor)
    }
    set {
      UserDefaults.standard.set(newValue.rawValue, forKey: redlineColorKey)
    }
  }

  static func colorChoice(for provider: Provider) -> GaugeColorChoice {
    switch provider {
    case .codex: codexColor
    case .claude: claudeColor
    case .antigravity: antigravityColor
    }
  }

  static func setColorChoice(_ choice: GaugeColorChoice, for provider: Provider) {
    switch provider {
    case .codex: codexColor = choice
    case .claude: claudeColor = choice
    case .antigravity: antigravityColor = choice
    }
  }

  // MARK: - Provider Display Order

  private static let providerOrderKey = "providerOrder"

  static var providerOrder: [Provider] {
    get {
      guard let rawList = UserDefaults.standard.stringArray(forKey: providerOrderKey) else {
        return [.codex, .claude, .antigravity]
      }
      var ordered = rawList.compactMap { Provider(rawValue: $0) }
      for provider in Provider.allCases where !ordered.contains(provider) {
        ordered.append(provider)
      }
      return ordered
    }
    set {
      UserDefaults.standard.set(newValue.map(\.rawValue), forKey: providerOrderKey)
    }
  }

  static func moveProvider(_ provider: Provider, up: Bool) {
    var order = providerOrder
    guard let currentIndex = order.firstIndex(of: provider) else { return }
    let targetIndex = up ? currentIndex - 1 : currentIndex + 1
    guard targetIndex >= 0 && targetIndex < order.count else { return }
    order.swapAt(currentIndex, targetIndex)
    providerOrder = order
  }

  static func resetIconStyle() {
    for setting in IconSliderSetting.allCases {
      UserDefaults.standard.removeObject(forKey: setting.rawValue)
    }
    for key in [
      providerOrderKey,
      codexColorKey,
      claudeColorKey,
      antigravityColorKey,
      redlineColorKey,
      displayModeKey,
      meterFillModeKey,
      meterDirectionKey,
      meterLabelModeKey,
      legacyCodexMeterLabelKey,
      legacyClaudeMeterLabelKey,
      legacyAntigravityMeterLabelKey,
      legacyFableStarScaleKey,
      legacyHandScaleKey,
      legacyScaleDotScaleKey,
      legacyHubScaleKey
    ] {
      UserDefaults.standard.removeObject(forKey: key)
    }
  }

  private static func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
    min(range.upperBound, max(range.lowerBound, value))
  }

  private static func color(forKey key: String, defaultValue: GaugeColorChoice) -> GaugeColorChoice {
    guard
      let raw = UserDefaults.standard.string(forKey: key),
      let color = GaugeColorChoice(rawValue: raw)
    else {
      return defaultValue
    }
    return color
  }
}

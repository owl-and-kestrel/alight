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
  private static let legacyFableStarScaleKey = "fableStarScale"
  private static let legacyHandScaleKey = "handScale"
  private static let legacyScaleDotScaleKey = "scaleDotScale"
  private static let legacyHubScaleKey = "hubScale"

  static let defaultCodexColor = GaugeColorChoice.teal
  static let defaultClaudeColor = GaugeColorChoice.coral
  static let defaultAntigravityColor = GaugeColorChoice.purple
  static let defaultRedlineColor = GaugeColorChoice.red

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

  static func resetIconStyle() {
    for setting in IconSliderSetting.allCases {
      UserDefaults.standard.removeObject(forKey: setting.rawValue)
    }
    for key in [
      codexColorKey,
      claudeColorKey,
      antigravityColorKey,
      redlineColorKey,
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

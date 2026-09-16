import AppKit

@MainActor
final class SettingsSliderRow: NSView {
  private let valueLabel: NSTextField
  private let slider: NSSlider
  private let onChange: @MainActor (Double) -> Void

  init(setting: IconSliderSetting, value: Double, onChange: @escaping @MainActor (Double) -> Void) {
    self.onChange = onChange
    valueLabel = NSTextField(labelWithString: SettingsSliderRow.format(value))
    slider = NSSlider(value: value, minValue: setting.range.lowerBound, maxValue: setting.range.upperBound, target: nil, action: nil)
    super.init(frame: NSRect(x: 0, y: 0, width: 286, height: 46))

    let titleLabel = NSTextField(labelWithString: setting.menuTitle)
    titleLabel.font = .systemFont(ofSize: 12)
    titleLabel.textColor = .labelColor
    titleLabel.frame = NSRect(x: 14, y: 25, width: 188, height: 16)
    addSubview(titleLabel)

    valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    valueLabel.alignment = .right
    valueLabel.textColor = .secondaryLabelColor
    valueLabel.frame = NSRect(x: 206, y: 25, width: 66, height: 16)
    addSubview(valueLabel)

    slider.frame = NSRect(x: 12, y: 5, width: 262, height: 18)
    slider.isContinuous = true
    slider.target = self
    slider.action = #selector(sliderChanged(_:))
    addSubview(slider)
  }

  required init?(coder: NSCoder) {
    nil
  }

  @objc private func sliderChanged(_ sender: NSSlider) {
    let value = sender.doubleValue
    valueLabel.stringValue = Self.format(value)
    onChange(value)
  }

  private static func format(_ value: Double) -> String {
    String(format: "%.2f pt", value)
  }
}

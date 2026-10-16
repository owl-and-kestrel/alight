import AppKit

@MainActor
final class SettingsSliderRow: NSView {
  private let titleLabel: NSTextField
  private let valueLabel: NSTextField
  private let slider: NSSlider
  private let onChange: @MainActor (Double) -> Void
  private let rowWidth: CGFloat

  init(
    setting: IconSliderSetting,
    value: Double,
    width: CGFloat = 380,
    onChange: @escaping @MainActor (Double) -> Void
  ) {
    self.onChange = onChange
    self.rowWidth = width
    valueLabel = NSTextField(labelWithString: SettingsSliderRow.format(value))
    slider = NSSlider(value: value, minValue: setting.range.lowerBound, maxValue: setting.range.upperBound, target: nil, action: nil)
    titleLabel = NSTextField(labelWithString: setting.menuTitle)
    super.init(frame: NSRect(x: 0, y: 0, width: width, height: 46))

    titleLabel.font = .systemFont(ofSize: 12)
    titleLabel.textColor = .labelColor
    addSubview(titleLabel)

    valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    valueLabel.alignment = .right
    valueLabel.textColor = .secondaryLabelColor
    addSubview(valueLabel)

    // The label and value bookend the full row so the pair reads centred in
    // the tab instead of hugging its left edge.
    let valueWidth: CGFloat = 72
    titleLabel.frame = NSRect(x: 14, y: 25, width: width - 14 - valueWidth - 14, height: 16)
    valueLabel.frame = NSRect(x: width - valueWidth - 14, y: 25, width: valueWidth, height: 16)

    slider.frame = NSRect(x: 12, y: 5, width: width - 24, height: 18)
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

import Charts
import SwiftUI

/// One provider card: a header, then the card's enabled elements in order.
struct ProviderCardView: View {
  let card: DashboardCard
  let result: ProviderResult?
  let history: UsageHistory
  let color: Color
  let now: Date
  var onSignIn: () -> Void = {}
  var onCustomize: () -> Void = {}
  var onRemove: () -> Void = {}
  /// Moves the card one slot (-1 up, +1 down); nil hides the move commands.
  var onMove: ((Int) -> Void)? = nil
  var canMove: (up: Bool, down: Bool) = (false, false)
  /// Dragging the header reports the vertical translation, then the end;
  /// nil makes the header inert (the Customize preview).
  var onReorderChanged: ((CGFloat) -> Void)? = nil
  var onReorderEnded: (() -> Void)? = nil

  @State private var isReordering = false

  private var windows: [UsageWindow] {
    (result?.windows ?? []).filter { !card.hiddenWindowIDs.contains($0.id) }.sorted(by: DashboardCard.displayOrder)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      if windows.isEmpty {
        emptyState
      } else {
        ForEach(card.visibleElements, id: \.self) { element in
          switch element {
          case .meters: meters
          case .history: historyChart
          case .forecast: forecast
          }
        }
      }
    }
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.045))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.07))
    )
    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .contextMenu {
      Button("Customize…", action: onCustomize)
      if result?.needsAuth == true { Button("Sign In to \(card.provider.displayName)…", action: onSignIn) }
      moveCommands
      Divider()
      Button("Remove Card", role: .destructive, action: onRemove)
    }
  }

  @ViewBuilder private var moveCommands: some View {
    if let onMove {
      Divider()
      Button("Move Up") { onMove(-1) }.disabled(!canMove.up)
      Button("Move Down") { onMove(1) }.disabled(!canMove.down)
    }
  }

  // MARK: Header

  private var header: some View {
    HStack(spacing: 8) {
      Circle().fill(color).frame(width: 9, height: 9)
      Text(card.provider.displayName).font(.headline)
      Spacer(minLength: 8)
      statusBadge
      Menu {
        Button("Customize…", action: onCustomize)
        moveCommands
        Divider()
        Button("Remove Card", role: .destructive, action: onRemove)
      } label: {
        Image(systemName: "ellipsis").frame(width: 18, height: 18)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .foregroundStyle(.secondary)
    }
    .contentShape(Rectangle())
    .modifier(ReorderHandle(
      isEnabled: onReorderChanged != nil,
      isReordering: $isReordering,
      onChanged: { onReorderChanged?($0) },
      onEnded: { onReorderEnded?() }
    ))
  }

  @ViewBuilder private var statusBadge: some View {
    if let result {
      if result.needsAuth {
        Button("Sign In", action: onSignIn).controlSize(.small).buttonStyle(.borderedProminent).tint(color)
      } else if result.source == "cached" {
        Label(result.sourceLabel.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Cached", systemImage: "clock.arrow.circlepath")
          .font(.caption).foregroundStyle(.secondary).help(result.error ?? "Showing the last live reading")
      } else if result.ok {
        Label("Live", systemImage: "dot.radiowaves.left.and.right")
          .font(.caption).foregroundStyle(.secondary).labelStyle(.titleOnly)
      } else {
        Label("Offline", systemImage: "exclamationmark.triangle")
          .font(.caption).foregroundStyle(.secondary).help(result.error ?? "")
      }
    } else {
      ProgressView().controlSize(.mini)
    }
  }

  private var emptyState: some View {
    Text(result?.error ?? (result == nil ? "Checking usage…" : "No limits reported."))
      .font(.callout)
      .foregroundStyle(.secondary)
      .lineLimit(3)
      .fixedSize(horizontal: false, vertical: true)
  }

  // MARK: Meters

  private var meters: some View {
    VStack(spacing: 12) {
      ForEach(windows) { window in
        MeterRow(
          window: window,
          style: card.valueStyle,
          color: color,
          showsPaceMarker: card.showsPaceMarker,
          showsCountdown: card.showsCountdown,
          now: now
        )
      }
    }
  }

  // MARK: History

  @ViewBuilder private var historyChart: some View {
    let data = HistoryChartData.make(
      observations: history.observations,
      windows: windows,
      range: card.historyRange,
      style: card.valueStyle,
      now: now
    )
    if data.isEmpty {
      Text("No live history in the last \(card.historyRange.title) yet.")
        .font(.caption).foregroundStyle(.secondary)
    } else {
      HistoryChartView(data: data, windows: windows, color: color, style: card.valueStyle, showsPaceGuide: card.showsPaceGuide)
    }
  }

  // MARK: Forecast

  private var forecast: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(windows) { window in
        let forecast = UsageForecast(
          window: window, identity: result?.observationIdentity, observations: history.observations, now: now
        )
        HStack(alignment: .firstTextBaseline) {
          Text(window.label).font(.caption.weight(.medium))
          Spacer()
          RunwayText(forecast: forecast, now: now)
        }
      }
    }
  }
}

/// Makes a card's header its drag handle: an open hand on hover, a closed
/// hand while dragging, and the vertical translation reported as it moves.
/// Clicks on the header's buttons still go to them (a drag needs movement).
private struct ReorderHandle: ViewModifier {
  let isEnabled: Bool
  @Binding var isReordering: Bool
  let onChanged: (CGFloat) -> Void
  let onEnded: () -> Void

  func body(content: Content) -> some View {
    if isEnabled {
      content
        .onHover { inside in
          guard !isReordering else { return }
          (inside ? NSCursor.openHand : NSCursor.arrow).set()
        }
        .gesture(
          DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
              if !isReordering {
                isReordering = true
                NSCursor.closedHand.set()
              }
              onChanged(value.translation.height)
            }
            .onEnded { _ in
              isReordering = false
              NSCursor.openHand.set()
              onEnded()
            }
        )
        .help("Drag to reorder")
    } else {
      content
    }
  }
}

/// Label, big number, bar with pace marker, then pace and reset details.
struct MeterRow: View {
  let window: UsageWindow
  let style: CardValueStyle
  let color: Color
  let showsPaceMarker: Bool
  let showsCountdown: Bool
  let now: Date

  private var value: Double { style.value(usedPercent: window.usedPercent) }
  private var paceValue: Double { style.value(usedPercent: 100 - window.expectedRemainingPercent) }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 4) {
        Text(window.label).font(.subheadline.weight(.medium))
        Spacer()
        Text("\(Int(value.rounded()))%")
          .font(.system(.title3, design: .rounded).weight(.semibold))
          .monospacedDigit()
          .contentTransition(.numericText(value: value))
        Text(style == .remaining ? "left" : "used").font(.caption).foregroundStyle(.secondary)
      }
      MeterBar(fraction: value / 100, pace: showsPaceMarker ? paceValue / 100 : nil, color: color)
      if showsPaceMarker || showsCountdown {
        HStack(spacing: 6) {
          if showsPaceMarker { PaceLabel(window: window) }
          Spacer(minLength: 4)
          if showsCountdown {
            Text("resets in \(window.resetCountdown(now: now))")
              .help(window.resetAt.formatted(.dateTime.weekday(.wide).hour().minute()))
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .animation(.smooth, value: value)
  }
}

/// A rounded track, the provider-colored value, and a tick where the value
/// would be if usage were exactly on pace.
struct MeterBar: View {
  let fraction: Double
  let pace: Double?
  let color: Color

  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      ZStack(alignment: .leading) {
        Capsule().fill(Color.primary.opacity(0.09))
        Capsule()
          .fill(color.gradient)
          .frame(width: max(proxy.size.height, width * clamp(fraction)))
          .opacity(fraction > 0.004 ? 1 : 0)
        if let pace {
          RoundedRectangle(cornerRadius: 1.5)
            .fill(Color.primary)
            .frame(width: 3, height: proxy.size.height + 6)
            .overlay(RoundedRectangle(cornerRadius: 1.5).stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
            .offset(x: min(width - 3, max(0, width * clamp(pace) - 1.5)))
        }
      }
    }
    .frame(height: 8)
    .padding(.vertical, 3)
    .accessibilityElement()
    .accessibilityValue("\(Int((clamp(fraction) * 100).rounded())) percent")
  }

  private func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
}

/// Pace as words plus a status glyph, never color alone.
struct PaceLabel: View {
  let window: UsageWindow

  var body: some View {
    let points = Int(abs(window.pressurePercent).rounded())
    HStack(spacing: 4) {
      Image(systemName: symbol).foregroundStyle(tint).imageScale(.small)
      switch window.band {
      case .high: Text("\(points)% to spare")
      case .low: Text("\(points)% over pace")
      case .good, .unknown: Text("on pace")
      }
    }
  }

  private var symbol: String {
    switch window.band {
    case .high: "tortoise.fill"
    case .low: "hare.fill"
    case .good, .unknown: "checkmark.circle.fill"
    }
  }

  private var tint: Color {
    switch window.band {
    case .high: .blue
    case .low: .red
    case .good, .unknown: .green
    }
  }
}

struct RunwayText: View {
  let forecast: UsageForecast
  let now: Date

  var body: some View {
    Group {
      if let zero = forecast.timeToZero {
        Label(
          zero <= now ? "Out now" : "Runs out \(zero.formatted(.dateTime.weekday(.abbreviated).hour().minute()))",
          systemImage: "exclamationmark.triangle.fill"
        )
        .foregroundStyle(.primary)
      } else if let projection = forecast.projection(at: forecast.window.resetAt) {
        Text("≈\(Int(projection.remainingPercent.rounded()))% left at reset")
      } else if let reason = forecast.unavailable {
        Text(Self.shortReason(reason)).help(reason.guidance)
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  static func shortReason(_ reason: UsageForecastUnavailable) -> String {
    switch reason {
    case .accountUnknown: "account unverified"
    case .insufficientCoverage: "collecting readings"
    case .stale: "reading is stale"
    case .clockChanged: "clock changed"
    case .windowChanged: "limit changed"
    case .noConsumption: "no recent use"
    case .expired: "reset; refresh"
    }
  }
}

/// Smooth (monotone, so it never overshoots a reading) lines per limit, a soft
/// area under the card's first limit, a dashed on-pace guide, and a hover
/// crosshair with each limit's reading.
struct HistoryChartView: View {
  let data: HistoryChartData
  let windows: [UsageWindow]
  let color: Color
  let style: CardValueStyle
  let showsPaceGuide: Bool

  @State private var selection: Date?

  private var labels: [String] { windows.map(\.label) }
  private var shades: [Color] {
    windows.indices.map { index in color.opacity([1, 0.62, 0.4, 0.28][min(index, 3)]) }
  }
  private var primaryID: String? { windows.first?.id }

  private var hourStride: Int {
    switch data.domain.lowerBound.distance(to: data.domain.upperBound) {
    case ...(6 * 3600): 2
    case ...(24 * 3600): 6
    default: 24
    }
  }

  private func label(for windowID: String) -> String {
    windows.first { $0.id == windowID }?.label ?? windowID
  }

  var body: some View {
    let seriesSizes = Dictionary(grouping: data.points, by: \.series).mapValues(\.count)
    let areaSizes = Dictionary(grouping: data.points, by: \.area).mapValues(\.count)
    let latest = Dictionary(grouping: data.points, by: \.windowID).compactMapValues { $0.max { $0.date < $1.date } }

    Chart {
      if showsPaceGuide {
        // Only the first limit's guide: one per expired short window clutters.
        ForEach(data.guides.filter { $0.windowID == primaryID }) { guide in
          ForEach([guide.start, guide.end]) { point in
            LineMark(
              x: .value("Time", point.date),
              y: .value("Percent", point.value),
              series: .value("Series", point.series)
            )
            .foregroundStyle(Color.secondary.opacity(0.55))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
          }
        }
      }

      ForEach(data.points.filter { $0.windowID == primaryID && areaSizes[$0.area, default: 0] > 1 }) { point in
        AreaMark(
          x: .value("Time", point.date),
          yStart: .value("Base", 0),
          yEnd: .value("Percent", point.value),
          series: .value("Series", point.area)
        )
        .interpolationMethod(.monotone)
        .foregroundStyle(
          LinearGradient(colors: [color.opacity(0.32), color.opacity(0.02)], startPoint: .top, endPoint: .bottom)
        )
      }

      ForEach(data.points) { point in
        LineMark(
          x: .value("Time", point.date),
          y: .value("Percent", point.value),
          series: .value("Series", point.series)
        )
        .interpolationMethod(.monotone)
        .foregroundStyle(by: .value("Limit", label(for: point.windowID)))
        .lineStyle(StrokeStyle(lineWidth: point.windowID == primaryID ? 2 : 1.5, lineCap: .round, lineJoin: .round))

        // A reading that joins no line (an unverified account, or isolated
        // by a gap) is a faint dot rather than a mark of its own weight.
        if seriesSizes[point.series] == 1 {
          PointMark(x: .value("Time", point.date), y: .value("Percent", point.value))
            .foregroundStyle(by: .value("Limit", label(for: point.windowID)))
            .symbolSize(6)
            .opacity(0.45)
        }
      }

      ForEach(Array(latest.values)) { point in
        PointMark(x: .value("Time", point.date), y: .value("Percent", point.value))
          .foregroundStyle(by: .value("Limit", label(for: point.windowID)))
          .symbolSize(36)
          .annotation(position: .trailing, alignment: .center, spacing: 4) {
            if windows.count > 1 {
              Text(label(for: point.windowID)).font(.caption2).foregroundStyle(Color.secondary)
            }
          }
      }

      if let selection {
        RuleMark(x: .value("Selected", selection))
          .foregroundStyle(Color.primary.opacity(0.25))
          .lineStyle(StrokeStyle(lineWidth: 1))
          .annotation(position: .top, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
            readout(at: selection)
          }
      }
    }
    .chartForegroundStyleScale(domain: labels, range: shades)
    .chartXScale(domain: data.domain)
    .chartYScale(domain: 0...100)
    .chartYAxis {
      AxisMarks(position: .leading, values: [0, 50, 100]) { value in
        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3])).foregroundStyle(Color.primary.opacity(0.12))
        AxisValueLabel { if let percent = value.as(Int.self) { Text("\(percent)%") } }
          .font(.caption2).foregroundStyle(Color.secondary)
      }
    }
    .chartXAxis {
      AxisMarks(values: .stride(by: .hour, count: hourStride)) { _ in
        AxisTick(length: 3).foregroundStyle(Color.primary.opacity(0.2))
        AxisValueLabel(format: .dateTime.hour(), collisionResolution: .greedy(minimumSpacing: 6))
          .font(.caption2).foregroundStyle(Color.secondary)
      }
    }
    .chartLegend(windows.count > 1 ? .visible : .hidden)
    .chartLegend(position: .top, alignment: .leading, spacing: 6)
    .chartXSelection(value: $selection)
    .chartPlotStyle { $0.padding(.trailing, windows.count > 1 ? 34 : 4) }
    .frame(height: 128)
    .accessibilityLabel("\(style.title) percentage over the last \(data.domain.lowerBound.distance(to: data.domain.upperBound) / 3600) hours")
  }

  private func readout(at date: Date) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(date.formatted(.dateTime.weekday(.abbreviated).hour().minute())).font(.caption2).foregroundStyle(Color.secondary)
      ForEach(data.nearest(to: date)) { point in
        HStack(spacing: 4) {
          Text(label(for: point.windowID))
          Text("\(Int(point.value.rounded()))%").monospacedDigit().fontWeight(.semibold)
        }
        .font(.caption)
      }
    }
    .padding(.horizontal, 7)
    .padding(.vertical, 5)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
  }
}

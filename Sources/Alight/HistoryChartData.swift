import Foundation

/// Chart-ready history for one card, derived from `UsageHistory` observations.
/// Pure so it can be tested; the view only draws what this returns.
struct HistoryChartData: Equatable, Sendable {
  struct Point: Equatable, Identifiable, Sendable {
    /// One continuous line: a window's uninterrupted segment.
    let series: String
    let windowID: String
    let date: Date
    let value: Double
    var id: String { "\(series)@\(date.timeIntervalSince1970)" }
  }

  /// Where usage would be if it ran exactly on pace through a quota window.
  struct PaceGuide: Equatable, Identifiable, Sendable {
    let windowID: String
    let start: Point
    let end: Point
    var id: String { start.series }
  }

  let domain: ClosedRange<Date>
  let points: [Point]
  let guides: [PaceGuide]

  var isEmpty: Bool { points.isEmpty }

  /// Builds the series for `windows` over `range` ending at `now`. At most
  /// `bucketCount` points per series survive: within a segment usage only
  /// rises, so each time bucket keeps its last reading and the line keeps its
  /// shape. Observations without a verified account stay isolated points.
  static func make(
    observations: [UsageObservation],
    windows: [UsageWindow],
    range: HistoryRange,
    style: CardValueStyle,
    now: Date,
    bucketCount: Int = 144
  ) -> HistoryChartData {
    let domain = now.addingTimeInterval(-range.seconds)...now
    let bucketWidth = range.seconds / Double(max(1, bucketCount))
    let wanted = Set(windows.map(\.id))

    var bySegment: [UUID: [UsageObservation]] = [:]
    var segmentOrder: [UUID] = []
    for observation in observations
    where wanted.contains(observation.window.id) && domain.contains(observation.capturedAt) {
      if bySegment[observation.segment] == nil { segmentOrder.append(observation.segment) }
      bySegment[observation.segment, default: []].append(observation)
    }

    var points: [Point] = []
    var guides: [PaceGuide] = []
    var guidedWindows = Set<String>()
    for segment in segmentOrder {
      let readings = (bySegment[segment] ?? []).sorted { $0.capturedAt < $1.capturedAt }
      guard let first = readings.first else { continue }
      let windowID = first.window.id
      // Unverified readings never join a line: each is its own series.
      let series = first.identity == nil ? nil : "\(windowID)#\(segment.uuidString)"

      // The segment's first reading always stays, so the line starts where
      // the segment does.
      var lastBucket: Int?
      var kept: [UsageObservation] = []
      for reading in readings {
        let bucket = Int(reading.capturedAt.timeIntervalSince(domain.lowerBound) / bucketWidth)
        if bucket == lastBucket, series != nil, kept.count > 1 { kept[kept.count - 1] = reading } else { kept.append(reading) }
        lastBucket = bucket
      }

      for reading in kept {
        points.append(Point(
          series: series ?? "\(windowID)#\(reading.id.uuidString)",
          windowID: windowID,
          date: reading.capturedAt,
          value: style.value(usedPercent: reading.window.usedPercent)
        ))
      }

      // One guide per quota window (its reset), clipped to the domain.
      let window = first.window
      let guideKey = "\(windowID)@\(window.resetAt.timeIntervalSince1970)"
      if guidedWindows.insert(guideKey).inserted,
        let guide = paceGuide(window: window, key: guideKey, domain: domain, style: style) {
        guides.append(guide)
      }
    }
    return HistoryChartData(domain: domain, points: points, guides: guides)
  }

  static func paceGuide(window: UsageWindow, key: String, domain: ClosedRange<Date>, style: CardValueStyle) -> PaceGuide? {
    let windowStart = window.resetAt.addingTimeInterval(-window.limitWindowSeconds)
    let start = max(windowStart, domain.lowerBound)
    let end = min(window.resetAt, domain.upperBound)
    guard start < end else { return nil }
    func point(_ date: Date) -> Point {
      let used = min(100, max(0, date.timeIntervalSince(windowStart) / window.limitWindowSeconds * 100))
      return Point(series: "pace:\(key)", windowID: window.id, date: date, value: style.value(usedPercent: used))
    }
    return PaceGuide(windowID: window.id, start: point(start), end: point(end))
  }

  /// The reading in each window's series nearest to `date`, for the hover readout.
  func nearest(to date: Date) -> [Point] {
    Dictionary(grouping: points, by: \.windowID).compactMap { _, windowPoints in
      windowPoints.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }
    .sorted { $0.windowID < $1.windowID }
  }
}

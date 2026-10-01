import SwiftUI
import Charts

/// Reusable presentation of the canonical store. Its host must pass the same
/// UsageStore used by the gauge; opening this view never starts another poller.
@MainActor
struct UsageInsightsView: View {
  @Bindable var store: UsageStore

  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { context in
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          Text("Usage history & runway").font(.largeTitle.bold())
          Text("Local live observations · percentages of each provider’s current allowance")
            .foregroundStyle(.secondary)
          if let issue = store.history.persistenceIssue {
            Label(issue, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
          }
          if store.status.windows.isEmpty {
            Text("No quota windows are available. Use the existing menu’s Refresh or provider sign-in action to obtain a live reading.")
          }
          ForEach(store.status.windows) { window in
            windowCard(window, now: context.date)
          }
          Text("Projections assume recent consumption continues. Changes in workload or an unreported plan allowance can invalidate them. Quota overrun is projected demand in percentage points, never billed overage or money.")
            .font(.caption).foregroundStyle(.secondary)
        }.padding(24)
      }
    }.frame(minWidth: 620, minHeight: 480)
  }

  private func windowCard(_ window: UsageWindow, now: Date) -> some View {
    let result = store.status.result(for: window.provider)
    let points = store.history.points(for: window).filter { $0.capturedAt >= now.addingTimeInterval(-24 * 3600) && $0.capturedAt <= now }
    let forecast = UsageForecast(window: window, identity: result?.observationIdentity, observations: store.history.observations, now: now)
    return VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(window.qualifiedLabel).font(.title2.bold())
        Spacer()
        Text("\(window.remainingDisplay) remaining").font(.title3.monospacedDigit())
      }
      Text("Reset: \(window.resetDescription(now: now))").foregroundStyle(.secondary)
      if let source = result?.sourceLabel { Text(source).font(.caption).foregroundStyle(.secondary) }
      if let latest = forecast.latestCapturedAt {
        Text("Last live observation: \(latest.formatted(.dateTime.hour().minute())) · \(ProviderResult.compactDuration(max(0, now.timeIntervalSince(latest)))) ago")
          .font(.caption).foregroundStyle(.secondary)
      }
      if points.isEmpty {
        Text("No live history yet. Cached refreshes do not create observations.").foregroundStyle(.secondary)
      } else {
        Chart(points) { point in
          // Separate series prevent lines across accounts, resets, decreases,
          // gaps, sources, or reported limit changes. Unknown accounts get dots.
          if point.identity != nil {
            LineMark(x: .value("Observed", point.capturedAt), y: .value("Used %", point.window.usedPercent), series: .value("Continuity", point.segment.uuidString))
          }
          PointMark(x: .value("Observed", point.capturedAt), y: .value("Used %", point.window.usedPercent))
        }
        .chartYScale(domain: 0...100)
        .chartYAxisLabel("Allowance used (%)")
        .chartLegend(.hidden)
        .frame(height: 180)
        Text("Past 24 hours · \(points.count) live observations. Disconnected points and lines belong to separate quota or account segments.")
          .font(.caption).foregroundStyle(.secondary)
      }
      if let sustainable = forecast.sustainablePointsPerHour {
        metric("Sustainable pace to reset", value: "\(number(sustainable)) percentage points/hour")
      }
      if let reason = forecast.unavailable {
        Text(reason.guidance).foregroundStyle(.secondary)
      } else if let rate = forecast.ratePointsPerHour {
        metric("Recent consumption", value: "≈\(number(rate)) percentage points/hour")
        Text("\(forecast.readingCount) readings over \(ProviderResult.compactDuration(forecast.coverageSeconds)); estimates assume this recent pace continues.")
          .font(.caption).foregroundStyle(.secondary)
        if let range = forecast.rateRange {
          Text("Observed interval rates: \(number(range.lowerBound))–\(number(range.upperBound)) points/hour (variation, not a confidence interval).")
            .font(.caption).foregroundStyle(.secondary)
        }
        if let zero = forecast.timeToZero {
          metric("Allowance reaches zero", value: zero <= now ? "Projected already exhausted" : zero.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
        } else {
          metric("Allowance reaches zero", value: "Not projected before this reset")
        }
        if let projection = forecast.projection(at: window.resetAt) {
          metric("Projected at reset", value: projectionText(projection))
        }
        if let weekEnd = Calendar.current.dateInterval(of: .weekOfYear, for: now)?.end {
          if let projection = forecast.projection(at: weekEnd) {
            metric("Projected at calendar week end", value: projectionText(projection))
          } else {
            Text("Calendar week end crosses this quota reset; a projection beyond the reset is unavailable.")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
      }
    }
    .padding(18)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
  }

  private func metric(_ title: String, value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title).foregroundStyle(.secondary)
      Spacer()
      Text(value).monospacedDigit()
    }
  }

  private func number(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(1))) }
  private func projectionText(_ projection: UsageProjection) -> String {
    projection.quotaOverrunPoints > 0
      ? "≈\(number(projection.quotaOverrunPoints)) points over allowance"
      : "≈\(number(projection.remainingPercent))% remaining"
  }
}

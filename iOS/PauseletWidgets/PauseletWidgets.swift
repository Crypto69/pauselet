import WidgetKit
import SwiftUI
#if canImport(AlarmKit)
import AlarmKit
#endif

@main
struct PauseletWidgetBundle: WidgetBundle {
    var body: some Widget {
        #if canImport(AlarmKit)
        PauseletAlarmLiveActivity()
        #endif
    }
}

#if canImport(AlarmKit)
/// The Live Activity AlarmKit requires for its countdown, paused, and alert
/// states — this is what appears on the Lock Screen, in the Dynamic Island,
/// and in StandBy while a Pauselet alarm is running or sounding.
///
/// Every countdown clamps its range to "now": the switch to the alert state
/// reaches this process asynchronously, so a stale countdown can be rendered
/// at or just past the fire moment, and a range whose upper bound is in the
/// past traps — crashing the widget at exactly the moment that matters.
struct PauseletAlarmLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(
            for: AlarmAttributes<PauseletAlarmMetadata>.self
        ) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(Color(red: 0.04, green: 0.09, blue: 0.11))
                .activitySystemActionForegroundColor(context.attributes.tintColor)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.attributes.metadata?.symbolName ?? "bell")
                        .font(.title2)
                        .foregroundStyle(context.attributes.tintColor)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.presentation.alert.title)
                            .font(.headline)
                            .lineLimit(1)
                        modeLine(context: context)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: context.attributes.metadata?.symbolName ?? "bell")
                    .foregroundStyle(context.attributes.tintColor)
            } compactTrailing: {
                compactTrailingView(context: context)
            } minimal: {
                Image(systemName: context.attributes.metadata?.symbolName ?? "bell")
                    .foregroundStyle(context.attributes.tintColor)
            }
        }
    }

    @ViewBuilder
    private func modeLine(
        context: ActivityViewContext<AlarmAttributes<PauseletAlarmMetadata>>
    ) -> some View {
        switch context.state.mode {
        case .countdown(let countdown):
            Text(timerInterval: Date.now...max(Date.now, countdown.fireDate), countsDown: true)
                .monospacedDigit()
        case .paused:
            Text("Paused")
        case .alert:
            Text("Now")
        @unknown default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func compactTrailingView(
        context: ActivityViewContext<AlarmAttributes<PauseletAlarmMetadata>>
    ) -> some View {
        switch context.state.mode {
        case .countdown(let countdown):
            Text(timerInterval: Date.now...max(Date.now, countdown.fireDate), countsDown: true)
                .monospacedDigit()
                .frame(maxWidth: 44)
        case .paused:
            Image(systemName: "pause.fill")
        case .alert:
            Image(systemName: "bell.and.waves.left.and.right.fill")
                .foregroundStyle(context.attributes.tintColor)
        @unknown default:
            EmptyView()
        }
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<AlarmAttributes<PauseletAlarmMetadata>>

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: context.attributes.metadata?.symbolName ?? "bell")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(context.attributes.tintColor)

            VStack(alignment: .leading, spacing: 3) {
                Text(context.attributes.presentation.alert.title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let message = context.attributes.metadata?.message, !message.isEmpty {
                    Text(message)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)

            trailing
        }
        .padding(16)
    }

    @ViewBuilder
    private var trailing: some View {
        switch context.state.mode {
        case .countdown(let countdown):
            Text(timerInterval: Date.now...max(Date.now, countdown.fireDate), countsDown: true)
                .font(.system(size: 24, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(maxWidth: 90)
        case .paused:
            Image(systemName: "pause.circle")
                .font(.system(size: 24))
                .foregroundStyle(.white.opacity(0.7))
        case .alert:
            Image(systemName: "bell.and.waves.left.and.right.fill")
                .font(.system(size: 24))
                .foregroundStyle(context.attributes.tintColor)
        @unknown default:
            EmptyView()
        }
    }
}
#endif

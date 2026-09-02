import SwiftUI
import ReminderCore

/// Common intervals as presets, with a custom escape hatch.
///
/// "Custom" is tracked as its own state rather than inferred from whether the
/// value happens to be a preset: inferring it made the option unreachable
/// (choosing Custom from a preset left the value on the preset, so the picker
/// snapped straight back), and it hid the stepper again the moment the user
/// stepped onto a preset value.
public struct IntervalPicker: View {
    @Binding private var minutes: Int
    @State private var isCustom: Bool

    private static let customTag = -1

    public init(minutes: Binding<Int>) {
        _minutes = minutes
        _isCustom = State(initialValue: !EditorCatalog.intervalPresets.contains(minutes.wrappedValue))
    }

    public var body: some View {
        Picker("Every", selection: Binding(
            get: { isCustom ? Self.customTag : minutes },
            set: { selected in
                if selected == Self.customTag {
                    isCustom = true
                } else {
                    isCustom = false
                    minutes = selected
                }
            }
        )) {
            ForEach(EditorCatalog.intervalPresets, id: \.self) { preset in
                Text(Schedule.humanDuration(minutes: preset)).tag(preset)
            }
            Text("Custom").tag(Self.customTag)
        }

        if isCustom {
            Stepper("Every \(minutes) min", value: $minutes, in: 1...1440, step: 5)
        }
    }
}

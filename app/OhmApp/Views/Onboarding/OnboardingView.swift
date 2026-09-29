import SwiftUI

public struct OnboardingView: View {
    public var onDismiss: () -> Void
    @State private var currentStep: Int = 0
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Dynamic Step Pane
            Group {
                switch currentStep {
                case 0:
                    paneView(
                        symbol: "gauge.with.needle",
                        tint: .accentColor,
                        title: OhmFormatters.localizedString("Real-time Apple Silicon Telemetry", locale: locale),
                        bodyText: OhmFormatters.localizedString("Onboarding.body1", locale: locale)
                    )
                case 1:
                    paneView(
                        symbol: "cpu",
                        tint: .blue,
                        title: OhmFormatters.localizedString("The Efficiency Core Lane", locale: locale),
                        bodyText: OhmFormatters.localizedString("Onboarding.body2", locale: locale)
                    )
                case 2:
                    paneView(
                        symbol: "snowflake.circle.fill",
                        tint: .cyan,
                        title: OhmFormatters.localizedString("Freeze Safety & Watcher Helper", locale: locale),
                        bodyText: OhmFormatters.localizedString("Onboarding.body3", locale: locale)
                    )
                default:
                    EmptyView()
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: currentStep)

            Spacer()

            // Bottom Navigation
            HStack {
                if currentStep > 0 {
                    Button(OhmFormatters.localizedString("Back", locale: locale)) {
                        currentStep -= 1
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .accessibilityLabel(OhmFormatters.localizedString("Go to previous step", locale: locale))
                } else {
                    Spacer().frame(width: 48)
                }

                Spacer()

                // Step Indicators
                HStack(spacing: 6) {
                    ForEach(0..<3) { idx in
                        Capsule()
                            .fill(idx == currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: idx == currentStep ? 16 : 6, height: 6)
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: currentStep)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(OhmFormatters.localizedFormat("Step %lld of 3", locale: locale, currentStep + 1))

                Spacer()

                if currentStep < 2 {
                    Button(OhmFormatters.localizedString("Next", locale: locale)) {
                        currentStep += 1
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .accessibilityLabel(OhmFormatters.localizedString("Go to next step", locale: locale))
                } else {
                    Button(OhmFormatters.localizedString("Get Started", locale: locale)) {
                        onDismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .accessibilityLabel(OhmFormatters.localizedString("Get Started with Ohm", locale: locale))
                }
            }
        }
        .padding(28)
        .frame(width: 480, height: 380)
        .background(.regularMaterial)
    }

    private func paneView(symbol: String, tint: Color, title: String, bodyText: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 52))
                .foregroundColor(tint)
                .frame(height: 64)

            Text(title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            Text(bodyText)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .frame(maxWidth: 400)
        }
    }
}

// MARK: - Previews

#Preview("Onboarding") {
    OnboardingView(onDismiss: {})
}

import SwiftUI
import OhmModel

public struct ClusterBarView: View {
    public let residency: ClusterResidency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(residency: ClusterResidency) {
        self.residency = residency
    }

    public var body: some View {
        HStack(spacing: 8) {
            clusterGroup(label: "P", ratio: residency.pActiveRatio, tint: .primary)
            clusterGroup(label: "E", ratio: residency.eActiveRatio, tint: .accentColor)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Performance cores at \(Int(residency.pActiveRatio * 100)) percent, Efficiency cores at \(Int(residency.eActiveRatio * 100)) percent"
        )
    }

    private func clusterGroup(label: String, ratio: Double, tint: Color) -> some View {
        HStack(spacing: 3) {
            // 5 segmented bars
            HStack(spacing: 1.5) {
                ForEach(0..<5) { index in
                    let threshold = Double(index) / 5.0
                    let isFilled = ratio > threshold
                    RoundedRectangle(cornerRadius: 1)
                        .fill(isFilled ? tint : Color.secondary.opacity(0.25))
                        .frame(width: 3, height: 9)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: ratio)
                }
            }

            Text(label)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.secondary)
        }
    }
}

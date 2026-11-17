import SwiftUI

/// Visualization only. Missing and unlimited quotas never become zero-use meters.
struct AccessUsageSummaryView: View {
    let usedBytes: String?
    let quotaBytes: String?
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("总用量").font(.subheadline).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(verbatim: AccessAccountUsagePresentation.formattedBytes(usedBytes))
                .font(.largeTitle.weight(.semibold)).monospacedDigit()
                .accessibilityLabel("总用量")
                .accessibilityValue(AccessAccountUsagePresentation.accessibleBytes(usedBytes, locale: locale))
                .accessibilityIdentifier("access-usage-used")
            if let fraction = AccessAccountUsagePresentation.usedFraction(used: usedBytes, quota: quotaBytes) {
                ProgressView(value: fraction)
                    .accessibilityLabel("总用量")
                    .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
                    .accessibilityIdentifier("access-usage-progress")
            }
        }
        .padding(.vertical, 6)
    }
}

struct AccessTransferBreakdown: View {
    let uploaded: String?
    let downloaded: String?
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.locale) private var locale

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        layout {
            metric("上传", icon: "arrow.up", bytes: uploaded, id: "uploaded")
            metric("下载", icon: "arrow.down", bytes: downloaded, id: "downloaded")
        }
        .padding(.vertical, 6)
    }

    private func metric(_ title: LocalizedStringKey, icon: String, bytes: String?, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: AccessAccountUsagePresentation.formattedBytes(bytes))
                .font(.body.weight(.medium)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityIdentifier("access-usage-" + id)
        .accessibilityValue(AccessAccountUsagePresentation.accessibleBytes(bytes, locale: locale))
    }
}

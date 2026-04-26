import SwiftUI
import AppKit

/// Compact CI / status-checks panel for `PRDetailView`. Failed checks
/// surface at the top; pending and passed checks collapse under a
/// disclosure so the section stays small when everything is green.
/// Clicking a row opens the check's `detailsUrl` / `targetUrl` in the
/// browser when available.
struct CIStatusView: View {
    let checks: [CheckSummary]

    @State private var showAll = false

    var body: some View {
        if checks.isEmpty {
            EmptyView()
        } else if failed.isEmpty {
            // All-green / all-pending case: no separate header — the
            // DisclosureGroup *is* the header. Tapping the whole row
            // expands. One concise summary, e.g. "CI: all green · 6
            // passed" instead of two stacked lines.
            DisclosureGroup(isExpanded: $showAll) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(nonFailed, id: \.self) { check in row(check) }
                }
                .padding(.top, 4)
            } label: {
                cleanHeaderLabel
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showAll.toggle()
                        }
                    }
            }
        } else {
            // Failures present: pin them at top under a red shield
            // header, collapse pending+passed under a separate
            // disclosure below.
            VStack(alignment: .leading, spacing: 6) {
                failedHeader
                ForEach(failed, id: \.self) { check in row(check) }

                if !nonFailed.isEmpty {
                    DisclosureGroup(isExpanded: $showAll) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(nonFailed, id: \.self) { check in row(check) }
                        }
                        .padding(.top, 4)
                    } label: {
                        let pending = checks.filter { $0.bucket == .pending }.count
                        let passed = checks.filter { $0.bucket == .passed }.count
                        Text(disclosureLabel(pending: pending, passed: passed))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    showAll.toggle()
                                }
                            }
                    }
                }
            }
        }
    }

    /// Combined header used when there are no failures: green shield +
    /// status verb + count summary on one line.
    private var cleanHeaderLabel: some View {
        let pending = checks.filter { $0.bucket == .pending }.count
        let passed = checks.filter { $0.bucket == .passed }.count
        return HStack(spacing: 6) {
            Image(systemName: pending > 0 ? "clock" : "checkmark.shield")
                .foregroundStyle(pending > 0 ? .yellow : .green)
                .font(.caption)
            Text(combinedCleanLabel(pending: pending, passed: passed))
                .font(.caption.bold())
        }
    }

    private var failedHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.red)
                .font(.caption)
            Text("CI: \(failed.count) failed")
                .font(.caption.bold())
            Spacer()
        }
    }

    private func combinedCleanLabel(pending: Int, passed: Int) -> String {
        // Mirrors the prior wording but on a single line:
        // "CI: all green · 6 passed", "CI: 2 pending · 4 passed", etc.
        let head: String
        if pending > 0 {
            head = "CI: \(pending) pending"
        } else {
            head = "CI: all green"
        }
        if passed > 0 {
            return "\(head) · \(passed) passed"
        }
        return head
    }

    private var failed: [CheckSummary] {
        checks.filter { $0.bucket == .failed }
    }

    private var nonFailed: [CheckSummary] {
        checks
            .filter { $0.bucket != .failed }
            .sorted { lhs, rhs in
                let lr = bucketRank(lhs.bucket), rr = bucketRank(rhs.bucket)
                if lr != rr { return lr < rr }
                return lhs.name < rhs.name
            }
    }

    private func bucketRank(_ b: CheckSummary.Bucket) -> Int {
        switch b {
        case .pending: return 0
        case .passed:  return 1
        case .unknown: return 2
        case .failed:  return -1
        }
    }

    private func disclosureLabel(pending: Int, passed: Int) -> String {
        var bits: [String] = []
        if pending > 0 { bits.append("\(pending) pending") }
        if passed > 0  { bits.append("\(passed) passed") }
        if bits.isEmpty { bits.append("\(nonFailed.count) more") }
        return bits.joined(separator: " · ")
    }

    @ViewBuilder
    private func row(_ check: CheckSummary) -> some View {
        let urlString = check.url
        let url = urlString.flatMap(URL.init(string:))
        Button {
            if let url { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 6) {
                statusIcon(check)
                Text(check.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(stateLabel(check))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                if url != nil {
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
        .help(url == nil ? "" : "Open in browser")
    }

    @ViewBuilder
    private func statusIcon(_ check: CheckSummary) -> some View {
        switch check.bucket {
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        case .pending:
            Image(systemName: "clock")
                .foregroundStyle(.yellow)
                .font(.caption)
        case .passed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .unknown:
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }

    private func stateLabel(_ check: CheckSummary) -> String {
        if let c = check.conclusion, !c.isEmpty { return c.lowercased() }
        if let s = check.status, !s.isEmpty { return s.lowercased() }
        return ""
    }
}

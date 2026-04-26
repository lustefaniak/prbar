import SwiftUI
import AppKit

struct PRRowView: View {
    let pr: InboxPR
    let isRefreshing: Bool
    let isMerging: Bool
    let onRefresh: () -> Void
    let onMerge: (MergeMethod) -> Void
    /// When true (set by `ScreenshotTests`), swap `Menu` for plain
    /// `Button`s. ImageRenderer can't capture NSPopUpButton-backed Menus
    /// — they render as the yellow "image not loaded" placeholder.
    var screenshotMode: Bool = false

    @State private var isHovering = false
    @State private var showMergeConfirm = false
    @State private var pendingMergeMethod: MergeMethod = .squash

    /// Persist the last merge method the user chose per-repo, so the
    /// split button's primary action defaults to "what you did last time"
    /// in this repo. Falls back to the repo-default order (squash >
    /// rebase > merge) when unset. Stored in UserDefaults under
    /// `lastMergeMethod.<owner>/<repo>`.
    private var defaultMergeMethod: MergeMethod {
        if let raw = UserDefaults.standard.string(forKey: defaultsKey),
           let stored = MergeMethod(rawValue: raw),
           pr.allowedMergeMethods.contains(stored) {
            return stored
        }
        return pr.preferredMergeMethod ?? .squash
    }

    private var defaultsKey: String { "lastMergeMethod.\(pr.nameWithOwner)" }

    private func rememberMethod(_ m: MergeMethod) {
        UserDefaults.standard.set(m.rawValue, forKey: defaultsKey)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            roleBadge
            VStack(alignment: .leading, spacing: 1) {
                Text(pr.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(verbatim: "\(pr.nameWithOwner) #\(pr.numberString)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if pr.isDraft {
                        Text("draft")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    rollupBadge
                    reviewBadge
                }
            }
            Spacer()
            trailingControl
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .help(tooltip)
        .confirmationDialog(
            "\(pendingMergeMethod.displayName) #\(pr.numberString)?",
            isPresented: $showMergeConfirm,
            titleVisibility: .visible
        ) {
            Button(pendingMergeMethod.displayName, role: .destructive) {
                rememberMethod(pendingMergeMethod)
                onMerge(pendingMergeMethod)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(pr.title)\n\(pr.nameWithOwner) → \(pr.baseRef)")
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        if isMerging {
            ProgressView()
                .controlSize(.small)
                .help("Merging…")
        } else if isRefreshing {
            ProgressView()
                .controlSize(.small)
                .help("Refreshing…")
        } else {
            HStack(spacing: 4) {
                if pr.isReadyToMerge {
                    mergeSplitButton
                }
                // Always make the secondary actions reachable. When ready
                // to merge, the … sits next to the prominent merge button
                // so the user can still hit "Open in browser" / "Refresh"
                // without losing it. Hover-only for non-ready rows so it
                // doesn't clutter the inbox.
                if isHovering || pr.isReadyToMerge {
                    secondaryActionsMenu
                }
            }
        }
    }

    /// Hover-only "…" menu — Open in browser + Refresh. Merge actions
    /// were promoted to the split button on ready-to-merge rows; on
    /// non-ready rows merge isn't an option anyway (GitHub would refuse).
    @ViewBuilder
    private var secondaryActionsMenu: some View {
        if screenshotMode {
            Image(systemName: "ellipsis.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Actions")
        } else {
            secondaryActionsMenuLive
        }
    }

    @ViewBuilder
    private var secondaryActionsMenuLive: some View {
        Menu {
            Button {
                NSWorkspace.shared.open(pr.url)
            } label: {
                Label("Open in browser", systemImage: "safari")
            }
            Button {
                onRefresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Actions")
    }

    /// SwiftUI Menu in `primaryAction:` mode renders as a split button:
    /// the label fires the primary action on click, the chevron opens
    /// the menu of alternatives. Only the methods the repo actually
    /// allows appear in the dropdown.
    @ViewBuilder
    private var mergeSplitButton: some View {
        if screenshotMode {
            mergeSplitButtonStatic
        } else {
            mergeSplitButtonLive
        }
    }

    /// Screenshot-only flat rendering: a plain `.borderedProminent` button
    /// (which ImageRenderer captures fine) plus a static chevron glyph
    /// next to it that visually mirrors the production split-button.
    @ViewBuilder
    private var mergeSplitButtonStatic: some View {
        let primary = defaultMergeMethod
        HStack(spacing: 0) {
            Button {} label: {
                Label(primary.shortDisplayName, systemImage: "arrow.triangle.merge")
                    .labelStyle(.titleAndIcon)
                    .font(.callout.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .controlSize(.small)
            .fixedSize()
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .frame(height: 22)
                .background(Color.green, in: RoundedRectangle(cornerRadius: 4))
                .padding(.leading, 1)
        }
    }

    @ViewBuilder
    private var mergeSplitButtonLive: some View {
        let primary = defaultMergeMethod
        let alternatives = MergeMethod.allCases.filter {
            pr.allowedMergeMethods.contains($0) && $0 != primary
        }
        Menu {
            ForEach(alternatives, id: \.rawValue) { method in
                Button {
                    pendingMergeMethod = method
                    showMergeConfirm = true
                } label: {
                    Label(method.displayName, systemImage: "arrow.triangle.merge")
                }
            }
        } label: {
            Label(primary.shortDisplayName, systemImage: "arrow.triangle.merge")
                .labelStyle(.titleAndIcon)
                .font(.callout.weight(.semibold))
        } primaryAction: {
            pendingMergeMethod = primary
            showMergeConfirm = true
        }
        // .borderedProminent + green tint reads as "primary action" not
        // "subtle hint". Tinted green to mirror GitHub's own merge button
        // and to stand out against the row's monochrome metadata.
        .menuStyle(.button)
        .buttonStyle(.borderedProminent)
        .tint(.green)
        .controlSize(.small)
        .fixedSize()
        .help("\(primary.displayName) #\(pr.numberString) — click chevron for alternatives")
    }

    private var tooltip: String {
        var parts = ["\(pr.nameWithOwner) #\(pr.numberString) — \(pr.title)"]
        parts.append("mergeable: \(pr.mergeStateStatus)")
        if let dec = pr.reviewDecision { parts.append("review: \(dec)") }
        parts.append("author: @\(pr.author)")
        return parts.joined(separator: "\n")
    }

    @ViewBuilder
    private var roleBadge: some View {
        switch pr.role {
        case .authored:
            Image(systemName: "person.fill")
                .foregroundStyle(.blue)
                .font(.caption)
        case .reviewRequested:
            Image(systemName: "eye.fill")
                .foregroundStyle(.orange)
                .font(.caption)
        case .both:
            Image(systemName: "person.crop.circle.badge.checkmark")
                .foregroundStyle(.purple)
                .font(.caption)
        case .other:
            Image(systemName: "circle.dotted")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }

    @ViewBuilder
    private var rollupBadge: some View {
        switch pr.checkRollupState {
        case "SUCCESS":
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .font(.caption2)
        case "FAILURE", "ERROR":
            Image(systemName: "xmark.seal.fill")
                .foregroundStyle(.red)
                .font(.caption2)
        case "PENDING", "EXPECTED":
            Image(systemName: "circle.dotted")
                .foregroundStyle(.yellow)
                .font(.caption2)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var reviewBadge: some View {
        switch pr.reviewDecision {
        case "APPROVED":
            Image(systemName: "hand.thumbsup.fill")
                .foregroundStyle(.green)
                .font(.caption2)
        case "CHANGES_REQUESTED":
            Image(systemName: "hand.thumbsdown.fill")
                .foregroundStyle(.red)
                .font(.caption2)
        case "REVIEW_REQUIRED":
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
                .font(.caption2)
        default:
            EmptyView()
        }
    }
}

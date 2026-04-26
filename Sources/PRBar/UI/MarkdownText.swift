import SwiftUI
import AppKit
import MarkdownUI

/// Renders GitHub-flavored Markdown via `swift-markdown-ui`. PR bodies,
/// AI review summaries, and per-subreview outcomes all flow through
/// here so styling stays consistent.
///
/// Links and images are scheme-filtered before reaching the system —
/// only `http`, `https`, and `mailto` open. Anything else (including
/// `file://`, `javascript:`, custom URL handlers) is silently dropped.
/// Markdown body text comes from arbitrary PR authors and AI output;
/// we treat both as untrusted.
struct MarkdownText: View {
    let raw: String

    var body: some View {
        Markdown(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            .markdownTheme(.prbar)
            .markdownImageProvider(.safeRemote)
            .markdownInlineImageProvider(.safeRemote)
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                guard MarkdownText.isSafe(url) else { return .discarded }
                NSWorkspace.shared.open(url)
                return .handled
            })
    }

    /// http/https/mailto only. Everything else (including schemeless
    /// or custom-scheme URLs) is rejected so a malicious or malformed
    /// link in an AI summary or PR body can't trigger arbitrary URL
    /// handlers.
    static func isSafe(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == "mailto"
    }
}

/// Image provider that drops any non-https URL. PR bodies and AI
/// summaries occasionally embed inline images; we don't want a `file://`
/// or `http://` (cleartext) URL to fire a request from the menu-bar
/// app.
struct SafeRemoteImageProvider: ImageProvider, InlineImageProvider {
    static let shared = SafeRemoteImageProvider()

    func makeImage(url: URL?) -> some View {
        Group {
            if let url, url.scheme?.lowercased() == "https" {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        ProgressView().controlSize(.small)
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    case .failure:
                        brokenImagePlaceholder
                    @unknown default:
                        brokenImagePlaceholder
                    }
                }
            } else {
                brokenImagePlaceholder
            }
        }
    }

    func image(with url: URL, label: String) async throws -> Image {
        guard url.scheme?.lowercased() == "https" else {
            throw URLError(.unsupportedURL)
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let nsImage = NSImage(data: data) else {
            throw URLError(.cannotDecodeContentData)
        }
        return Image(nsImage: nsImage)
    }

    private var brokenImagePlaceholder: some View {
        Image(systemName: "photo")
            .foregroundStyle(.secondary)
            .help("Image hidden — only https images render")
    }
}

extension ImageProvider where Self == SafeRemoteImageProvider {
    static var safeRemote: SafeRemoteImageProvider { .shared }
}

extension InlineImageProvider where Self == SafeRemoteImageProvider {
    static var safeRemote: SafeRemoteImageProvider { .shared }
}

extension Theme {
    /// Tuned for the popover: tighter margins than the default GitHub
    /// theme.
    @MainActor
    static let prbar = Theme.gitHub
        .text {
            ForegroundColor(.primary)
            BackgroundColor(.clear)
            FontSize(.em(1.0))
        }
        .paragraph { config in
            config.label
                .relativeLineSpacing(.em(0.15))
                .markdownMargin(top: 0, bottom: 6)
        }
        .heading1 { config in
            config.label
                .markdownMargin(top: 8, bottom: 4)
                .markdownTextStyle {
                    FontWeight(.bold)
                    FontSize(.em(1.25))
                }
        }
        .heading2 { config in
            config.label
                .markdownMargin(top: 8, bottom: 4)
                .markdownTextStyle {
                    FontWeight(.bold)
                    FontSize(.em(1.15))
                }
        }
        .heading3 { config in
            config.label
                .markdownMargin(top: 6, bottom: 2)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.05))
                }
        }
}

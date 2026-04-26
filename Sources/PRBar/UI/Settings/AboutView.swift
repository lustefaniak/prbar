import SwiftUI
import AppKit

/// "About" tab in Settings — shows the app icon, version, copyright,
/// and authorship. Pulls version + build numbers straight from
/// Bundle.main so they stay in sync with project.yml.
struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            // App icon — the same icon shipped in AppIcon.appiconset.
            // NSImage(named: "AppIcon") comes back nil from the asset
            // catalog under some build configs, so fall back to the
            // running app's icon image (always present).
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)

            Text("PRBar")
                .font(.title.bold())

            Text("Version \(versionString)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Text("Menu-bar PR co-pilot — monitors GitHub PRs and runs AI-assisted reviews via the gh and claude CLIs.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            Divider()
                .padding(.horizontal, 60)

            VStack(spacing: 4) {
                Text("Built by")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text("Łukasz Stefaniak  ·  Claude Code Opus")
                    .font(.callout)
            }

            HStack(spacing: 8) {
                Link(destination: URL(string: "https://github.com/lustefaniak")!) {
                    Label("@lustefaniak", systemImage: "person.crop.circle")
                }
                Link(destination: URL(string: "https://github.com/lustefaniak/prbar")!) {
                    Label("Source", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
            .font(.callout)
            .controlSize(.small)
            .padding(.top, 2)

            Spacer(minLength: 0)

            Text(copyright)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        // Marketing version is the latest git tag (sans `v`); build
        // number is the commit count of HEAD. Showing both makes dev
        // builds vs tagged releases instantly recognisable in the
        // About box.
        return "\(version) (build \(build))"
    }

    private var copyright: String {
        Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String
            ?? "© Łukasz Stefaniak"
    }
}

#Preview {
    AboutView()
        .frame(width: 700, height: 520)
}

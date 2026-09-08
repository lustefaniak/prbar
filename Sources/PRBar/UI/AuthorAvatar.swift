import SwiftUI

/// GitHub avatar for a login, rendered as a circle.
///
/// ponytail: `github.com/<login>.png` redirects to the same avatar CDN, so no
/// `avatarUrl` has to be threaded through the GraphQL query, `InboxPR`, and
/// every `makePR` fixture. Falls back to an SF symbol offline (screenshot
/// fixtures included).
struct AuthorAvatar: View {
    let login: String
    var size: CGFloat = 14

    var body: some View {
        AsyncImage(url: URL(string: "https://github.com/\(login).png?size=\(Int(size * 2))")) { image in
            image.resizable()
        } placeholder: {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(.secondary)
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .help("@\(login)")
    }
}

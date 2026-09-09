import NetworkImage
import SwiftUI

/// GitHub avatar for a login, rendered as a circle.
///
/// `github.com/<login>.png` redirects to the same avatar CDN, so no
/// `avatarUrl` has to be threaded through the GraphQL query, `InboxPR`, and
/// every `makePR` fixture. Falls back to an SF symbol offline (screenshot
/// fixtures included).
///
/// `NetworkImage` rather than `AsyncImage`: it keeps decoded images in a
/// process-wide `NSCache`, so switching tabs re-renders the same avatars
/// instead of refetching them. `AsyncImage` holds nothing between view
/// identities and every rebuild re-hits the network.
struct AuthorAvatar: View {
    let login: String
    var size: CGFloat = 14

    var body: some View {
        NetworkImage(url: URL(string: "https://github.com/\(login).png?size=\(Int(size * 2))")) { image in
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

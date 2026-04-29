import SwiftUI

struct ArtistDiscographyView: View {
    let albums: [CatalogAlbum]
    let isEnglish: Bool
    let isDarkMode: Bool

    private var titleText: String { isEnglish ? "Discography" : "Дискография" }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(albums) { al in
                    VStack(alignment: .leading, spacing: 8) {
                        AsyncImage(url: catalogRemoteImageURL(al.coverURL)) { phase in
                            switch phase {
                            case .success(let img):
                                img.resizable().scaledToFill()
                            default:
                                Rectangle().fill(Color.white.opacity(isDarkMode ? 0.08 : 0.06))
                            }
                        }
                        .frame(height: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                        Text(al.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(isDarkMode ? .white : .primary)
                            .lineLimit(2)
                        Text(isEnglish ? "Album" : "Альбом")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .navigationTitle(titleText)
        .navigationBarTitleDisplayMode(.inline)
        .background((isDarkMode ? Color.black : Color(.systemBackground)).ignoresSafeArea())
    }
}


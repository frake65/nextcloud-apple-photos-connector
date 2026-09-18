import SwiftUI
import Photos

struct ContentView: View {
    @StateObject private var library = PhotoLibraryModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if library.authorization.canRead {
                TabView {
                    NavigationStack { GalleryScreen(library: library, assets: library.assets, title: "Fotos") }
                        .tabItem { Label("Fotos", systemImage: "photo.on.rectangle.angled") }
                    NavigationStack { AlbumsScreen(library: library) }
                        .tabItem { Label("Alben", systemImage: "rectangle.stack") }
                }
            } else {
                permissionView
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { library.refreshAuthorizationAndLoad() }
        }
        .onAppear { library.refreshAuthorizationAndLoad() }
    }

    private var permissionView: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.stack").font(.system(size: 48)).foregroundStyle(.tint)
            Text("Zugriff auf deine Fotos").font(.title2.bold())
            Text("Nextcloud APC benötigt Zugriff auf deine Fotomediathek, damit du Fotos, Videos und Alben für die Übernahme nach Nextcloud ansehen kannst.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            switch library.authorization {
            case .notDetermined:
                Button("Zugriff auf Fotos erlauben") { library.requestAccess() }.buttonStyle(.borderedProminent)
            case .denied:
                Text("Der Zugriff wurde abgelehnt. Du kannst ihn in den iPhone-Einstellungen unter Datenschutz & Sicherheit → Fotos ändern.").multilineTextAlignment(.center)
                Button("Erneut prüfen") { library.refreshAuthorizationAndLoad() }.buttonStyle(.bordered)
            case .restricted:
                Text("Der Zugriff auf Fotos ist für dieses Gerät oder Konto eingeschränkt.").multilineTextAlignment(.center)
            case .authorized, .limited: EmptyView()
            }
        }.padding(28).navigationTitle("Nextcloud APC")
    }
}

private struct AlbumsScreen: View {
    @ObservedObject var library: PhotoLibraryModel
    var body: some View {
        List(library.albums) { album in
            NavigationLink {
                GalleryScreen(library: library, assets: library.assets(in: album), title: album.title)
            } label: {
                HStack(spacing: 14) {
                    if let cover = album.cover { ThumbnailView(asset: cover, library: library, dimension: 60) }
                    else { Image(systemName: "rectangle.stack").frame(width: 60, height: 60).background(.quaternary, in: RoundedRectangle(cornerRadius: 8)) }
                    VStack(alignment: .leading) { Text(album.title).font(.headline); Text("\(album.count) Medien").font(.subheadline).foregroundStyle(.secondary) }
                }
            }
        }
        .overlay { if library.isLoading && library.albums.isEmpty { ProgressView("Alben werden geladen…") } else if library.albums.isEmpty { ContentUnavailableView("Keine Alben", systemImage: "rectangle.stack", description: Text(library.authorization == .limited ? "Bei eingeschränktem Zugriff sind möglicherweise nicht alle Alben sichtbar." : "In der Mediathek wurden keine Benutzeralben gefunden.")) } }
        .navigationTitle("Alben")
        .toolbar { if library.authorization == .limited { Label("Eingeschränkter Zugriff", systemImage: "person.crop.circle.badge.checkmark").labelStyle(.iconOnly) } }
    }
}

private struct GalleryScreen: View {
    @ObservedObject var library: PhotoLibraryModel
    let assets: [GalleryAsset]
    let title: String
    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 2)]

    var body: some View {
        ScrollView {
            if library.authorization == .limited { limitedAccessNotice }
            if library.isLoading && assets.isEmpty { ProgressView("Mediathek wird geladen…").padding(.top, 60) }
            else if assets.isEmpty { ContentUnavailableView("Keine Medien", systemImage: "photo.on.rectangle.angled", description: Text(library.authorization == .limited ? "Für diese Ansicht sind keine freigegebenen Fotos oder Videos verfügbar." : "Es wurden keine Fotos oder Videos gefunden.")) }
            else {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(assets) { item in
                        ZStack(alignment: .bottomTrailing) {
                            ThumbnailView(asset: item.asset, library: library, dimension: 160).aspectRatio(1, contentMode: .fill).clipped()
                            if item.isVideo { Label("Video", systemImage: "play.fill").font(.caption2.bold()).padding(5).background(.black.opacity(0.65), in: Capsule()).foregroundStyle(.white).padding(6) }
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
        .toolbar { if library.authorization == .limited { Label("Eingeschränkter Zugriff", systemImage: "person.crop.circle.badge.checkmark") } }
    }

    private var limitedAccessNotice: some View {
        Label("Eingeschränkter Zugriff: Es werden nur die Fotos und Videos angezeigt, die du freigegeben hast.", systemImage: "person.crop.circle.badge.checkmark")
            .font(.footnote).foregroundStyle(.secondary).padding()
    }
}

private struct ThumbnailView: View {
    let asset: PHAsset
    @ObservedObject var library: PhotoLibraryModel
    let dimension: CGFloat
    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { ProgressView().controlSize(.small) }
        }
        .frame(width: dimension, height: dimension).clipped()
        .onAppear {
            requestID = library.requestThumbnail(for: asset, size: CGSize(width: dimension * UIScreen.main.scale, height: dimension * UIScreen.main.scale)) { image in
                DispatchQueue.main.async { self.image = image }
            }
        }
        .onDisappear { if let requestID { library.cancelThumbnail(requestID) }; requestID = nil }
    }
}

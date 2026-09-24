import SwiftUI
import Photos
import UIKit
import InventoryCore

struct ContentView: View {
    private enum AppTab: Hashable { case photos, albums, connection }
    @StateObject private var library = PhotoLibraryModel()
    @StateObject private var selection = AssetSelectionModel()
    @StateObject private var connection = IOSConnectionModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingInventoryReview = false
    @State private var showingStartup = true
    @State private var selectedTab: AppTab = .photos

    init() {
        IOSImportDiagnostics.log("[Startup] ContentView init")
    }

    var body: some View {
        Group {
            if showingStartup && !library.hasLoadedInitialState {
                StartupView(isLoadingLibrary: library.authorization.canRead || library.isLoading) {
                    if library.authorization == .notDetermined { library.requestAccess() }
                }
            } else {
            if library.authorization.canRead {
                TabView(selection: $selectedTab) {
                    NavigationStack {
                        GalleryScreen(library: library, selection: selection, assets: library.assets, title: "Fotos & Videos", canImport: connection.parsedSourceId != nil, onCheck: { showingInventoryReview = true })
                    }.tabItem { Label("Fotos", systemImage: "photo.on.rectangle.angled") }.tag(AppTab.photos)
                    NavigationStack { AlbumsScreen(library: library, selection: selection, canImport: connection.parsedSourceId != nil, onCheck: { showingInventoryReview = true }) }
                        .tabItem { Label("Alben", systemImage: "rectangle.stack") }.tag(AppTab.albums)
                    NavigationStack { ConnectionView(model: connection) }
                        .tabItem { Label("Einstellungen", systemImage: "server.rack") }.tag(AppTab.connection)
                }
            } else {
                permissionView
            }
            }
        }
        .sheet(isPresented: $showingInventoryReview) {
            NavigationStack {
                InventoryReviewScreen(library: library, selection: selection, connection: connection)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                library.refreshAuthorizationAndLoad()
                Task { await presentRecoveryIfNeeded() }
            }
        }
        .onAppear {
            IOSImportDiagnostics.log("[Startup] ContentView appeared")
            library.refreshAuthorizationAndLoad()
            Task { await presentRecoveryIfNeeded() }
            routeToInitialConnectionIfNeeded()
        }
        .onChange(of: library.hasLoadedInitialState) { _, loaded in
            if loaded {
                showingStartup = false
                routeToInitialConnectionIfNeeded()
            }
        }
        .onChange(of: library.isLoading) { _, loading in
            if !loading { Task { await presentRecoveryIfNeeded() } }
        }
    }

    private func routeToInitialConnectionIfNeeded() {
        guard library.hasLoadedInitialState, library.authorization.canRead, !connection.hasConfiguredConnection else { return }
        selectedTab = .connection
    }

    private var permissionView: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.stack").font(.system(size: 48)).foregroundStyle(.tint)
            Text("Zugriff auf deine Fotos").font(.title2.bold())
            Text("Photos Connector benötigt Zugriff auf deine Fotomediathek, damit du Fotos, Videos und Alben aus Apple Fotos in Nextcloud ansehen kannst.")
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
        }.padding(28).navigationTitle("Photos Connector")
    }

    @MainActor
    private func presentRecoveryIfNeeded() async {
        guard !showingInventoryReview,
              connection.parsedSourceId != nil,
              !library.isLoading,
              !library.assets.isEmpty else { return }
        let store = ImportQueueStore()
        let coordinator = BackgroundTransferCoordinator.shared
        _ = await coordinator.reconcileTasks(queueStore: store)
        guard await coordinator.activeBindings().isEmpty else { return }
        let sourceID = connection.parsedSourceId!
        let hasRecoverableRun = (await store.recoverableRuns()).contains { run in
            run.sourceID == sourceID &&
            run.account.serverBaseURL == connection.server &&
            run.account.username == connection.username &&
            run.assets.allSatisfy { persistedAsset in
                library.assets.contains { galleryAsset in galleryAsset.id == persistedAsset.localIdentifier }
            }
        }
        if hasRecoverableRun { showingInventoryReview = true }
    }
}

private struct StartupView: View {
    let isLoadingLibrary: Bool
    let onVisible: () -> Void
    private let launchBlue = Color(red: 0.0, green: 0.4784313725, blue: 1.0)

    var body: some View {
        ZStack {
            launchBlue.ignoresSafeArea()
            VStack(spacing: 20) {
                Image("PhotosConnectorLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 140, height: 140)
                Text("Photos Connector")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                if isLoadingLibrary {
                    ProgressView()
                        .tint(.white)
                        .onAppear { IOSImportDiagnostics.log("[Startup] loading indicator appeared") }
                    Text("Mediathek wird geladen …")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
        }
        .preferredColorScheme(.light)
        .task {
            IOSImportDiagnostics.log("[Startup] StartupView appeared")
            onVisible()
        }
    }
}

private struct AlbumsScreen: View {
    @ObservedObject var library: PhotoLibraryModel
    @ObservedObject var selection: AssetSelectionModel
    let canImport: Bool
    let onCheck: () -> Void

    var body: some View {
        List(library.albums) { album in
            NavigationLink {
                GalleryScreen(library: library, selection: selection, assets: library.assets(in: album), title: album.title, canImport: canImport, onCheck: onCheck)
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
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if library.authorization == .limited { ToolbarItem(placement: .topBarLeading) { Label("Eingeschränkter Zugriff", systemImage: "person.crop.circle.badge.checkmark").labelStyle(.iconOnly) } }
            ToolbarItem(placement: .topBarTrailing) { selectionButton }
        }
    }

    private var selectionButton: some View {
        Button(action: onCheck) { Label("Fotos & Alben übernehmen", systemImage: "icloud.and.arrow.up") }
            .disabled(!canImport)
    }
}

private struct GalleryScreen: View {
    @ObservedObject var library: PhotoLibraryModel
    @ObservedObject var selection: AssetSelectionModel
    let assets: [GalleryAsset]
    let title: String
    let canImport: Bool
    let onCheck: () -> Void
    @AppStorage("apc.ios.gallery.columnCount") private var columnCount = 3
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 0), spacing: 2), count: columnCount)
    }
    @State private var cellFrames: [String: CGRect] = [:]
    @StateObject private var gestureData = GalleryGestureData()
    @State private var galleryScrollView: UIScrollView?
    @State private var autoScrollDriver: ContinuousScrollDriver?
    @State private var dragLocation: CGPoint?

    private struct CellFramesKey: PreferenceKey {
        static let defaultValue: [String: CGRect] = [:]
        static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { $1 }) }
    }

    var body: some View {
        ScrollView {
            // Keep the probe inside the ScrollView's content hierarchy so its
            // UIKit host has the gallery UIScrollView as an ancestor.
            ScrollViewIntrospector(scrollView: $galleryScrollView)
                .frame(width: 0, height: 0)
            if library.authorization == .limited { limitedAccessNotice }
            if library.isLoading && assets.isEmpty { ProgressView("Mediathek wird geladen…").padding(.top, 60) }
            else if assets.isEmpty { ContentUnavailableView("Keine Medien", systemImage: "photo.on.rectangle.angled", description: Text(library.authorization == .limited ? "Für diese Ansicht sind keine freigegebenen Fotos oder Videos verfügbar." : "Es wurden keine Fotos oder Videos gefunden.")) }
            else {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(assets) { item in
                        Button { selection.toggle(item) } label: {
                            GeometryReader { proxy in
                                let side = proxy.size.width
                                ZStack(alignment: .bottomTrailing) {
                                    ThumbnailView(asset: item.asset, library: library, dimension: 160)
                                        .frame(width: side, height: side)
                                        .clipped()
                                        .overlay(alignment: .topTrailing) { selectionIndicator(for: item) }
                                    if item.isVideo { Label(item.durationLabel, systemImage: "play.fill").font(.caption2.bold()).padding(5).background(.black.opacity(0.65), in: Capsule()).foregroundStyle(.white).padding(6).frame(maxWidth: .infinity, alignment: .leading) }
                                }
                                .frame(width: side, height: side)
                                .clipped()
                            }
                            .aspectRatio(1, contentMode: .fit)
                        }
                        .buttonStyle(.plain)
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: CellFramesKey.self, value: [item.id: proxy.frame(in: .global)])
                        })
                        .accessibilityLabel(selection.contains(item) ? "Auswahl aufheben" : "Foto auswählen")
                    }
                }
            }
        }
        .coordinateSpace(name: "gallery-grid")
        .background { SelectionLongPressBridge(scrollView: $galleryScrollView) { state, location in
            handleSelectionLongPress(state: state, location: location)
        } }
        .onPreferenceChange(CellFramesKey.self) { frames in
            cellFrames = frames
            gestureData.frames = frames
        }
        .onChange(of: assets.count) { _, _ in
            gestureData.assets = assets
        }
        .onAppear {
            gestureData.assets = assets
            debugLog("SELECT GALLERY SCREEN ACTIVE")
        }
        .onDisappear { stopAutoScroll(); selection.endDrag() }
        .navigationTitle(title)
        .toolbar {
            if library.authorization == .limited { ToolbarItem(placement: .topBarLeading) { Label("Eingeschränkter Zugriff", systemImage: "person.crop.circle.badge.checkmark").labelStyle(.iconOnly) } }
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(title).font(.headline)
                    Text("Photos Connector").font(.caption2).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            ToolbarItem(placement: .topBarLeading) {
                Button(action: toggleAll) {
                    Label(allSelected ? "Alle abwählen" : "Alle auswählen", systemImage: allSelected ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .disabled(assets.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Text("Darstellung")
                    ForEach([3, 4, 5, 6], id: \.self) { count in
                        Button { columnCount = count } label: {
                            Label("\(count) Spalten", systemImage: columnCount == count ? "checkmark" : "circle")
                        }
                    }
                } label: {
                    Label("Darstellung", systemImage: "square.grid.3x3")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            importAction
        }
    }

    private var limitedAccessNotice: some View {
        Label("Eingeschränkter Zugriff: Es werden nur freigegebene Fotos und Videos angezeigt.", systemImage: "person.crop.circle.badge.checkmark")
            .font(.footnote).foregroundStyle(.secondary).padding()
    }

    private var allSelected: Bool { selection.allSelected(in: assets) }

    private var importAction: some View {
        HStack(spacing: 12) {
            Text("\(selection.count) ausgewählt")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selection.count == 0 ? .secondary : .primary)
            Spacer()
            Button(action: onCheck) {
                Label("Fotos & Alben übernehmen", systemImage: "icloud.and.arrow.up")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canImport)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func toggleAll() {
        if allSelected { selection.deselectAll(in: assets) }
        else { selection.selectAll(in: assets) }
    }

    private func selectionIndicator(for item: GalleryAsset) -> some View {
        let isSelected = selection.contains(item)
        return ZStack {
            Circle()
                .fill(isSelected ? Color.blue : Color.white.opacity(0.82))
                .overlay(Circle().stroke(isSelected ? Color.white.opacity(0.9) : Color.black.opacity(0.72), lineWidth: 1.5))
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: markerSize, height: markerSize)
        .padding(markerPadding)
    }

    private var markerSize: CGFloat {
        switch columnCount { case 4: 22; case 5: 19; case 6: 16; default: 25 }
    }

    private var markerPadding: CGFloat {
        switch columnCount { case 4: 6; case 5: 5; case 6: 4; default: 7 }
    }

    private func handleSelectionLongPress(state: UIGestureRecognizer.State, location: CGPoint) {
        let point = location
        switch state {
        case .began:
            debugLog("SELECT BEGIN location=\(point.x),\(point.y)")
            #if DEBUG
            let scroll = galleryScrollView
            print("SELECT COORD touchGlobal=(\(point.x),\(point.y)) contentOffset=(\(scroll?.contentOffset.x ?? 0),\(scroll?.contentOffset.y ?? 0)) adjustedInset=(\(scroll?.adjustedContentInset.top ?? 0),\(scroll?.adjustedContentInset.left ?? 0),\(scroll?.adjustedContentInset.bottom ?? 0),\(scroll?.adjustedContentInset.right ?? 0))")
            #endif
            guard let item = asset(at: point) else {
                debugLog("SELECT BEGIN NO ASSET location=\(point.x),\(point.y) frames=\(cellFrames.prefix(4))")
                return
            }
            #if DEBUG
            logSelectionHit(item: item, touch: point)
            #endif
            dragLocation = point
            selection.beginDrag(at: item)
            updateAutoScroll()
        case .changed:
            guard selection.dragIsActive else { return }
            dragLocation = point
            if let item = asset(at: point) { selection.applyDrag(to: item) }
            updateAutoScroll()
        case .ended, .cancelled, .failed:
            stopAutoScroll(); dragLocation = nil; selection.endDrag()
        default: break
        }
    }

    private func updateAutoScroll() {
        guard let point = dragLocation, selection.dragIsActive, let scrollView = galleryScrollView else { stopAutoScroll(); return }
        let zone: CGFloat = 70
        let height = scrollView.bounds.height
        guard let velocity = GalleryAutoScroll.velocity(fingerY: point.y, viewportHeight: height, zone: zone) else {
            stopAutoScroll()
            debugLog("SELECT AUTOSCROLL STOP")
            return
        }
        if autoScrollDriver == nil { autoScrollDriver = ContinuousScrollDriver() }
        autoScrollDriver?.start(scrollView: scrollView, velocity: velocity) { [weak selection] delta, currentVelocity in
            guard let selection else { return }
            let location = self.dragLocation ?? point
            let sweep = abs(currentVelocity) * delta + 2
            for asset in self.gestureData.assets where self.gestureData.frames[asset.id]?.insetBy(dx: 0, dy: -sweep).contains(location) == true {
                selection.applyDrag(to: asset)
            }
        }
    }

    private func stopAutoScroll() {
        autoScrollDriver?.stop()
    }

    private func debugLog(_ message: String) {
        #if DEBUG
        print(message)
        #endif
    }

    private func asset(at point: CGPoint) -> GalleryAsset? {
        guard let key = gestureData.frames.first(where: { $0.value.contains(point) })?.key else { return nil }
        #if DEBUG
        if !gestureData.assets.contains(where: { $0.id == key }) {
            print("SELECT HIT ASSET LOOKUP key=\(key) found=false ids=\(gestureData.assets.prefix(6).map(\.id))")
        }
        #endif
        return gestureData.assets.first { $0.id == key }
    }

    #if DEBUG
    private func logSelectionHit(item: GalleryAsset, touch: CGPoint) {
        guard let frame = gestureData.frames[item.id] else { return }
        let left = gestureData.frames
            .filter { $0.key != item.id && $0.value.maxX <= frame.minX && $0.value.intersects(frame.insetBy(dx: 0, dy: -1)) }
            .max { $0.value.maxX < $1.value.maxX }
        let right = gestureData.frames
            .filter { $0.key != item.id && $0.value.minX >= frame.maxX && $0.value.intersects(frame.insetBy(dx: 0, dy: -1)) }
            .min { $0.value.minX < $1.value.minX }
        func shortID(_ id: String?) -> String { id.map { String($0.prefix(8)) } ?? "-" }
        print("SELECT HIT touch=(\(touch.x),\(touch.y)) asset=\(shortID(item.id)) frame=(\(frame.minX),\(frame.minY),\(frame.width),\(frame.height)) center=(\(frame.midX),\(frame.midY)) delta=(\(touch.x - frame.midX),\(touch.y - frame.midY)) left=\(shortID(left?.key)) frame=\(String(describing: left?.value)) right=\(shortID(right?.key)) frame=\(String(describing: right?.value))")
    }
    #endif
}

private final class GalleryGestureData: ObservableObject {
    var assets: [GalleryAsset] = []
    var frames: [String: CGRect] = [:]
}

private struct SelectionLongPressBridge: UIViewRepresentable {
    @Binding var scrollView: UIScrollView?
    let action: (UIGestureRecognizer.State, CGPoint) -> Void

    func makeUIView(context: Context) -> UIView {
        #if DEBUG
        print("SELECT BRIDGE MAKEUIView")
        #endif
        return BridgeView(context: context)
    }
    func updateUIView(_ view: UIView, context: Context) {
        guard let scrollView, !context.coordinator.hasRecognizer else { return }
        context.coordinator.install(on: scrollView, action: action)
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var recognizer: SelectionGestureRecognizer?
        var hasRecognizer: Bool { recognizer != nil }
        private weak var pan: UIPanGestureRecognizer?
        private var action: ((UIGestureRecognizer.State, CGPoint) -> Void)?

        func install(on scrollView: UIScrollView, action: @escaping (UIGestureRecognizer.State, CGPoint) -> Void) {
            guard recognizer == nil else { return }
            self.action = action
            pan = scrollView.panGestureRecognizer
            let longPress = SelectionGestureRecognizer(target: self, action: #selector(handle(_:)))
            longPress.minimumDuration = 0.3
            longPress.movementThreshold = 20
            longPress.cancelsTouchesInView = true
            longPress.delaysTouchesBegan = false
            longPress.delaysTouchesEnded = false
            longPress.delegate = self
            scrollView.addGestureRecognizer(longPress)
            // The gallery pan waits only for this selection recognizer. A
            // normal swipe releases it as soon as allowableMovement fails;
            // a stationary hold lets selection begin and prevents the pan.
            scrollView.panGestureRecognizer.require(toFail: longPress)
            recognizer = longPress
            pan?.addTarget(self, action: #selector(handlePan(_:)))
            #if DEBUG
            print("SELECT SELECTION GESTURE INSTALLED view=\(String(describing: longPress.view)) scrollView=\(scrollView) minimumDuration=0.3 movementThreshold=20")
            print("SELECT GESTURE RECOGNIZERS " + (scrollView.gestureRecognizers ?? []).map { String(describing: type(of: $0)) }.joined(separator: ","))
            #endif
            // No failure relationship is required: movement beyond
            // allowableMovement fails this recognizer, leaving the native pan
            // to handle an immediate swipe. Simultaneous recognition remains
            // disabled below.
        }

        @objc private func handle(_ recognizer: SelectionGestureRecognizer) {
            guard let view = recognizer.view else { return }
            #if DEBUG
            let location = recognizer.location(in: view)
            print("SELECT GESTURE \(stateName(recognizer.state)) duration=\(recognizer.duration) distance=\(recognizer.distance)")
            #endif
            let localLocation = recognizer.location(in: view)
            // SwiftUI frame(in: .global) is in the global screen coordinate
            // space. Convert the recognizer location to that same space.
            let globalLocation = view.convert(localLocation, to: nil)
            action?(recognizer.state, globalLocation)
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            #if DEBUG
            let state = recognizer.state
            guard state != lastPanState else { return }
            lastPanState = state
            let name: String
            switch state { case .began: name = "began"; case .changed: name = "changed"; case .cancelled: name = "cancelled"; case .ended: name = "ended"; case .failed: name = "failed"; default: name = "possible" }
            print("SELECT PAN \(name)")
            let lpName = self.recognizer.map { stateName($0.state) } ?? "none"
            print("SELECT ARBITRATION LP=\(lpName) PAN=\(stateName(state))")
            #endif
        }

        private func stateName(_ state: UIGestureRecognizer.State) -> String {
            switch state { case .possible: "possible"; case .began: "began"; case .changed: "changed"; case .ended: "ended"; case .cancelled: "cancelled"; case .failed: "failed"; @unknown default: "unknown" }
        }

        #if DEBUG
        private var lastPanState: UIGestureRecognizer.State = .possible
        #endif

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            if other === pan { return false }
            let typeName = String(describing: type(of: other))
            if typeName.contains("UIKitResponderGestureRecognizer") || typeName.contains("UIScrollViewDelayedTouchesBeganGestureRecognizer") {
                #if DEBUG
                print("SELECT SIMULTANEOUS type=\(typeName) state=\(stateName(other.state)) -> true")
                #endif
                return true
            }
            return false
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
            return false
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            return false
        }
    }

    private final class SelectionGestureRecognizer: UIGestureRecognizer {
        var minimumDuration: TimeInterval = 0.3
        var movementThreshold: CGFloat = 20
        private var timer: DispatchWorkItem?
        private var startTime: CFTimeInterval = 0
        private var initialLocation = CGPoint.zero
        private var currentLocation = CGPoint.zero
        var duration: CFTimeInterval { startTime == 0 ? 0 : CACurrentMediaTime() - startTime }
        var delta: CGPoint { CGPoint(x: currentLocation.x - initialLocation.x, y: currentLocation.y - initialLocation.y) }
        var distance: CGFloat { hypot(delta.x, delta.y) }

        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
            #if DEBUG
            print("SELECT CAN-PREVENT target=\(type(of: preventedGestureRecognizer)) state=\(stateName(preventedGestureRecognizer.state))")
            #endif
            return super.canPrevent(preventedGestureRecognizer)
        }

        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
            #if DEBUG
            print("SELECT PREVENTED-BY type=\(type(of: preventingGestureRecognizer)) id=\(ObjectIdentifier(preventingGestureRecognizer)) state=\(stateName(preventingGestureRecognizer.state))")
            #endif
            return super.canBePrevented(by: preventingGestureRecognizer)
        }

        private func stateName(_ value: UIGestureRecognizer.State) -> String {
            switch value { case .possible: "possible"; case .began: "began"; case .changed: "changed"; case .ended: "ended"; case .cancelled: "cancelled"; case .failed: "failed"; @unknown default: "unknown" }
        }

        private func transition(to newState: UIGestureRecognizer.State, reason: String) {
            let old = state
            state = newState
            #if DEBUG
            print("SELECT STATE \(stateName(old)) -> \(stateName(newState)) reason=\(reason)")
            #endif
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            guard touches.count == 1, let touch = touches.first, let view else { transition(to: .failed, reason: "invalid-touch-count"); return }
            initialLocation = touch.location(in: view)
            currentLocation = initialLocation
            startTime = CACurrentMediaTime()
            transition(to: .possible, reason: "touches-began")
            #if DEBUG
            print("SELECT TOUCH START x=\(initialLocation.x) y=\(initialLocation.y)")
            #endif
            let timerID = UUID().uuidString
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                #if DEBUG
                print("SELECT TIMER FIRED id=\(timerID) state=\(self.stateName(self.state)) elapsed=\(self.duration) distance=\(self.distance)")
                #endif
                guard self.state == .possible else { print("SELECT TIMER IGNORED reason=state state=\(self.stateName(self.state))"); return }
                guard self.distance <= self.movementThreshold else { print("SELECT TIMER IGNORED reason=movement state=\(self.stateName(self.state))"); return }
                self.transition(to: .began, reason: "timer")
            }
            timer = work
            #if DEBUG
            print("SELECT TIMER SCHEDULED id=\(timerID) delay=0.3 state=possible")
            #endif
            DispatchQueue.main.asyncAfter(deadline: .now() + minimumDuration, execute: work)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let touch = touches.first, let view else { return }
            currentLocation = touch.location(in: view)
            guard state == .possible else {
                if state == .began {
                    transition(to: .changed, reason: "touches-moved")
                }
                return
            }
            if distance > movementThreshold {
                timer?.cancel(); timer = nil; transition(to: .failed, reason: "movement")
                #if DEBUG
                print("SELECT GESTURE FAILED reason=movement duration=\(duration) distance=\(distance)")
                #endif
            }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            timer?.cancel(); timer = nil
            if let touch = touches.first, let view { currentLocation = touch.location(in: view) }
            if state == .began || state == .changed {
                transition(to: .ended, reason: "touches-ended")
            } else if state == .possible {
                transition(to: .failed, reason: "released-before-longpress")
                #if DEBUG
                print("SELECT GESTURE FAILED reason=released-before-longpress duration=\(duration) distance=\(distance)")
                #endif
            }
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            timer?.cancel(); timer = nil
            transition(to: (state == .began || state == .changed) ? .cancelled : .failed, reason: "touches-cancelled")
        }

        override func reset() {
            #if DEBUG
            print("SELECT RESET state=\(stateName(state)) timerExists=\(timer != nil) elapsed=\(duration)")
            #endif
            timer?.cancel(); timer = nil; startTime = 0; initialLocation = .zero; currentLocation = .zero
            super.reset()
            #if DEBUG
            print("SELECT RESET COMPLETE state=\(stateName(state))")
            #endif
        }
    }

    private final class BridgeView: UIView {
        init(context: Context) { super.init(frame: .zero); isUserInteractionEnabled = false }
        required init?(coder: NSCoder) { fatalError() }
    }
}

private final class ContinuousScrollDriver: NSObject {
    private var displayLink: CADisplayLink?
    private weak var scrollView: UIScrollView?
    private var targetVelocity: CGFloat = 0
    private var currentVelocity: CGFloat = 0
    private var lastTimestamp: CFTimeInterval?
    private var onTick: ((CGFloat, CGFloat) -> Void)?

    func start(scrollView: UIScrollView, velocity: CGFloat, onTick: @escaping (CGFloat, CGFloat) -> Void) {
        self.scrollView = scrollView; self.targetVelocity = velocity; self.onTick = onTick
        if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common); displayLink = link
        }
    }
    func stop() { displayLink?.invalidate(); displayLink = nil; lastTimestamp = nil; onTick = nil; targetVelocity = 0; currentVelocity = 0 }
    @objc private func tick(_ link: CADisplayLink) {
        guard let scrollView, let onTick else { stop(); return }
        let delta = min(0.05, lastTimestamp.map { link.timestamp - $0 } ?? (1.0 / 60.0)); lastTimestamp = link.timestamp
        let minY = -scrollView.adjustedContentInset.top
        let maxY = max(minY, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
        currentVelocity += (targetVelocity - currentVelocity) * min(1, CGFloat(delta) * 12)
        guard abs(currentVelocity) > 0.5 else { return }
        let newY = min(max(scrollView.contentOffset.y + currentVelocity * CGFloat(delta), minY), maxY)
        guard newY != scrollView.contentOffset.y else { stop(); return }
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: newY), animated: false); onTick(CGFloat(delta), currentVelocity)
    }
}

private struct ScrollViewIntrospector: UIViewRepresentable {
    @Binding var scrollView: UIScrollView?
    func makeUIView(context: Context) -> UIView {
        #if DEBUG
        print("SELECT INTROSPECTOR MAKEUIView")
        #endif
        return IntrospectionView { found in
            #if DEBUG
            print("SELECT SCROLLVIEW FOUND \(found)")
            #endif
            scrollView = found
        }
    }
    func updateUIView(_ view: UIView, context: Context) {}
    private final class IntrospectionView: UIView {
        let report: (UIScrollView) -> Void
        private weak var reportedScrollView: UIScrollView?
        private var didLogWaiting = false
        init(report: @escaping (UIScrollView) -> Void) { self.report = report; super.init(frame: .zero); isUserInteractionEnabled = false }
        required init?(coder: NSCoder) { fatalError() }

        private func resolveScrollView() {
            var view = superview
            while let current = view {
                if let scroll = current as? UIScrollView {
                    guard reportedScrollView !== scroll else { return }
                    reportedScrollView = scroll
                    #if DEBUG
                    var chainParts: [String] = []
                    var chainView = self.superview
                    while let current = chainView, chainParts.count < 12 {
                        chainParts.append(String(describing: type(of: current)))
                        chainView = current.superview
                    }
                    let chain = chainParts.joined(separator: " -> ")
                    print("SELECT SCROLLVIEW FOUND (scroll) chain=\(chain)")
                    #endif
                    report(scroll)
                    return
                }
                view = current.superview
            }
            #if DEBUG
            if !didLogWaiting {
                didLogWaiting = true
                print("SELECT SCROLLVIEW SEARCH waiting")
            }
            #endif
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            resolveScrollView()
        }
        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            resolveScrollView()
        }
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
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
            else { ProgressView().controlSize(.small) }
        }
        .onAppear {
            requestID = library.requestThumbnail(for: asset, size: CGSize(width: dimension * UIScreen.main.scale, height: dimension * UIScreen.main.scale)) { image in
                DispatchQueue.main.async { self.image = image }
            }
        }
        .onDisappear { if let requestID { library.cancelThumbnail(requestID) }; requestID = nil }
    }
}

enum ImportPresentationPhase: Equatable {
    case idle
    case transferring
    case serverVerification
    case albumSync
    case completed
    case stopped

    static func resolve(
        phase: IOSForegroundImportCoordinator.Phase,
        completed: Int,
        total: Int,
        isVerifyingCompletedUpload: Bool
    ) -> Self {
        switch phase {
        case .idle: return .idle
        case .completing:
            if completed > 0, completed >= total { return .albumSync }
            return isVerifyingCompletedUpload ? .serverVerification : .transferring
        case .finished: return .completed
        case .failed, .cancelled: return .stopped
        default: return .transferring
        }
    }

    static func allowsStart(phase: Self, isRunning: Bool, hasActiveBackgroundTransfer: Bool, waitingForWiFi: Bool, hasRecoverableRun: Bool = false) -> Bool {
        !hasRecoverableRun && !isRunning && !hasActiveBackgroundTransfer && !waitingForWiFi && (phase == .idle || phase == .stopped)
    }

    static func allowsNewImport(selectionCount: Int, canImport: Bool) -> Bool {
        selectionCount > 0 && canImport
    }

    static func showsIdleHelp(phase: Self, isRunning: Bool, hasActiveBackgroundTransfer: Bool, waitingForWiFi: Bool, hasRecoverableRun: Bool = false) -> Bool {
        !hasRecoverableRun && !isRunning && !hasActiveBackgroundTransfer && !waitingForWiFi && (phase == .idle || phase == .transferring)
    }

    static func showsCancel(isRunning: Bool, waitingForWiFi: Bool) -> Bool {
        isRunning || waitingForWiFi
    }
}

private struct InventoryReviewScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var library: PhotoLibraryModel
    @ObservedObject var selection: AssetSelectionModel
    @ObservedObject var connection: IOSConnectionModel
    @State private var isChecking = false
    @State private var result: InventoryCheckResult?
    @State private var error: String?
    @StateObject private var importer = IOSForegroundImportCoordinator()
    @State private var interruptedRun: PersistedImportRun?
    #if DEBUG
    @State private var identityDiagnostics: [PhotoIdentityDiagnostic] = []
    @State private var identityDiagnosticError: String?
    @State private var originalHashRunning = false
    @State private var originalHashProgress = 0.0
    @State private var originalHashResult: OriginalContentDiagnostic?
    @State private var originalHashError: String?
    #endif

    var body: some View {
        List {
            Section("Auswahl") {
                Text("\(selection.count) ausgewählt")
                if let result {
                    LabeledContent("Bereits in Nextcloud", value: "\(result.known)")
                    LabeledContent("Neu", value: "\(result.new)")
                }
            }
            Section("Übertragungen") {
                Toggle("Mobile Daten für Übertragungen verwenden", isOn: Binding(
                    get: { connection.useCellularForTransfers },
                    set: { connection.setUseCellularForTransfers($0) }
                ))
                Text("Wenn deaktiviert, werden Fotos und Videos nur über WLAN übertragen.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            #if DEBUG
            if IOSImportDiagnostics.enabled, let result {
                Section("Ergebnis je Asset") {
                    ForEach(Array(result.assets.enumerated()), id: \.offset) { index, asset in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(asset.filename ?? "Unbenanntes Medium").lineLimit(1)
                                Text(asset.stableIdentity.hasPrefix("cloud:") ? "iCloud-Fotomediathek-ID" : "Nur lokale PhotoKit-ID")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(result.states[index] == .known ? "Bereits in Nextcloud" : "Neu")
                                .font(.caption.bold()).foregroundStyle(result.states[index] == .known ? .green : .orange)
                        }
                    }
                }
            }
            #endif
            #if DEBUG
            if IOSImportDiagnostics.enabled { Section("DEBUG: PhotoKit-Identität") {
                Button("Identität der Auswahl anzeigen") {
                    do {
                        identityDiagnostics = try library.identityDiagnostics(for: selection.assets)
                        identityDiagnosticError = nil
                    } catch {
                        identityDiagnostics = []
                        identityDiagnosticError = error.localizedDescription
                    }
                }
                if let identityDiagnosticError { Text(identityDiagnosticError).foregroundStyle(.red) }
                ForEach(identityDiagnostics) { diagnostic in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("localIdentifier: \(diagnostic.localIdentifier)").textSelection(.enabled)
                        Text("Cloud-ID vorhanden: \(diagnostic.cloudIdentifier == nil ? "nein" : "ja")")
                        Text("serialisierte Cloud-ID: \(diagnostic.cloudIdentifier ?? "<keine>")").textSelection(.enabled)
                        Text("Inventory-Identifier: \(diagnostic.inventoryIdentifier)").textSelection(.enabled)
                        if let result, let index = result.assets.firstIndex(where: { $0.localIdentifier == diagnostic.localIdentifier }) {
                            Text("Serverresultat: \(result.states[index].rawValue)")
                        } else {
                            Text("Serverresultat: noch nicht geprüft")
                        }
                    }.font(.caption.monospaced())
                }
                Text("sourceId: \(connection.parsedSourceId?.uuidString.lowercased() ?? "ungültig")").textSelection(.enabled)
            } }
            if IOSImportDiagnostics.enabled { Section("DEBUG: Original-Hash") {
                Button {
                    Task { await calculateOriginalHash() }
                } label: {
                    if originalHashRunning { Label("Original wird geladen…", systemImage: "icloud.and.arrow.down") }
                    else { Label("Original-Hash berechnen", systemImage: "number") }
                }
                .disabled(originalHashRunning || selection.count != 1)
                if originalHashRunning { ProgressView(value: originalHashProgress).accessibilityLabel("iCloud-Download und Hash-Berechnung") }
                if let originalHashError { Text(originalHashError).foregroundStyle(.red) }
                if let originalHashResult {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("localIdentifier: \(originalHashResult.localIdentifier)").textSelection(.enabled)
                        Text("cloudIdentifier: \(originalHashResult.cloudIdentifier ?? "<keine>")").textSelection(.enabled)
                        Text("resourceType: \(originalHashResult.resourceType)")
                        Text("originalFilename: \(originalHashResult.filename)").textSelection(.enabled)
                        Text("byteSize: \(originalHashResult.byteSize)")
                        Text("SHA-256: \(originalHashResult.sha256)").textSelection(.enabled)
                    }.font(.caption.monospaced())
                }
                if selection.count != 1 { Text("Genau ein Foto oder Video auswählen.").font(.footnote).foregroundStyle(.secondary) }
            } }
            #endif
            if let error { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) } }
            Section("Import") {
                if let interruptedRun {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Unterbrochene Übertragung")
                        Text("Die Übertragung wurde unterbrochen und kann fortgesetzt werden.").font(.caption).foregroundStyle(.secondary)
                        Button("Fortsetzen") { resumeImport(interruptedRun) }
                            .disabled(importer.isRunning)
                    }
                }
                let presentation = ImportPresentationPhase.resolve(phase: importer.phase, completed: importer.completed, total: importer.total, isVerifyingCompletedUpload: importer.isVerifyingCompletedUpload)
                if importer.isWaitingForWiFi {
                    Text("Warten auf WLAN …").font(.caption).foregroundStyle(.secondary)
                    Text("Die Übertragung wird fortgesetzt, sobald WLAN bereitsteht.").font(.caption).foregroundStyle(.secondary)
                } else if importer.hasActiveBackgroundTransfer {
                    Text("Übertragung läuft …").font(.caption).foregroundStyle(.secondary)
                    Text("Die Übertragung läuft weiter.").font(.caption).foregroundStyle(.secondary)
                } else if presentation == .albumSync {
                    Text("Übertragung abgeschlossen")
                    ProgressView()
                    Text("Alben werden abgeglichen …").font(.caption).foregroundStyle(.secondary)
                } else if presentation == .completed {
                    Text("Übertragung abgeschlossen")
                } else if presentation != .idle {
                    if presentation != .serverVerification, let filename = importer.currentFilename {
                        Text(filename)
                        ProgressView(value: importer.overallProgress)
                        if !importer.activeTransfers.isEmpty {
                            ForEach(importer.activeTransfers, id: \.job) { transfer in
                                Text("\(ByteCountFormatter.string(fromByteCount: transfer.sent, countStyle: .file)) von \(ByteCountFormatter.string(fromByteCount: transfer.total, countStyle: .file))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("\(importer.completed) von \(importer.total) übertragen").font(.caption).foregroundStyle(.secondary)
                    if presentation == .serverVerification {
                        Text("Übertragung abgeschlossen")
                        Text("Datei wird in Nextcloud überprüft …").font(.caption).foregroundStyle(.secondary)
                        Text("Bei großen Videos kann dies etwas dauern.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(importerStatusText).font(.caption).foregroundStyle(.secondary)
                    }
                    if importer.uploaded > 0 { Text("Übertragen: \(importer.uploaded)") }
                    if importer.alreadyPresent > 0 { Text("Bereits vorhanden: \(importer.alreadyPresent)") }
                    #if DEBUG
                    if IOSImportDiagnostics.enabled, importer.reconciled > 0 { Text("Überprüft: \(importer.reconciled)") }
                    #endif
                    if let failure = importer.failure { Text(failure).foregroundStyle(.red) }
                }
                if presentation == .albumSync || presentation == .completed {
                    if importer.uploaded > 0 { Text("Übertragen: \(importer.uploaded)") }
                    if importer.alreadyPresent > 0 { Text("Bereits vorhanden: \(importer.alreadyPresent)") }
                }
                if ImportPresentationPhase.allowsStart(phase: presentation, isRunning: importer.isRunning, hasActiveBackgroundTransfer: importer.hasActiveBackgroundTransfer, waitingForWiFi: importer.isWaitingForWiFi, hasRecoverableRun: interruptedRun != nil) {
                    Button { startImport() } label: {
                        Label("Fotos & Alben übernehmen", systemImage: "icloud.and.arrow.up")
                    }
                    .disabled(!ImportPresentationPhase.allowsNewImport(selectionCount: selection.count, canImport: connectionHasConfiguration))
                }
                if ImportPresentationPhase.showsCancel(isRunning: importer.isRunning, waitingForWiFi: importer.isWaitingForWiFi) {
                    Button("Import abbrechen") { importer.cancel() }
                }
                if ImportPresentationPhase.showsIdleHelp(phase: presentation, isRunning: importer.isRunning, hasActiveBackgroundTransfer: importer.hasActiveBackgroundTransfer, waitingForWiFi: importer.isWaitingForWiFi, hasRecoverableRun: interruptedRun != nil) {
                    Text("Die Übertragung läuft im Vordergrund. Danach werden die betroffenen Alben abgeglichen.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            #if DEBUG
            if IOSImportDiagnostics.enabled { Section {
                Button {
                    Task { await checkSelection() }
                } label: {
                    if isChecking { ProgressView("Auswahl wird geprüft…") }
                    else { Label("Auswahl prüfen", systemImage: "checkmark.circle") }
                }
                .disabled(isChecking || selection.count == 0)
                Text("Es werden nur Inventarmetadaten an Nextcloud gesendet. Diese Aktion überträgt keine Dateien.")
                    .font(.footnote).foregroundStyle(.secondary)
            } }
            #endif
        }
        .navigationTitle("Fotos & Videos übertragen")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Fertig") { dismiss() } } }
        .task { await loadInterruptedRun() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await loadInterruptedRun() } }
        }
    }

    @MainActor
    private func checkSelection() async {
        isChecking = true; error = nil; result = nil
        defer { isChecking = false }
        guard connection.parsedSourceId != nil else { error = InventoryCheckError.invalidSourceIdentifier.localizedDescription; return }
        do {
            let assets = try library.inventory(for: selection.assets)
            let reply = try await InventoryCheckClient.check(
                connection: connection.makeConnection(),
                source: PhotoSource(sourceId: connection.parsedSourceId!, name: "Apple Photos"),
                assets: assets
            )
            result = InventoryCheckResult(
                selected: assets.count,
                known: reply.summary.known,
                new: reply.summary.new,
                assets: assets,
                states: reply.assets.map(\.state)
            )
        } catch let issue as InventoryCheckError {
            error = issue.localizedDescription
        } catch UploadError.invalidConfiguration {
            error = InventoryCheckError.noServerConfiguration.localizedDescription
        } catch _ {
            error = InventoryCheckError.network.localizedDescription
        }
    }

    @MainActor
    private func startImport() {
        guard let sourceID = connection.parsedSourceId else { error = InventoryCheckError.invalidSourceIdentifier.localizedDescription; return }
        guard let serverConnection = try? connection.makeConnection() else { error = InventoryCheckError.noServerConfiguration.localizedDescription; return }
        interruptedRun = nil
            importer.start(selection: selection.assets, library: library, connection: serverConnection, source: PhotoSource(sourceId: sourceID, name: "Apple Photos"), targetRoot: connection.targetDirectory)
    }

    @MainActor
    private func loadInterruptedRun() async {
        guard let sourceID = connection.parsedSourceId else { return }
        await importer.reconcileBackgroundTasks()
        if importer.hasActiveBackgroundTransfer { interruptedRun = nil; return }
        let runs = await importer.recoverableRuns()
        interruptedRun = runs.first { run in
            run.sourceID == sourceID && run.account.serverBaseURL == connection.server && run.account.username == connection.username
                && run.assets.allSatisfy { persistedAsset in library.assets.contains { galleryAsset in galleryAsset.id == persistedAsset.localIdentifier } }
        }
    }

    @MainActor
    private func resumeImport(_ run: PersistedImportRun) {
        guard let sourceID = connection.parsedSourceId,
              let serverConnection = try? connection.makeConnection() else { return }
        let byID = Dictionary(uniqueKeysWithValues: library.assets.map { ($0.id, $0) })
        let assets = run.assets.compactMap { byID[$0.localIdentifier] }
        guard assets.count == run.assets.count else { return }
        interruptedRun = nil
        IOSImportDiagnostics.memory(phase: "resume-start")
            importer.start(selection: assets, library: library, connection: serverConnection, source: PhotoSource(sourceId: sourceID, name: "Apple Photos"), targetRoot: connection.targetDirectory, resumeRun: run)
    }

    private var connectionHasConfiguration: Bool { connection.parsedSourceId != nil }
    private var importerStatusText: String {
        switch importer.phase {
        case .inventory: "Übertragung wird vorbereitet …"
        case .exporting, .hashing, .preparing: "Dateien werden vorbereitet …"
        case .uploading: "Übertragung läuft …"
        case .completing: "Übertragung wird geprüft …"
        case .finished: "Alben werden abgeglichen …"
        default: ""
        }
    }

    #if DEBUG
    @MainActor
    private func calculateOriginalHash() async {
        guard selection.assets.count == 1, let asset = selection.assets.first else { return }
        originalHashRunning = true
        originalHashProgress = 0
        originalHashError = nil
        originalHashResult = nil
        defer { originalHashRunning = false }
        do {
            originalHashResult = try await library.originalContentDiagnostic(for: asset) { value in
                originalHashProgress = value
            }
        } catch {
            originalHashError = error.localizedDescription
        }
    }
    #endif
}

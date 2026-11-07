// SPDX-License-Identifier: AGPL-3.0-or-later
// Additional permission for app store distribution: see LICENSE.appstore.
import AnAIOdysseyAI
import AnAIOdysseyCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
// AppKit/UIKit are imported to decode images into the platform's native image
// type for display; the abstraction is unified below as `PlatformImage`.
#if os(macOS)
import AppKit
#else
import UIKit
#endif

#if os(iOS)
/// Push-navigation routes for the compact (iPhone portrait) gallery hierarchy.
/// Pops a pushed screen when its backing model object disappears (e.g. the
/// shown image was deleted). Used because the hosting navigation stack lives in
/// the phone shell, so this view can't trim a path binding directly.
struct AutoDismissWhenMissing<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let isMissing: Bool
    @ViewBuilder var content: Content

    var body: some View {
        content
            .onChange(of: isMissing) { _, missing in
                if missing { dismiss() }
            }
    }
}

enum GalleryRoute: Hashable {
    case album(String)
    case image(String)
}
#endif

/// The Gallery workspace: a three-column browser over albums, their image grids,
/// and a single image's detail.
///
/// Image bytes live on disk (managed by the gallery repository), so views resolve
/// file URLs and decode them lazily. The workspace handles album/image creation,
/// system file-importer ingestion of new photos, and confirmed deletes for both
/// albums and individual images.
struct GalleryView: View {
    /// Gallery persistence: albums, image records, and on-disk file URLs.
    @Environment(\.repositories) private var repositories
    /// Remote connections used to enumerate and call image-generation models.
    @EnvironmentObject private var providerSettings: ProviderSettings
    /// Albums backing the leading column.
    @State private var albums: [Album] = []
    /// The selected album whose images populate the middle column.
    @State private var selectedAlbumID: String?
    /// Images in the selected album.
    @State private var images: [GalleryImage] = []
    /// The image shown in the trailing detail column.
    @State private var selectedImageID: String?
    /// Drives the system photo file importer.
    @State private var showImporter = false
    /// Presents the system Photos picker (must not be nested in a Menu on iPhone).
    @State private var showPhotosPicker = false
    /// Photos-library items picked for import into the selected album.
    @State private var photosPickerItems: [PhotosPickerItem] = []
    /// Drives the AI image-generation sheet.
    @State private var showGenerateSheet = false
    /// Source image for an AI edit, when the user chose "Change with AI".
    @State private var editSource: GalleryImageEditSource?
    /// Album awaiting delete confirmation.
    @State private var albumPendingDeletion: Album?
    /// Image awaiting delete confirmation.
    @State private var imagePendingDeletion: GalleryImage?
    /// Surfaces import/IO errors.
    @State private var errorMessage: String?
    /// True when Photos is add-only/denied, so iPad generations in the library cannot be read.
    @State private var photosSyncNeedsFullAccess = false
    /// Re-import from Photos when the app returns to the foreground.
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    /// iPhone portrait is compact; a nested three-column split can't reveal its
    /// content/detail columns there, so we fall back to push navigation.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isCompact: Bool { horizontalSizeClass == .compact }
    /// Push stack for the compact albums → images → image hierarchy.
    #else
    private var isCompact: Bool { false }
    #endif

    /// Three-column split (albums → image grid → image detail) wired to the file
    /// importer and the album/image delete confirmations.
    var body: some View {
        layout
            .onAppear {
                reloadAlbums()
                Task { await syncGalleryFromSystemPhotos() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { await syncGalleryFromSystemPhotos() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: FeatureSettings.galleryContentDidChange)) { _ in
                reloadAlbums()
            }
            .onReceive(NotificationCenter.default.publisher(for: CloudKitSyncMonitor.didFinishImport)) { _ in
                Task { await syncGalleryFromSystemPhotos() }
            }
            // Switching albums clears the image selection and reloads its images.
            .onChange(of: selectedAlbumID) { _, _ in
                selectedImageID = nil
                reloadImages()
            }
            .onChange(of: photosPickerItems) { _, items in
                guard !items.isEmpty else { return }
                Task { await importPickedPhotos(items) }
            }
            .photosPicker(
                isPresented: $showPhotosPicker,
                selection: $photosPickerItems,
                maxSelectionCount: 30,
                matching: .images
            )
            // System importer for adding one or more photos to the selected album.
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.image],
                allowsMultipleSelection: true
            ) { result in
                importImages(from: result)
            }
            // AI image generation into the selected album.
            .sheet(isPresented: $showGenerateSheet) {
                GenerateImageSheet(
                    modelChoices: imageModelChoices,
                    providerSettings: providerSettings,
                    sourceImage: nil,
                    onGenerated: { data, prompt in
                        saveGeneratedImage(data: data, prompt: prompt)
                    }
                )
            }
            .sheet(item: $editSource) { source in
                GenerateImageSheet(
                    modelChoices: imageEditModelChoices,
                    providerSettings: providerSettings,
                    sourceImage: source,
                    onGenerated: { data, prompt in
                        saveGeneratedImage(data: data, prompt: prompt, albumID: source.albumID)
                    }
                )
            }
            .destructiveDeleteAlert(
                "Delete Album?",
                item: $albumPendingDeletion,
                message: { album in
                    "“\(album.name)” and its images will be permanently deleted."
                },
                confirmAction: deleteAlbum
            )
            .destructiveDeleteAlert(
                "Delete Image?",
                item: $imagePendingDeletion,
                message: { _ in
                    "This image will be permanently deleted."
                },
                confirmAction: deleteImage
            )
            .alert(
                "Gallery Error",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
    }

    /// Three-column split (macOS / iPad / iPhone landscape) or push navigation
    /// (iPhone portrait), where the split can't reveal its content/detail columns.
    @ViewBuilder
    private var layout: some View {
        #if os(iOS)
        if isCompact {
            compactBody
        } else {
            splitBody
        }
        #else
        splitBody
        #endif
    }

    private var splitBody: some View {
        NavigationSplitView {
            // Leading column: album list with create/delete.
            List(selection: $selectedAlbumID) {
                ForEach(albums, id: \.id) { album in
                    AlbumRow(album: album, imageCount: imageCount(for: album))
                        .tag(album.id)
                        .contextMenu {
                            Button("Delete Album", role: .destructive) {
                                albumPendingDeletion = album
                            }
                        }
                }
                .onDelete(perform: deleteAlbums)
            }
            .overlay {
                if albums.isEmpty {
                    emptyAlbumsPlaceholder
                }
            }
            .navigationTitle("Albums")
            .macWorkspaceSplit()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    newAlbumButton
                }
            }
        } content: {
            // Middle column: the selected album's image grid, or a prompt.
            if let selectedAlbumID {
                imageGrid(for: selectedAlbumID)
            } else {
                ContentUnavailableView(
                    "No Album Selected",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text("Create or select an album.")
                )
            }
        } detail: {
            // Trailing column: the selected image's detail, or a prompt.
            if let selectedImageID,
               let image = images.first(where: { $0.id == selectedImageID }),
               let repositories {
                ImageDetailView(
                    image: image,
                    fileURL: repositories.gallery.imageFileURL(for: image),
                    onCaptionChanged: { caption in
                        try? repositories.gallery.updateImageCaption(id: image.id, caption: caption)
                        reloadImages()
                    },
                    onChangeWithAI: {
                        beginEdit(image)
                    },
                    canChangeWithAI: !imageEditModelChoices.isEmpty,
                    onSaveToPhotos: {
                        exportToSystemPhotos(image)
                    },
                    onDelete: {
                        imagePendingDeletion = image
                    }
                )
            } else {
                ContentUnavailableView(
                    "No Image Selected",
                    systemImage: "photo",
                    description: Text("Import photos into the selected album.")
                )
            }
        }
        .removeNestedSidebarToggle()
        .workspaceNavigationSplit()
    }

    #if os(iOS)
    /// iPhone portrait: albums list → image grid → image detail, pushed in turn.
    ///
    /// No `NavigationStack` of its own: the Library tab's stack (in
    /// `PhoneRootView`) hosts these pushes, so there is exactly one navigation
    /// bar and one Back path.
    private var compactBody: some View {
        compactAlbumList
            .navigationDestination(for: GalleryRoute.self) { route in
                switch route {
                case .album(let id):
                    compactImageGrid(for: id)
                case .image(let id):
                    // The host stack owns the path, so the pushed detail pops
                    // itself if its image is deleted out from under it.
                    AutoDismissWhenMissing(isMissing: !images.contains { $0.id == id }) {
                        compactImageDetail(for: id)
                    }
                }
            }
    }

    /// Root album list for compact width; tapping an album pushes its image grid.
    private var compactAlbumList: some View {
        List {
            ForEach(albums, id: \.id) { album in
                NavigationLink(value: GalleryRoute.album(album.id)) {
                    AlbumRow(album: album, imageCount: imageCount(for: album))
                }
                .contextMenu {
                    Button("Delete Album", role: .destructive) {
                        albumPendingDeletion = album
                    }
                }
            }
            .onDelete(perform: deleteAlbums)
        }
        .navigationTitle("Albums")
        .overlay {
            if albums.isEmpty {
                emptyAlbumsPlaceholder
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                newAlbumButton
            }
        }
    }

    /// Image grid for a pushed album; tapping a thumbnail pushes its detail.
    @ViewBuilder
    private func compactImageGrid(for albumID: String) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 12) {
                ForEach(images, id: \.id) { image in
                    NavigationLink(value: GalleryRoute.image(image.id)) {
                        GalleryThumbnail(
                            image: image,
                            fileURL: repositories?.gallery.imageFileURL(for: image),
                            isSelected: false
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if let fileURL = repositories?.gallery.imageFileURL(for: image) {
                            WorkspaceImageShareLink(
                                title: WorkspaceShareContent.imageShareTitle(
                                    caption: image.caption,
                                    filename: image.filename
                                ),
                                fileURL: fileURL,
                                accessibilityIdentifier: "share-gallery-thumbnail-\(image.id)"
                            )
                        }
                        Button("Change with AI") {
                            beginEdit(image)
                        }
                        .disabled(imageEditModelChoices.isEmpty)
                        Button("Save to Photos") {
                            exportToSystemPhotos(image)
                        }
                        Button("Delete", role: .destructive) {
                            imagePendingDeletion = image
                        }
                    }
                }
            }
            .padding()
        }
        .overlay {
            if images.isEmpty {
                emptyAlbumImportPlaceholder
            }
        }
        .navigationTitle(albumTitle(for: albumID))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showPhotosPicker = true
                } label: {
                    Label("Photos", systemImage: "photo.on.rectangle")
                }
                .disabled(selectedAlbumID == nil)
                .workspaceActionButtonTint()
                .accessibilityIdentifier("import-gallery-button")
            }
            ToolbarItem(placement: .primaryAction) {
                generateButton
            }
        }
        .onAppear {
            // Load this album's images (and enable import) when it's shown.
            if selectedAlbumID != albumID {
                selectedAlbumID = albumID
            } else {
                reloadImages()
            }
        }
    }

    /// Full-size detail for a pushed image.
    @ViewBuilder
    private func compactImageDetail(for imageID: String) -> some View {
        if let image = images.first(where: { $0.id == imageID }),
           let repositories {
            ImageDetailView(
                image: image,
                fileURL: repositories.gallery.imageFileURL(for: image),
                onCaptionChanged: { caption in
                    try? repositories.gallery.updateImageCaption(id: image.id, caption: caption)
                    reloadImages()
                },
                onChangeWithAI: {
                    beginEdit(image)
                },
                canChangeWithAI: !imageEditModelChoices.isEmpty,
                onSaveToPhotos: {
                    exportToSystemPhotos(image)
                },
                onDelete: {
                    imagePendingDeletion = image
                }
            )
        } else {
            ContentUnavailableView("Image Missing", systemImage: "photo")
        }
    }
    #endif

    /// Adaptive thumbnail grid for an album, with tap-to-select, context delete,
    /// and an Import button in the toolbar.
    @ViewBuilder
    private func imageGrid(for albumID: String) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 12) {
                ForEach(images, id: \.id) { image in
                    // A real Button (not a tap gesture) so thumbnails are reachable
                    // by VoiceOver, Full Keyboard Access, and hardware keyboards.
                    Button {
                        selectedImageID = image.id
                    } label: {
                        GalleryThumbnail(
                            image: image,
                            fileURL: repositories?.gallery.imageFileURL(for: image),
                            isSelected: selectedImageID == image.id
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(thumbnailAccessibilityLabel(for: image))
                    .accessibilityAddTraits(selectedImageID == image.id ? .isSelected : [])
                    .accessibilityIdentifier("gallery-thumbnail-\(image.id)")
                    .contextMenu {
                        if let fileURL = repositories?.gallery.imageFileURL(for: image) {
                            WorkspaceImageShareLink(
                                title: WorkspaceShareContent.imageShareTitle(
                                    caption: image.caption,
                                    filename: image.filename
                                ),
                                fileURL: fileURL,
                                accessibilityIdentifier: "share-gallery-thumbnail-\(image.id)"
                            )
                        }
                        Button("Change with AI") {
                            beginEdit(image)
                        }
                        .disabled(imageEditModelChoices.isEmpty)
                        Button("Save to Photos") {
                            exportToSystemPhotos(image)
                        }
                        Button("Delete", role: .destructive) {
                            imagePendingDeletion = image
                        }
                    }
                }
            }
            .padding()
        }
        .overlay {
            if images.isEmpty {
                emptyAlbumImportPlaceholder
            }
        }
        .navigationTitle(albumTitle(for: albumID))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                importMenu
            }
            ToolbarItem(placement: .primaryAction) {
                generateButton
            }
        }
    }

    /// Spoken label for a thumbnail: the caption when set, else a generic name.
    private func thumbnailAccessibilityLabel(for image: GalleryImage) -> String {
        if let caption = image.caption, !caption.isEmpty {
            return caption
        }
        return "Image added \(image.createdAt.formatted(date: .abbreviated, time: .omitted))"
    }

    /// Opens the AI generation sheet; disabled when no album is selected or no
    /// image-generation model is configured.
    private var generateButton: some View {
        Button {
            showGenerateSheet = true
        } label: {
            Label("Generate", systemImage: "sparkles")
        }
        .disabled(imageModelChoices.isEmpty)
        .help(
            imageModelChoices.isEmpty
                ? "Configure a remote connection that serves an image model (e.g. gpt-image-1) to generate images."
                : "Generate an image with an AI model and save it to this album."
        )
        .accessibilityIdentifier("generate-gallery-image-button")
    }

    /// Import from the system Photos library (primary) or from files.
    ///
    /// The picker itself is presented with `.photosPicker(isPresented:)` — nesting
    /// `PhotosPicker` inside a `Menu` never opens on iPhone.
    private var importMenu: some View {
        Menu {
            Button("From Photos Library", systemImage: "photo.on.rectangle") {
                showPhotosPicker = true
            }
            Button("From Files…", systemImage: "folder") {
                showImporter = true
            }
        } label: {
            Label("Import", systemImage: "photo.on.rectangle")
        }
        .disabled(selectedAlbumID == nil)
        .workspaceActionButtonTint()
        .help("Import photos from the Photos library or from files.")
        .accessibilityIdentifier("import-gallery-button")
    }

    /// Compact plus control so it isn't clipped behind the split-view overflow chevrons.
    private var newAlbumButton: some View {
        Button(action: createAlbum) {
            Label("New Album", systemImage: "plus")
        }
        .workspaceActionButtonTint()
        .help("Create a new album")
        .accessibilityIdentifier("new-album-button")
    }

    /// Empty-state with an in-content New Album action, so creating an album
    /// does not depend on the (often overflowed) toolbar.
    private var emptyAlbumsPlaceholder: some View {
        ContentUnavailableView {
            Label("No Albums", systemImage: "photo.on.rectangle.angled")
        } description: {
            if photosSyncNeedsFullAccess {
                Text("Images generated on your iPad are in Photos. Open Settings, tap Photos, and choose Full Access so they can appear here.")
            } else {
                Text("Create an album to store photos.")
            }
        } actions: {
            Button("New Album", systemImage: "plus", action: createAlbum)
                .accessibilityIdentifier("new-album-empty-button")
            if photosSyncNeedsFullAccess {
                Button("Open Settings") {
                    SystemPhotoLibrary.openAppSettings()
                }
            }
        }
    }

    /// Empty album with a Photos-library import action that actually presents on iPhone.
    private var emptyAlbumImportPlaceholder: some View {
        ContentUnavailableView {
            Label("No Photos", systemImage: "photo.on.rectangle")
        } description: {
            if photosSyncNeedsFullAccess {
                Text("Images generated on your iPad are in Photos but this iPhone cannot read them. Open Settings, tap Photos, and choose Full Access.")
            } else {
                Text("Import from your Photos library, including images generated on your other devices.")
            }
        } actions: {
            Button("From Photos", systemImage: "photo.on.rectangle") {
                showPhotosPicker = true
            }
            .accessibilityIdentifier("import-from-photos-button")
            Button("From Files", systemImage: "folder") {
                showImporter = true
            }
            if photosSyncNeedsFullAccess {
                Button("Open Settings") {
                    SystemPhotoLibrary.openAppSettings()
                }
            }
        }
    }

    /// Image-generation models offered by the configured remote connections.
    private var imageModelChoices: [ImageGenerationModelChoice] {
        ImageGenerationCatalog.availableModels(providerSettings: providerSettings)
    }

    /// Image models that can take a selected photo and change it.
    private var imageEditModelChoices: [ImageGenerationModelChoice] {
        ImageGenerationCatalog.availableEditModels(providerSettings: providerSettings)
    }

    /// Opens the AI edit sheet for a gallery image already in the photos database.
    private func beginEdit(_ image: GalleryImage) {
        guard let repositories else { return }
        let url = repositories.gallery.imageFileURL(for: image)
        guard let data = try? Data(contentsOf: url) else {
            errorMessage = "Could not read this image."
            return
        }
        editSource = GalleryImageEditSource(
            albumID: image.albumID,
            filename: image.filename,
            data: data
        )
    }

    /// Saves freshly generated or edited image bytes into the selected album
    /// (or the AI Generated album when none is selected) and records them in Photos.
    private func saveGeneratedImage(data: Data, prompt: String, albumID: String? = nil) {
        guard let repositories else { return }
        do {
            FeatureSettings.enableGallery()
            let targetAlbumID: String
            if let albumID = albumID ?? selectedAlbumID {
                targetAlbumID = albumID
            } else {
                targetAlbumID = try GeneratedImagesAlbum.findOrCreate(in: repositories.gallery).id
            }
            let image = try repositories.gallery.importImage(
                albumID: targetAlbumID,
                data: data,
                suggestedFilename: ImageGenerationCatalog.filename(for: prompt),
                caption: prompt
            )
            selectedAlbumID = targetAlbumID
            reloadAlbums()
            selectedImageID = image.id
            FeatureSettings.noteGalleryContentChanged()
            let albumName = (try? repositories.gallery.fetchAlbum(id: targetAlbumID))?.name
                ?? GeneratedImagesAlbum.name
            Task {
                await SystemPhotoLibrary.saveImageIfAllowed(data, albumName: albumName)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Display name for an album id, used as the grid's navigation title.
    private func albumTitle(for albumID: String) -> String {
        albums.first(where: { $0.id == albumID })?.name ?? "Gallery"
    }

    /// Image count for an album row. Uses the already-loaded array for the active
    /// album to avoid a redundant fetch; queries storage for the rest.
    private func imageCount(for album: Album) -> Int {
        if album.id == selectedAlbumID {
            return images.count
        }
        return visibleImages(in: album.id).count
    }

    /// Reloads albums, keeps a valid album selection, and refreshes its images.
    private func reloadAlbums() {
        guard let repositories else { return }
        albums = ((try? repositories.gallery.listAlbums()) ?? []).sorted { lhs, rhs in
            if lhs.name == GeneratedImagesAlbum.name { return true }
            if rhs.name == GeneratedImagesAlbum.name { return false }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        if selectedAlbumID == nil {
            selectedAlbumID = albums.first?.id
        } else if !albums.contains(where: { $0.id == selectedAlbumID }) {
            selectedAlbumID = albums.first?.id
        }
        reloadImages()
    }

    /// Images whose files are actually on disk (CloudKit can sync metadata first).
    private func visibleImages(in albumID: String) -> [GalleryImage] {
        guard let repositories else { return [] }
        let listed = (try? repositories.gallery.listImages(albumID: albumID)) ?? []
        return listed.filter {
            FileManager.default.fileExists(atPath: repositories.gallery.imageFileURL(for: $0).path)
        }
    }

    /// Pulls the shared Photos “AI Generated” album (and matching albums) into the gallery.
    private func syncGalleryFromSystemPhotos() async {
        guard let repositories else { return }
        _ = await PhotosGallerySync.run(gallery: repositories.gallery)
        photosSyncNeedsFullAccess = SystemPhotoLibrary.isAddOnly
            || (!SystemPhotoLibrary.canReadPhotos && SystemPhotoLibrary.authorizationStatus == .denied)
        reloadAlbums()
    }

    /// Reloads the selected album's images and keeps the image selection valid.
    private func reloadImages() {
        guard let repositories, let selectedAlbumID else {
            images = []
            return
        }
        images = visibleImages(in: selectedAlbumID)
        if let selectedImageID, !images.contains(where: { $0.id == selectedImageID }) {
            self.selectedImageID = images.first?.id
        }
    }

    /// Creates a new album and selects it.
    private func createAlbum() {
        guard let repositories else { return }
        let album = try? repositories.gallery.createAlbum(name: "New Album", description: nil)
        reloadAlbums()
        selectedAlbumID = album?.id
    }

    /// Swipe-to-delete handler mapping list offsets to albums.
    private func deleteAlbums(at offsets: IndexSet) {
        for index in offsets {
            deleteAlbum(albums[index])
        }
    }

    /// Deletes an album (and its images), clearing selection if it was active.
    private func deleteAlbum(_ album: Album) {
        guard let repositories else { return }
        let deletedID = album.id
        try? repositories.gallery.deleteAlbum(id: deletedID)
        if selectedAlbumID == deletedID {
            selectedAlbumID = nil
            selectedImageID = nil
        }
        albumPendingDeletion = nil
        reloadAlbums()
    }

    /// Deletes a single image, clearing selection if it was shown, then refreshes
    /// both the image grid and album counts.
    private func deleteImage(_ image: GalleryImage) {
        guard let repositories else { return }
        let deletedID = image.id
        try? repositories.gallery.deleteImage(id: deletedID)
        if selectedImageID == deletedID {
            selectedImageID = nil
        }
        imagePendingDeletion = nil
        // In compact width the pushed image detail pops itself via
        // `AutoDismissWhenMissing` once the reload drops the deleted image.
        reloadImages()
        reloadAlbums()
    }

    /// Ingests photos picked from the system Photos library into the selected album.
    ///
    /// The system picker does not require library permission; we still try several
    /// transferable representations because HEIC often fails as a generic `.image`.
    private func importPickedPhotos(_ items: [PhotosPickerItem]) async {
        defer { photosPickerItems = [] }
        guard let repositories, let selectedAlbumID else { return }
        var imported = 0
        for item in items {
            do {
                guard let data = await imageData(from: item) else { continue }
                _ = try repositories.gallery.importImage(
                    albumID: selectedAlbumID,
                    data: data,
                    suggestedFilename: "photo.\(ImageFileCodec.preferredFileExtension(for: data, suggestedFilename: "photo.heic"))",
                    caption: nil
                )
                imported += 1
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        if imported == 0, !items.isEmpty, errorMessage == nil {
            errorMessage = "Could not read the selected photo(s) from the library."
        }
        reloadImages()
        reloadAlbums()
        FeatureSettings.noteGalleryContentChanged()
    }

    /// Loads image bytes from a Photos picker item (JPEG, HEIC, PNG, or generic image).
    private func imageData(from item: PhotosPickerItem) async -> Data? {
        if let picked = try? await item.loadTransferable(type: GalleryPickedImage.self), !picked.data.isEmpty {
            return picked.data
        }
        if let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty {
            return data
        }
        return nil
    }

    /// Copies a gallery image into the system Photos library.
    private func exportToSystemPhotos(_ image: GalleryImage) {
        guard let repositories else { return }
        let url = repositories.gallery.imageFileURL(for: image)
        guard let data = try? Data(contentsOf: url) else {
            errorMessage = "Could not read this image."
            return
        }
        let albumName = albums.first(where: { $0.id == image.albumID })?.name
            ?? GeneratedImagesAlbum.name
        Task {
            do {
                try await SystemPhotoLibrary.saveImage(data, albumName: albumName)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Ingests user-picked photos into the selected album.
    ///
    /// Each picked URL is a security-scoped resource, so access is explicitly
    /// started/stopped around the read. The filename (minus extension) seeds the
    /// caption. Per-file errors are surfaced without aborting the whole batch.
    private func importImages(from result: Result<[URL], Error>) {
        guard let repositories, let selectedAlbumID else { return }
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let urls):
            Task {
                for url in urls {
                    // Sandboxed file access must be bracketed for picked URLs.
                    guard url.startAccessingSecurityScopedResource() else { continue }
                    defer { url.stopAccessingSecurityScopedResource() }
                    do {
                        let data = try Data(contentsOf: url)
                        _ = try repositories.gallery.importImage(
                            albumID: selectedAlbumID,
                            data: data,
                            suggestedFilename: url.lastPathComponent,
                            caption: url.deletingPathExtension().lastPathComponent
                        )
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                reloadImages()
                reloadAlbums()
                FeatureSettings.noteGalleryContentChanged()
            }
        }
    }
}

/// Source image for an AI edit, loaded from the photos gallery database.
private struct GalleryImageEditSource: Identifiable {
    let id = UUID()
    let albumID: String
    let filename: String
    let data: Data
}

/// Prompt + model form that generates a new image or edits a selected photo,
/// then hands the resulting bytes back for saving into the photos database.
private struct GenerateImageSheet: View {
    /// The image-generation models the user can pick from.
    let modelChoices: [ImageGenerationModelChoice]
    /// Connection lookup + adapter configuration for the picked model.
    let providerSettings: ProviderSettings
    /// When set, the prompt is applied as an edit to this existing photo.
    let sourceImage: GalleryImageEditSource?
    /// Called with the image bytes and the prompt once generation succeeds.
    let onGenerated: (Data, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var prompt = ""
    @State private var selectedChoiceID = ""
    @State private var modelSelectionKey = ""
    @State private var isGenerating = false
    @State private var errorMessage: String?

    private var selectedChoice: ImageGenerationModelChoice? {
        modelChoices.first { $0.id == selectedChoiceID }
    }

    private var isEditing: Bool { sourceImage != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isEditing ? "Change Image" : "Generate Image")
                .font(.headline)

            if let sourceImage, let preview = PlatformImage(data: sourceImage.data) {
                preview
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if isEditing {
                if modelChoices.isEmpty {
                    StatusMessage(
                        kind: .error,
                        text: "Configure a remote image model that supports edits (gpt-image-1 or dall-e-2)."
                    )
                } else {
                    Picker("Model", selection: $selectedChoiceID) {
                        ForEach(modelChoices) { choice in
                            Text(choice.pickerLabel).tag(choice.id)
                        }
                    }
                    .accessibilityIdentifier("gallery-image-model-picker")
                }
            } else {
                WorkspaceModelPicker(
                    label: "Model",
                    selectionKey: $modelSelectionKey,
                    providerSettings: providerSettings,
                    accessibilityIdentifier: "gallery-image-model-picker",
                    pickerScope: .imageOnly
                )
            }

            ModelPickerOptionsView(
                selectionKey: imageOptionsSelectionKey,
                style: .expanded
            )

            TextField(
                isEditing ? "Describe how to change this image…" : "Describe the image…",
                text: $prompt,
                axis: .vertical
            )
            .lineLimit(3...6)
            .workspaceFormField()
            .accessibilityIdentifier("gallery-image-prompt-field")

            if let errorMessage {
                StatusMessage(kind: .error, text: errorMessage)
            }

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                if isGenerating {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(isEditing ? "Change" : "Generate", action: generate)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        isGenerating
                            || !hasImageModelSelection
                            || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    .accessibilityIdentifier("gallery-generate-image-button")
            }
        }
        .padding(20)
        .frame(minWidth: 420)
        .onAppear {
            if selectedChoiceID.isEmpty {
                selectedChoiceID = modelChoices.first?.id ?? ""
            }
        }
    }

    private var hasImageModelSelection: Bool {
        if isEditing { return selectedChoice != nil }
        return ConfiguredModelRegistry.parseSelectionKey(modelSelectionKey) != nil
    }

    private var imageOptionsSelectionKey: String {
        if isEditing, let choice = selectedChoice {
            return ConfiguredModelRegistry.selectionKey(
                modelID: choice.modelID,
                backend: .remote,
                connectionID: choice.connectionID
            )
        }
        return modelSelectionKey
    }

    /// Runs generation or edit against the picked model's connection, then hands
    /// the bytes back and dismisses. Errors stay in the sheet for retry.
    private func generate() {
        let resolved: (connection: RemoteConnection, modelID: String)? = {
            if isEditing {
                guard let choice = selectedChoice,
                      let connection = providerSettings.connection(id: choice.connectionID) else {
                    return nil
                }
                return (connection, choice.modelID)
            }
            guard let parsed = ConfiguredModelRegistry.parseSelectionKey(modelSelectionKey),
                  let connectionID = parsed.connectionID,
                  let connection = providerSettings.connection(id: connectionID) else {
                return nil
            }
            return (connection, parsed.modelID)
        }()
        guard let resolved else {
            errorMessage = "The selected model's connection is no longer configured."
            return
        }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }

        isGenerating = true
        errorMessage = nil
        Task { @MainActor in
            defer { isGenerating = false }
            do {
                let service = RemoteLLMService(settings: providerSettings)
                service.activate(connection: resolved.connection, modelID: resolved.modelID)
                let data: Data
                if let sourceImage {
                    data = try await service.editImage(
                        prompt: trimmedPrompt,
                        imageData: sourceImage.data,
                        filename: sourceImage.filename,
                        modelID: resolved.modelID
                    )
                } else {
                    data = try await service.generateImage(
                        prompt: trimmedPrompt,
                        modelID: resolved.modelID
                    )
                }
                onGenerated(data, trimmedPrompt)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// A sidebar row for an album: its name, optional description, and image count.
private struct AlbumRow: View {
    let album: Album
    let imageCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(album.name)
                .font(.headline)
            if let description = album.albumDescription, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text("\(imageCount) image\(imageCount == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// A grid cell rendering an album image's thumbnail with a caption overlay and a
/// selection ring. Falls back to a placeholder when the file can't be decoded.
private struct GalleryThumbnail: View {
    let image: GalleryImage
    /// On-disk location of the image bytes; `nil` if unresolved.
    let fileURL: URL?
    /// Whether this cell is the current detail selection (draws the accent ring).
    let isSelected: Bool

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Decoded thumbnail, or a placeholder when the file is missing/unreadable.
            if let fileURL, let platformImage = PlatformImage(contentsOf: fileURL) {
                platformImage
                    .resizable()
                    .scaledToFill()
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 120, maxHeight: 120)
                    .clipped()
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .frame(height: 120)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
            }

            // Caption strip across the bottom when present.
            if let caption = image.caption, !caption.isEmpty {
                Text(caption)
                    .font(.caption2)
                    .lineLimit(1)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        // Accent ring marks the selected thumbnail.
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        }
        .accessibilityIdentifier("gallery-image-\(image.id)")
    }
}

/// Full-size detail for a selected image with an editable caption and delete.
///
/// The caption is seeded into local `@State` so it can be edited freely and only
/// pushed back to storage on commit/save; an empty string is normalized to `nil`.
private struct ImageDetailView: View {
    let image: GalleryImage
    /// On-disk location of the full-resolution image.
    let fileURL: URL
    /// Persists a caption edit (`nil` clears it).
    let onCaptionChanged: (String?) -> Void
    /// Opens the AI edit sheet for this photo.
    let onChangeWithAI: () -> Void
    /// Whether an edit-capable image model is configured.
    let canChangeWithAI: Bool
    /// Copies this image into the system Photos library.
    let onSaveToPhotos: () -> Void
    /// Requests deletion of this image (parent confirms).
    let onDelete: () -> Void

    /// Locally edited caption, seeded from the model on init.
    @State private var caption: String

    init(
        image: GalleryImage,
        fileURL: URL,
        onCaptionChanged: @escaping (String?) -> Void,
        onChangeWithAI: @escaping () -> Void,
        canChangeWithAI: Bool,
        onSaveToPhotos: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.image = image
        self.fileURL = fileURL
        self.onCaptionChanged = onCaptionChanged
        self.onChangeWithAI = onChangeWithAI
        self.canChangeWithAI = canChangeWithAI
        self.onSaveToPhotos = onSaveToPhotos
        self.onDelete = onDelete
        _caption = State(initialValue: image.caption ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let platformImage = PlatformImage(contentsOf: fileURL) {
                platformImage
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Image Missing", systemImage: "photo")
            }

            TextField("Caption", text: $caption, onCommit: {
                onCaptionChanged(caption.isEmpty ? nil : caption)
            })
            .workspaceFormField()

            HStack {
                Button("Save Caption") {
                    onCaptionChanged(caption.isEmpty ? nil : caption)
                }
                Button("Change with AI", action: onChangeWithAI)
                    .disabled(!canChangeWithAI)
                    .help(
                        canChangeWithAI
                            ? "Send this photo to an AI image model and save the result in the gallery."
                            : "Configure gpt-image-1 or dall-e-2 to change an existing photo."
                    )
                    .accessibilityIdentifier("gallery-change-image-button")
                WorkspaceImageShareLink(
                    title: WorkspaceShareContent.imageShareTitle(
                        caption: image.caption,
                        filename: image.filename
                    ),
                    fileURL: fileURL,
                    accessibilityIdentifier: "share-image-button"
                )
                Button("Save to Photos", action: onSaveToPhotos)
                    .help("Copy this image into the Photos app.")
                    .accessibilityIdentifier("gallery-save-to-photos-button")
                Button("Delete", role: .destructive, action: onDelete)
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .navigationTitle(image.caption?.isEmpty == false ? image.caption! : "Image")
    }
}

// Cross-platform bridge for loading a SwiftUI `Image` directly from a file URL.
// Each platform decodes via its native image type (NSImage / UIImage), failing
// gracefully to `nil` so callers can show a placeholder.
#if os(macOS)
private typealias PlatformImage = Image

private extension Image {
    /// macOS: decode the file into an `NSImage` and wrap it as a SwiftUI `Image`.
    init?(contentsOf url: URL) {
        guard let nsImage = NSImage(contentsOf: url) else { return nil }
        self.init(nsImage: nsImage)
    }

    init?(data: Data) {
        guard let nsImage = NSImage(data: data) else { return nil }
        self.init(nsImage: nsImage)
    }
}
#else
private typealias PlatformImage = Image

private extension Image {
    /// iOS: decode the file into a `UIImage` and wrap it as a SwiftUI `Image`.
    init?(contentsOf url: URL) {
        guard let uiImage = UIImage(contentsOfFile: url.path) else { return nil }
        self.init(uiImage: uiImage)
    }

    init?(data: Data) {
        guard let uiImage = UIImage(data: data) else { return nil }
        self.init(uiImage: uiImage)
    }
}
#endif

/// Bytes loaded from a `PhotosPicker` selection. HEIC/JPEG are listed explicitly
/// because a generic `.image` type often fails to transfer on iPhone.
private struct GalleryPickedImage: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .jpeg) { GalleryPickedImage(data: $0) }
        DataRepresentation(importedContentType: .heic) { GalleryPickedImage(data: $0) }
        DataRepresentation(importedContentType: .heif) { GalleryPickedImage(data: $0) }
        DataRepresentation(importedContentType: .png) { GalleryPickedImage(data: $0) }
        DataRepresentation(importedContentType: .webP) { GalleryPickedImage(data: $0) }
        DataRepresentation(importedContentType: .gif) { GalleryPickedImage(data: $0) }
        DataRepresentation(importedContentType: .tiff) { GalleryPickedImage(data: $0) }
        DataRepresentation(importedContentType: .image) { GalleryPickedImage(data: $0) }
    }
}

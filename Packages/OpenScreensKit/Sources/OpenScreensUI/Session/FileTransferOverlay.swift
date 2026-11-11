import OpenScreensCore
import rootshellVNC
import SwiftUI

/// What is shown over the picture while files are dragged to or from a Mac:
/// the place to drag files for copying them back, and the list of copies
/// under way.
///
/// It is laid over the canvas itself, so its coordinates are the canvas's.
struct FileTransferOverlay: View {
    let session: RemoteSession

    /// Transfers the user has dismissed, or that finished well long enough
    /// ago to go away by themselves.
    @State private var hidden: Set<UUID> = []
    /// Finished uploads that are on their way out, so that each is sent off
    /// once however many times the list changes meanwhile.
    @State private var leaving: Set<UUID> = []

    private static let space = "file-transfer-canvas"

    var body: some View {
        let transfers = session.fileTransfers
        let rows = transfers.transfers.filter { $0.state != .dragging && !hidden.contains($0.id) }

        ZStack(alignment: .topLeading) {
            Color.clear

            if transfers.showsDragOutTarget, session.canFetchFiles {
                FileFetchTarget(
                    names: transfers.remoteDraggedNames,
                    isTargeted: transfers.remoteDragOverTarget)
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .named(Self.space))
                    } action: { frame in
                        session.setFileTarget(viewRect: frame)
                    }
                    .onDisappear { session.setFileTarget(viewRect: nil) }
                    .position(targetCentre)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }

            if !rows.isEmpty {
                FileTransferList(
                    rows: rows,
                    kept: session.fetchedFiles,
                    onCancel: { transfers.cancel($0.id) },
                    onDismiss: dismiss)
                    #if os(macOS)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 14)
                    .padding(.bottom, 14)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    #else
                    // The controls float along the bottom of the screen, so
                    // the list keeps to the top, under the place files are
                    // dragged to when that is showing.
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.horizontal, 12 + max(session.viewport.insets.left, session.viewport.insets.right))
                    .padding(.top, listTop)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    #endif
            }
        }
        .coordinateSpace(.named(Self.space))
        #if os(iOS)
        // The canvas runs under the notch and the home indicator and keeps
        // the picture clear of them itself. This has to cover exactly the
        // same ground, or where the target is drawn and where the Mac is
        // told it is would differ by the height of the notch.
        .ignoresSafeArea()
        #endif
        .animation(.snappy(duration: 0.22), value: transfers.showsDragOutTarget)
        .animation(.snappy(duration: 0.22), value: rows.map(\.id))
        .onChange(of: transfers.transfers) { _, current in
            settle(current)
        }
    }

    /// The target sits at the top of the picture, not of the view: the bars
    /// beside a picture that does not fill the view are nowhere on the Mac's
    /// screen, so the pointer there could never be over it.
    private var targetCentre: CGPoint {
        let viewport = session.viewport
        let picture = viewport.contentRect.intersection(viewport.usableRect)
        let area = picture.isNull || picture.isEmpty ? viewport.usableRect : picture
        return CGPoint(
            x: area.midX,
            y: area.minY + 16 + FileFetchTarget.size.height / 2)
    }

    #if os(iOS)
    private var listTop: CGFloat {
        let top = session.viewport.insets.top + 12
        guard session.fileTransfers.showsDragOutTarget else { return top }
        return targetCentre.y + FileFetchTarget.size.height / 2 + 12
    }
    #endif

    /// Puts finished downloads where they belong and lets finished uploads
    /// go after a moment; anything that failed stays until dismissed.
    private func settle(_ transfers: [VNCFileTransfer]) {
        for transfer in transfers where transfer.direction == .upload && !transfer.isActive {
            session.releaseSentFiles(of: transfer.id)
        }
        for transfer in transfers where transfer.direction == .download && !transfer.isActive {
            // What arrived is kept even when not everything did.
            session.keepFetchedFiles(of: transfer)
        }
        for transfer in transfers where transfer.state == .completed {
            switch transfer.direction {
            case .download:
                break
            case .upload:
                guard !hidden.contains(transfer.id), !leaving.contains(transfer.id) else { continue }
                let id = transfer.id
                leaving.insert(id)
                Task {
                    try? await Task.sleep(for: .seconds(6))
                    leaving.remove(id)
                    hidden.insert(id)
                    session.fileTransfers.remove(id)
                }
            }
        }
        let present = Set(transfers.map(\.id))
        hidden.formIntersection(present)
        for id in session.fetchedFiles.keys where !present.contains(id) {
            session.forgetFetchedFiles(of: id)
        }
    }

    private func dismiss(_ transfer: VNCFileTransfer) {
        hidden.insert(transfer.id)
        if transfer.direction == .download, session.fetchedFiles[transfer.id] != nil {
            // The files have been moved to where the user will find them;
            // what is left is the empty folder they arrived in.
            session.fileTransfers.downloadWasSaved(transfer.id)
        } else {
            session.fileTransfers.remove(transfer.id)
        }
    }
}

/// Where to let go of files dragged on the Mac to copy them here.
struct FileFetchTarget: View {
    let names: [String]
    let isTargeted: Bool

    static let size = CGSize(width: 280, height: 58)

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "arrow.down.circle")
                .symbolVariant(isTargeted ? .fill : .none)
                .font(.title2)
            VStack(alignment: .leading, spacing: 1) {
                Text(isTargeted ? "Let Go to Copy Here" : "Drag Here to Copy to \(Self.deviceName)")
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(Self.summary(of: names))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .opacity(0.85)
            }
        }
        // It lies over someone else's screen, which may be any colour, a
        // white window as likely as a dark desktop: tinted glass and white
        // lettering read on all of them, where plain glass would not.
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .frame(width: Self.size.width, height: Self.size.height)
        .glassEffect(
            .regular.tint(Color.accentColor.opacity(isTargeted ? 0.95 : 0.7)), in: .capsule)
        .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
        .scaleEffect(isTargeted ? 1.05 : 1)
        .animation(.snappy(duration: 0.15), value: isTargeted)
        // The drag belongs to the picture underneath, which has to go on
        // hearing about it while the pointer is over this.
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    static var deviceName: String {
        #if os(macOS)
        "This Mac"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "This iPad" : "This iPhone"
        #endif
    }

    static func summary(of names: [String]) -> String {
        switch names.count {
        case 0: "Files"
        case 1: names[0]
        default: "\(names[0]) and \(names.count - 1) more"
        }
    }
}

/// Copies under way and just finished, newest first.
private struct FileTransferList: View {
    let rows: [VNCFileTransfer]
    let kept: [UUID: [URL]]
    let onCancel: (VNCFileTransfer) -> Void
    let onDismiss: (VNCFileTransfer) -> Void

    var body: some View {
        VStack(spacing: 8) {
            ForEach(rows.reversed().prefix(4)) { transfer in
                FileTransferRow(
                    transfer: transfer,
                    kept: kept[transfer.id] ?? [],
                    onCancel: { onCancel(transfer) },
                    onDismiss: { onDismiss(transfer) })
            }
        }
        .frame(maxWidth: 340)
    }
}

private struct FileTransferRow: View {
    let transfer: VNCFileTransfer
    let kept: [URL]
    let onCancel: () -> Void
    let onDismiss: () -> Void

    @State private var isChoosingFolder = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 3) {
                Text(transfer.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if transfer.isActive {
                    if transfer.state == .transferring, let fraction = transfer.fractionCompleted {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                Text(status)
                    .font(.caption)
                    .foregroundStyle(isFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if transfer.isActive {
                iconButton("Cancel", systemName: "xmark.circle.fill", action: onCancel)
            } else {
                if transfer.direction == .download, !kept.isEmpty {
                    #if os(macOS)
                    iconButton("Show in Finder", systemName: "magnifyingglass.circle.fill") {
                        NSWorkspace.shared.activateFileViewerSelecting(kept)
                    }
                    #else
                    iconButton("Save to Files", systemName: "square.and.arrow.down.fill") {
                        isChoosingFolder = true
                    }
                    #endif
                }
                iconButton("Dismiss", systemName: "xmark.circle.fill", action: onDismiss)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .glassPanel(cornerRadius: 18)
        #if os(iOS)
        .fileMover(isPresented: $isChoosingFolder, files: kept) { result in
            if case .success = result { onDismiss() }
        }
        #endif
    }

    private func iconButton(_ label: String, systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .symbolRenderingMode(.hierarchical)
                .font(.title3)
                .frame(width: 30, height: 30)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }

    private var symbol: String {
        switch transfer.state {
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        case .completed: "checkmark.circle.fill"
        default: transfer.direction == .upload ? "arrow.up.circle" : "arrow.down.circle"
        }
    }

    private var tint: Color {
        switch transfer.state {
        case .failed: .red
        case .completed: .green
        case .cancelled: .secondary
        default: .accentColor
        }
    }

    private var isFailure: Bool {
        if case .failed = transfer.state { true } else { false }
    }

    private var status: String {
        switch transfer.state {
        case .dragging:
            return ""
        case .preparing:
            return transfer.direction == .upload ? "Waiting for the Mac…" : "Starting…"
        case .transferring:
            let done = ByteCountFormatter.string(fromByteCount: transfer.completedBytes, countStyle: .file)
            guard transfer.totalBytes > 0 else { return done }
            let total = ByteCountFormatter.string(fromByteCount: transfer.totalBytes, countStyle: .file)
            return "\(done) of \(total)"
        case .completed:
            switch transfer.direction {
            case .upload:
                if let folder = transfer.remoteFolder, !folder.isEmpty {
                    return "Copied to \((folder as NSString).lastPathComponent) on the Mac"
                }
                return "Copied to the Mac"
            case .download:
                #if os(macOS)
                return kept.isEmpty ? "Copied" : "In your Downloads folder"
                #else
                return "Ready to save"
                #endif
            }
        case .failed(let message):
            return message
        case .cancelled:
            return "Cancelled"
        }
    }
}

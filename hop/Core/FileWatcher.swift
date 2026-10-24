import Foundation

/// Calls `onChange` (debounced, on the main actor) when a file changes, however it is
/// saved: an editor that replaces the file shows up on its folder, an in-place write
/// (VS Code, scripts) only on the file itself. The file is watched again after every
/// change, because a replaced file is a new inode.
final class FileWatcher {
    let url: URL
    private let onChange: () -> Void
    private var folder: DispatchSourceFileSystemObject?
    private var file: DispatchSourceFileSystemObject?
    private var pending: Task<Void, Never>?

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        folder = source(url.deletingLastPathComponent().path, [.write, .rename, .delete])
        file = source(url.path, [.write, .extend, .rename, .delete])
    }

    func stop() {
        pending?.cancel()
        folder?.cancel()
        file?.cancel()
        folder = nil
        file = nil
    }

    private func source(_ path: String, _ mask: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
        s.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.changed() } }
        s.setCancelHandler { close(fd) }
        s.resume()
        return s
    }

    private func changed() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled else { return }
            file?.cancel()
            file = source(url.path, [.write, .extend, .rename, .delete])
            onChange()
        }
    }
}

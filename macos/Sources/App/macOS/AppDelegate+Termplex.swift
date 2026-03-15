import AppKit

// MARK: Termplex Delegate

/// This implements the Termplex app delegate protocol which is used by the Termplex
/// APIs for app-global information.
extension AppDelegate: Termplex.Delegate {
    func termplexSurface(id: UUID) -> Termplex.SurfaceView? {
        for window in NSApp.windows {
            guard let controller = window.windowController as? BaseTerminalController else {
                continue
            }

            for surface in controller.surfaceTree where surface.id == id {
                return surface
            }
        }

        return nil
    }
}

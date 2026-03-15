import Foundation

extension Termplex {
    /// This is a delegate that should be applied to your global app delegate for TermplexKit
    /// to perform app-global operations.
    protocol Delegate {
        /// Look up a surface within the application by ID.
        func termplexSurface(id: UUID) -> SurfaceView?
    }
}

enum TermplexIntentError: Error, CustomLocalizedStringResourceConvertible {
    case appUnavailable
    case surfaceNotFound
    case permissionDenied

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appUnavailable: "The Termplex app isn't properly initialized."
        case .surfaceNotFound: "The terminal no longer exists."
        case .permissionDenied: "Termplex doesn't allow Shortcuts."
        }
    }
}

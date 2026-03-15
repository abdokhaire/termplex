extension Termplex {
    /// Possible errors from internal Termplex calls.
    enum Error: Swift.Error, CustomLocalizedStringResourceConvertible {
        case apiFailed

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .apiFailed: return "libtermplex API call failed"
            }
        }
    }
}

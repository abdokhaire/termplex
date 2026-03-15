import TermplexKit

extension FullscreenMode {
    /// Initialize from a Termplex fullscreen action.
    static func from(termplex: termplex_action_fullscreen_e) -> Self? {
        return switch termplex {
        case TERMPLEX_FULLSCREEN_NATIVE:
                .native

        case TERMPLEX_FULLSCREEN_MACOS_NON_NATIVE:
                .nonNative

        case TERMPLEX_FULLSCREEN_MACOS_NON_NATIVE_VISIBLE_MENU:
                .nonNativeVisibleMenu

        case TERMPLEX_FULLSCREEN_MACOS_NON_NATIVE_PADDED_NOTCH:
                .nonNativePaddedNotch

        default:
            nil
        }
    }
}

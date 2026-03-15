import Foundation

extension UserDefaults {
    static var termplexSuite: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["TERMPLEX_USER_DEFAULTS_SUITE"]
        #else
        nil
        #endif
    }

    static var termplex: UserDefaults {
        termplexSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }
}

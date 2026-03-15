import SwiftUI
import TermplexKit

@main
struct Termplex_iOSApp: App {
    @StateObject private var termplex_app: Termplex.App

    init() {
        if termplex_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != TERMPLEX_SUCCESS {
            preconditionFailure("Initialize termplex backend failed")
        }
        _termplex_app = StateObject(wrappedValue: Termplex.App())
    }

    var body: some Scene {
        WindowGroup {
            iOS_TermplexTerminal()
                .environmentObject(termplex_app)
        }
    }
}

struct iOS_TermplexTerminal: View {
    @EnvironmentObject private var termplex_app: Termplex.App

    var body: some View {
        ZStack {
            // Make sure that our background color extends to all parts of the screen
            Color(termplex_app.config.backgroundColor).ignoresSafeArea()

            Termplex.Terminal()
        }
    }
}

struct iOS_TermplexInitView: View {
    @EnvironmentObject private var termplex_app: Termplex.App

    var body: some View {
        VStack {
            Image("AppIconImage")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 96)
            Text("Termplex")
            Text("State: \(termplex_app.readiness.rawValue)")
        }
        .padding()
    }
}

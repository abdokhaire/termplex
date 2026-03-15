import SwiftUI
import Cocoa

// For testing.
struct ColorizedTermplexIconView: View {
    var body: some View {
        Image(nsImage: ColorizedTermplexIcon(
            screenColors: [.purple, .blue],
            ghostColor: .yellow,
            frame: .aluminum
        ).makeImage(in: .main)!)
    }
}

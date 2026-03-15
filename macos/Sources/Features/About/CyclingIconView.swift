import SwiftUI
import TermplexKit
import Combine

/// A view that cycles through Termplex's official icon variants.
struct CyclingIconView: View {
    @EnvironmentObject var viewModel: AboutViewModel

    var body: some View {
        ZStack {
            iconView(for: viewModel.currentIcon)
                .id(viewModel.currentIcon)
        }
        .animation(.easeInOut(duration: 0.5), value: viewModel.currentIcon)
        .frame(height: 128)
        .onHover { hovering in
            viewModel.isHovering = hovering
        }
        .onTapGesture {
            viewModel.advanceToNextIcon()
        }
        .contextMenu {
            if let currentIcon = viewModel.currentIcon {
                Button("Copy Icon Config") {
                    NSPasteboard.general.setString("macos-icon = \(currentIcon.rawValue)", forType: .string)
                }
            }
        }
        .accessibilityLabel("Termplex Application Icon")
        .accessibilityHint("Click to cycle through icon variants")
    }

    @ViewBuilder
    private func iconView(for icon: Termplex.MacOSIcon?) -> some View {
        let iconImage: Image = switch icon?.assetName {
        case let assetName?: Image(assetName)
        case nil: termplexIconImage()
        }

        iconImage
            .resizable()
            .aspectRatio(contentMode: .fit)
    }
}

import SwiftUI

// MARK: - Spacing Constants

enum FGSpacing {
    static let section: CGFloat = 16
    static let item: CGFloat = 10
    static let innerPadding: CGFloat = 12
    static let panelPadding: CGFloat = 14
}

// MARK: - Card Style

struct CardStyle: ViewModifier {
    var isSelected: Bool = false

    func body(content: Content) -> some View {
        content
            .padding(FGSpacing.innerPadding)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
            )
    }
}

extension View {
    func cardStyle(isSelected: Bool = false) -> some View {
        modifier(CardStyle(isSelected: isSelected))
    }
}

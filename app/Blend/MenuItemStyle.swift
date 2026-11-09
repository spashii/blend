import AppKit
import SwiftUI

/// Draws a button as an item of a standard menu: menu text colour, and the selection highlight
/// under the pointer. The panel is never the key window, and the system's borderless buttons
/// draw their titles greyed out there, as if every item were disabled.
struct MenuItemButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            MenuItemLabel(highlighted: hovering || configuration.isPressed) { configuration.label }
                .onHover { hovering = $0 }
                // The panel keeps its views while closed, and the pointer may leave without an
                // exit event, so an item would otherwise open highlighted.
                .onDisappear { hovering = false }
        }
    }
}

/// A menu item's label: the full width of its column, so the highlight and the click reach
/// past the text as in a menu.
struct MenuItemLabel<Content: View>: View {
    @Environment(\.isEnabled) private var enabled
    private let highlighted: Bool
    private let content: Content

    init(highlighted: Bool, @ViewBuilder content: () -> Content) {
        self.highlighted = highlighted
        self.content = content()
    }

    var body: some View {
        let look = MenuItemLook(enabled: enabled, highlighted: highlighted)
        content
            .foregroundStyle(Color(nsColor: look.text))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MenuItemLook.inset.width)
            .padding(.vertical, MenuItemLook.inset.height)
            .background {
                if let background = look.background {
                    RoundedRectangle(cornerRadius: MenuItemLook.cornerRadius, style: .continuous)
                        .fill(Color(nsColor: background))
                }
            }
            .contentShape(Rectangle())
    }
}

/// The colours of a menu item, as NSMenu draws them. A disabled item is never highlighted.
struct MenuItemLook: Equatable {
    let text: NSColor
    let background: NSColor?

    /// How far the highlight reaches past the text on each side.
    static let inset = CGSize(width: 8, height: 3)
    static let cornerRadius: CGFloat = 6

    init(enabled: Bool, highlighted: Bool) {
        if !enabled {
            text = .disabledControlTextColor
            background = nil
        } else if highlighted {
            text = .selectedMenuItemTextColor
            background = .selectedContentBackgroundColor
        } else {
            text = .labelColor
            background = nil
        }
    }
}

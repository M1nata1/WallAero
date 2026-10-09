import AppKit
import SwiftUI

/// What differs between the looks of macOS. Since macOS 26 bars are glass over the content, which
/// scrolls under them, and corners are rounder; before it a line parts a bar from the content.
///
/// macOS 26 shows the new look only to an app built with its SDK, the one that comes with
/// Swift 6.2. Older tools cannot compile that code, so they leave it out and build the app in
/// the look it had.
enum SystemLook {
    static let isGlass: Bool = {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            return true
        }
        #endif
        return false
    }()

    /// The corners of a wallpaper's picture in the library.
    static let tileCornerRadius: CGFloat = isGlass ? 14 : 10
    /// The corners of a picture inside a group of settings.
    static let insetCornerRadius: CGFloat = isGlass ? 12 : 8
    /// The corners of the frames around the whole library: the empty one, and where files drop.
    static let frameCornerRadius: CGFloat = isGlass ? 24 : 18
}

extension View {
    /// Puts a bar of buttons below the view.
    @ViewBuilder
    func bottomBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            // The bar has text in it as well as buttons, so what scrolls under it is hidden
            // for good rather than left to show through.
            safeAreaBar(edge: .bottom, spacing: 0) { bar() }
                .scrollEdgeEffectStyle(.hard, for: .bottom)
        } else {
            linedBottomBar(bar)
        }
        #else
        linedBottomBar(bar)
        #endif
    }

    private func linedBottomBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        VStack(spacing: 0) {
            self
            Divider()
            bar()
        }
    }

    /// Puts a bar above the view, right under the window's toolbar.
    @ViewBuilder
    func topBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            safeAreaBar(edge: .top, spacing: 0) { bar() }
        } else {
            linedTopBar(bar)
        }
        #else
        linedTopBar(bar)
        #endif
    }

    private func linedTopBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        VStack(spacing: 0) {
            bar()
            Divider()
            self
        }
    }

    /// The style of a button in such a bar: glass since macOS 26, tinted for the main action.
    @ViewBuilder
    func barButtonStyle(isMainAction: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if isMainAction {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else {
            self
        }
        #else
        self
        #endif
    }
}

extension View {
    /// The style of a button that shows something is on, like Tags while tags are ticked:
    /// tinted then, and glass since macOS 26, as it stands in a bar there.
    @ViewBuilder
    func pressedButtonStyle(_ isPressed: Bool) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            barButtonStyle(isMainAction: isPressed)
        } else {
            borderedButtonStyle(isProminent: isPressed)
        }
        #else
        borderedButtonStyle(isProminent: isPressed)
        #endif
    }

    @ViewBuilder
    private func borderedButtonStyle(isProminent: Bool) -> some View {
        if isProminent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }
}

extension NSMenuItem {
    /// macOS 26 puts a symbol next to some items by itself — a gear by "Settings…" — and indents the
    /// rest of that group to line up with it, so a menu looks ragged. There every item gets its
    /// own symbol, as in the system's menus; earlier systems draw menus without symbols.
    func setSymbol(_ name: String) {
        if #available(macOS 26, *) {
            image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        }
    }
}

import SwiftUI

/// Root container hosting the two-column NavigationSplitView.
/// Keeps sidebar vibrancy intact by avoiding an opaque root canvas fill.
struct RootView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ModulesView()
            .background(MainWindowCloseBehavior())
            .tint(Design.Palette.accent)
            .transaction { transaction in
                if reduceMotion {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
    }
}

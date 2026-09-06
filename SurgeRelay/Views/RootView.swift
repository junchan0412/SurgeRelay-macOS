import SwiftUI

/// The module list now lives directly in the sidebar of a two-column
/// NavigationSplitView (see `ModulesView`); settings moved to a toolbar button.
struct RootView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ModulesView()
            .background(MainWindowCloseBehavior())
            .tint(Design.Palette.accent)
            .transaction { transaction in
                if reduceMotion { transaction.animation = nil; transaction.disablesAnimations = true }
            }
    }
}

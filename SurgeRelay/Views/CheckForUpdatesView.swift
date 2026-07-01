import AppKit
import SwiftUI

struct CheckForUpdatesView: View {
    var body: some View {
        Button("查看更新…") {
            NSWorkspace.shared.open(ReleaseUpdateChannel.latestReleaseURL)
        }
    }
}

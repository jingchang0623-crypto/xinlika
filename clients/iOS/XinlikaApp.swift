// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

@main
struct XinlikaApp: App {
    @UIApplicationDelegateAdaptor(ShennaoAppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup { XinlikaRootView() }
    }
}

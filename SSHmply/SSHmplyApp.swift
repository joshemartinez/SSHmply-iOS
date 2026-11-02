import SwiftUI
import UIKit

@main
@MainActor
struct SSHmplyApp: App {
    @StateObject private var store: AppStore
    @StateObject private var sessions: SessionManager

    init() {
        UITextView.appearance().backgroundColor = .clear
        let s = AppStore()
        _store = StateObject(wrappedValue: s)
        _sessions = StateObject(wrappedValue: SessionManager(store: s))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(sessions)
                .preferredColorScheme(store.preferredScheme)
        }
    }
}

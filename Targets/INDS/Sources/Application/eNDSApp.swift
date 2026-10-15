import SwiftUI

@main
struct eNDSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var romLibrary = ROMListViewModel()

    var body: some Scene {
        WindowGroup {
            if INDSLaunchFlags.openMapping {
                NavigationStack { ButtonMappingView() }
            } else {
                ContentView()
                    .environmentObject(romLibrary)
                    .onOpenURL { url in
                        AppDelegate.handleFileURL(url)
                    }
            }
        }
    }
}

import SwiftUI

@main struct AntAfouScaleApp: App {
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system.rawValue

    var body: some Scene {
        WindowGroup {
            MainAppContent(language: language)
                .environment(\.locale, AppLanguage.selected.locale)
        }
    }
}

/// Created only on the normal route, so launch-time demos never start real BLE.
private struct MainAppContent: View {
    let language: String
    @StateObject private var profile = UserProfile()

    var body: some View {
        Group {
            if profile.isComplete {
                MeasurementAppContent(language: language)
            } else {
                PrimaryProfileSetupView()
                    .id(language)
            }
        }
        .environmentObject(profile)
    }
}

/// No Bluetooth or HealthKit objects are created until onboarding is complete.
private struct MeasurementAppContent: View {
    let language: String
    @StateObject private var scale = ScaleManager()
    @StateObject private var healthKit = HealthKitManager()

    var body: some View {
        ContentView()
            .id(language)
            .environmentObject(scale)
            .environmentObject(healthKit)
    }
}

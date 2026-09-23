// swift-tools-version: 5.9
import PackageDescription

// Native macOS tests exercise the same persistence / wire / sync models without an iOS runtime.
let package = Package(
    name: "AiHealthCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "AiHealth", targets: ["AiHealth"])],
    targets: [
        .target(name: "AiHealth", path: "ios", exclude: ["AiHealthWatch", "AiHealthWatchUITests", "AiHealthTests", "AiHealthUITests", "project.yml", "CompanionShared/CompanionTransport.swift", "AiHealth/AiHealthApp.swift", "AiHealth/AccountSecureField.swift", "AiHealth/HealthSync.swift", "AiHealth/SettingsViews.swift", "AiHealth/TrainingViews.swift", "AiHealth/PlanningViews.swift", "AiHealth/FoodEntryViews.swift", "AiHealth/SleepViews.swift", "AiHealth/CoachViews.swift", "AiHealth/ExerciseGuideViews.swift", "AiHealth/Info.plist", "AiHealth/AiHealth.entitlements"], sources: ["AiHealth/Models.swift", "AiHealth/ExerciseMedia.swift", "AiHealth/Coach.swift", "AiHealth/HealthStorage.swift", "AiHealth/Planning.swift", "AiHealth/FoodLibrary.swift", "AiHealth/LocalHealthOverview.swift", "AiHealth/SleepHistory.swift", "AiHealth/Network.swift", "AiHealth/AppStore.swift", "AiHealth/Notifications.swift", "CompanionShared/CompanionCore.swift", "AiHealth/CompanionPhone.swift"]),
        .testTarget(name: "AiHealthTests", dependencies: ["AiHealth"], path: "ios/AiHealthTests")
    ]
)

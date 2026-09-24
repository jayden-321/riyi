// swift-tools-version: 5.9
import PackageDescription

// Native macOS tests exercise the same persistence / wire / sync models without an iOS runtime.
let package = Package(
    name: "AiHealthCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "AiHealth", targets: ["AiHealth"])],
    targets: [
        .target(name: "AiHealth", path: "ios", exclude: ["AiHealthWatch", "AiHealthWatchUITests", "AiHealthTests", "AiHealthUITests", "project.yml", "CompanionShared/CompanionTransport.swift", "AiHealth/AiHealthApp.swift", "AiHealth/AccountSecureField.swift", "AiHealth/HealthSync.swift", "AiHealth/WorkoutHealthWriter.swift", "AiHealth/SettingsViews.swift", "AiHealth/TrainingViews.swift", "AiHealth/PlanningViews.swift", "AiHealth/ManualTrainingCycleViews.swift", "AiHealth/FoodEntryViews.swift", "AiHealth/PasswordResetView.swift", "AiHealth/SleepViews.swift", "AiHealth/WeightViews.swift", "AiHealth/VitalViews.swift", "AiHealth/CoachViews.swift", "AiHealth/TeamViews.swift", "AiHealth/ExerciseGuideViews.swift", "AiHealth/Info.plist", "AiHealth/AiHealth.entitlements"], sources: ["AiHealth/Models.swift", "AiHealth/ExerciseMedia.swift", "AiHealth/Coach.swift", "AiHealth/HealthStorage.swift", "AiHealth/Planning.swift", "AiHealth/FoodLibrary.swift", "AiHealth/LocalHealthOverview.swift", "AiHealth/SleepHistory.swift", "AiHealth/WeightHistory.swift", "AiHealth/VitalHistory.swift", "AiHealth/Network.swift", "AiHealth/AppStore.swift", "AiHealth/Notifications.swift", "CompanionShared/CompanionCore.swift", "CompanionShared/WorkoutSport.swift", "AiHealth/CompanionPhone.swift"]),
        .testTarget(name: "AiHealthTests", dependencies: ["AiHealth"], path: "ios/AiHealthTests")
    ]
)

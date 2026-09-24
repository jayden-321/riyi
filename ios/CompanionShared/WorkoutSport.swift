import HealthKit

func healthWorkoutConfiguration(for workout: Workout) -> HKWorkoutConfiguration {
    let configuration = HKWorkoutConfiguration()
    switch workout.activity?.resolvedSport ?? "strength" {
    case "walking": configuration.activityType = .walking; configuration.locationType = .outdoor
    case "running": configuration.activityType = .running; configuration.locationType = .outdoor
    case "cycling": configuration.activityType = .cycling; configuration.locationType = .outdoor
    case "swimming":
        configuration.activityType = .swimming
        if workout.activity?.swimLocation == "pool" {
            configuration.locationType = .indoor
            configuration.swimmingLocationType = .pool
            if let length = workout.activity?.poolLengthMeters { configuration.lapLength = HKQuantity(unit: .meter(), doubleValue: length) }
        } else {
            configuration.locationType = .outdoor
            configuration.swimmingLocationType = .openWater
        }
    case "pilates": configuration.activityType = .pilates; configuration.locationType = .indoor
    case "hiit": configuration.activityType = .highIntensityIntervalTraining; configuration.locationType = .unknown
    case "yoga": configuration.activityType = .yoga; configuration.locationType = .indoor
    case "hiking": configuration.activityType = .hiking; configuration.locationType = .outdoor
    case "rowing": configuration.activityType = .rowing; configuration.locationType = .unknown
    case "elliptical": configuration.activityType = .elliptical; configuration.locationType = .indoor
    case "strength": configuration.activityType = .traditionalStrengthTraining; configuration.locationType = .indoor
    case "other": configuration.activityType = .other; configuration.locationType = .unknown
    default: configuration.activityType = .other; configuration.locationType = .unknown
    }
    return configuration
}

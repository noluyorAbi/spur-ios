import Foundation

// The bench compiles only the motion files; `MotionFile.swift` extends `TripRecord` for the trip
// window, so a minimal stand-in is enough here.
struct TripRecord {
    var startedAt: Date
    var endedAt: Date?
}

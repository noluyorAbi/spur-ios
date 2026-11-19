import Foundation
import Testing
@testable import Spur

/// SPEC 16.3.3: trips of 1.0 and 1.1 export exactly as before version 1.2 (goldens written at
/// 99ad32f, see `GoldenExports`). `trips.csv` only gains the trailing motion columns, empty.
struct GoldenExportTests {
    @Test func oldTripsExportByteForByteAsBefore() throws {
        var compared = 0
        for c in try GoldenExports.cases() {
            for f in try GoldenExports.files(c) {
                let golden = try TestResources.data(f.name, "txt")
                if f.name.hasSuffix(".trips.csv") {
                    let old = String(decoding: golden, as: UTF8.self).split(separator: "\n").map(String.init)
                    let new = String(decoding: f.data, as: UTF8.self).split(separator: "\n").map(String.init)
                    #expect(old.count == 2 && new.count == 2)
                    #expect(new[0] == old[0] + MotionSummaryColumns.header, "\(f.name): header gains the motion columns only")
                    #expect(new[1] == old[1] + String(repeating: ",", count: MotionSummaryColumns.count), "\(f.name): empty motion columns")
                } else {
                    #expect(f.data == golden, "\(f.name) differs from the export of 99ad32f")
                }
                compared += 1
            }
        }
        #expect(compared == 15)
    }
}

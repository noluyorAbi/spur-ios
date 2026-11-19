import Foundation
import Testing
@testable import Spur

/// SPEC 18.10a: why values are hidden, in words.
struct HandlingStateTests {
    typealias Suite = MotionPhysicsSuiteTests

    /// A remount (the phone in a hand, then put down): "In der Hand" while it is handled, then
    /// "Neu ausrichten" with a remaining time that falls.
    @Test func aRemountReadsInHandThenRealigning() {
        let ph = Suite.standard()
        let sc = Suite.build(ph)
        var est = LiveMotionEstimator()
        var nextFix = 0
        var nextRefresh = sc.samples[0].time + 10
        var seen: [LiveMotionEstimator.Hidden] = []
        for (i, s) in sc.samples.enumerated() {
            est.append([s])
            while nextFix < sc.fixes.count && sc.fixes[nextFix].time <= s.time { est.append(fix: sc.fixes[nextFix]); nextFix += 1 }
            if s.time >= nextRefresh {
                nextRefresh += 10
                est.refresh(source: Array(sc.samples[...i]), allFixes: Array(sc.fixes[..<nextFix]), now: Date(timeIntervalSince1970: s.time))
            }
            if let h = est.hidden, seen.last != h { seen.append(h) }
        }
        #expect(seen.contains(.inHand), "the remount is a hand at work")
        let remaining = seen.compactMap { h -> Double? in if case .realigning(let r) = h { return r } else { return nil } }
        #expect(!remaining.isEmpty, "after it, realigning")
        #expect(zip(remaining, remaining.dropFirst()).allSatisfy { $0 >= $1 }, "the remaining time only falls")
    }

    @Test func theStatusLineSaysItInWords() {
        var snap = LiveMotionSnapshot()
        snap.state = .moved
        snap.hidden = .inHand
        #expect(LiveMotionSection.status(snap, state: .moved).text == "In der Hand, Werte pausiert")
        snap.hidden = .realigning(remainingSeconds: 60)
        #expect(LiveMotionSection.status(snap, state: .aligning).text == "Neu ausrichten nach dem Ablegen, noch etwa 1 min (braucht Anfahren und Bremsen)")
        snap.hidden = .realigning(remainingSeconds: 5)
        #expect(LiveMotionSection.status(snap, state: .aligning).text.contains("gleich"))
        // Aligned values are never labelled as hidden.
        #expect(LiveMotionSection.status(snap, state: .aligned).text != "In der Hand, Werte pausiert")
    }
}

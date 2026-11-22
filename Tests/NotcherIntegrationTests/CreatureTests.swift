import XCTest
@testable import Notcher

/// The creature of the Agents page, played through without a screen: annoyed, gone, peeking, back sulking, forgiven.
@MainActor final class CreatureTests: XCTestCase {
    private let width: CGFloat = 260, ground: CGFloat = 120, home: CGFloat = 130
    private var now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private let brain = CreatureBrain()
    @discardableResult private func run(_ seconds: Double, step: Double = 0.05) -> CreatureBrain.Frame {
        var frame = brain.step(now: now, home: home, width: width, mood: .working, ground: ground)
        var elapsed = 0.0
        while elapsed < seconds { now += step; elapsed += step; frame = brain.step(now: now, home: home, width: width, mood: .working, ground: ground) }
        return frame
    }
    private var center: CGPoint { CGPoint(x: brain.x ?? home, y: ground - AgentStage.height / 2) }

    func testPushedTooFarItLeavesPeeksAndComesBackSulking() {
        run(0.1)
        // Poked again and again: dizzy first, then angry.
        for _ in 0..<9 { brain.tap(at: center, now: now); run(0.1) }
        XCTAssertGreaterThan(brain.angryUntil, now)
        // One more poke while it is angry, from its left: it runs off the right side.
        brain.move(to: CGPoint(x: 20, y: 40), now: now)
        brain.tap(at: center, now: now)
        XCTAssertEqual(brain.flight, .running)
        run(1.5)
        guard case .hidden = brain.flight else { return XCTFail("should be hidden, is \(String(describing: brain.flight))") }
        XCTAssertGreaterThan(brain.x ?? 0, width)
        // You are still there: it peeks, sees you and hides again.
        brain.move(to: CGPoint(x: 21, y: 40), now: now)
        var peeked = false, hidAgain = false
        for _ in 0..<160 {
            let frame = run(0.05)
            // The frame that starts the peek is still drawn hidden; the next ones show its head.
            if case .peeking = brain.flight { if peeked { XCTAssertTrue(frame.visible); XCTAssertTrue(frame.peeking) }; peeked = true }
            if peeked, case .hidden = brain.flight { hidAgain = true; break }
        }
        XCTAssertTrue(peeked); XCTAssertTrue(hidAgain)
        // You leave: it comes back, slowly, vexed.
        brain.move(to: nil, now: now)
        run(16)
        XCTAssertNil(brain.flight)
        XCTAssertLessThan(abs((brain.x ?? 0) - home), 3)
        XCTAssertGreaterThan(brain.sulkUntil, now)
        XCTAssertTrue(run(0.05).cloud)
        // Petting it twice forgives everything.
        for _ in 0..<2 {
            for stroke in 0..<6 {
                brain.move(to: CGPoint(x: home + (stroke % 2 == 0 ? -12 : 12), y: ground - 20), now: now)
                run(0.05)
            }
            run(0.3)
        }
        XCTAssertLessThan(brain.sulkUntil, now)
        XCTAssertFalse(run(0.05).cloud)
    }
    func testComingBackWhileItReturnsSendsItOffAgain() {
        run(0.1)
        for _ in 0..<9 { brain.tap(at: center, now: now); run(0.1) }
        brain.tap(at: center, now: now)
        // Off, hidden, then a slow look before stepping back in.
        for _ in 0..<200 where brain.flight != .returning { run(0.05) }
        XCTAssertEqual(brain.flight, .returning)
        brain.move(to: CGPoint(x: 100, y: 40), now: now)
        run(0.05)
        XCTAssertEqual(brain.flight, .running)
    }
    func testThrownHardItLandsDizzy() {
        run(0.1)
        XCTAssertTrue(brain.grab(at: center))
        brain.hold(at: CGPoint(x: home, y: 0))
        let held = run(0.05)
        XCTAssertTrue(held.held); XCTAssertGreaterThan(held.lift, 40)
        brain.release(velocity: CGSize(width: 300, height: 600))
        run(1.5)
        XCTAssertGreaterThan(brain.dizzyUntil, now - 1.5)
    }
}

@MainActor final class CreatureSceneTests: XCTestCase {
    func testAScenePlaysUntilYouComeInThenFades() {
        let brain = CreatureBrain(), start = Date(timeIntervalSinceReferenceDate: 2_000_000)
        brain.beginScene(mood: .working, now: start, pick: .pool)
        XCTAssertEqual(brain.sceneFrame(now: start + 10, mood: .working)?.opacity, 1, "nobody came: it keeps swimming")
        brain.move(to: CGPoint(x: 50, y: 50), now: start + 10)
        _ = brain.sceneFrame(now: start + 10.1, mood: .working)
        XCTAssertNotNil(brain.sceneFrame(now: start + 10.5, mood: .working)?.noticed)
        XCTAssertNotNil(brain.sceneFrame(now: start + 11.0, mood: .working))
        XCTAssertNil(brain.sceneFrame(now: start + 11.5, mood: .working))
    }
    func testAnEmbarrassingSceneTidiesItselfAway() {
        let brain = CreatureBrain(), start = Date(timeIntervalSinceReferenceDate: 2_000_000)
        brain.beginScene(mood: .idle, now: start, pick: .fridge)
        XCTAssertNotNil(brain.sceneFrame(now: start + 3, mood: .idle))
        _ = brain.sceneFrame(now: start + CreatureBrain.shameLength + 0.1, mood: .idle)
        XCTAssertNil(brain.sceneFrame(now: start + CreatureBrain.shameLength + 0.7, mood: .idle))
        // Claude needs you: no scene.
        brain.beginScene(mood: .waiting, now: start)
        XCTAssertNil(brain.scene)
    }
}

@MainActor final class CreatureSceneVisitTests: XCTestCase {
    /// The pointer that clicked the card rests over the stage when the page opens: moving it about there does
    /// not interrupt the scene; leaving and coming back, or going near the creature, does.
    func testThePointerThatOpenedThePageDoesNotCount() {
        let brain = CreatureBrain(), start = Date(timeIntervalSinceReferenceDate: 3_000_000)
        brain.move(to: CGPoint(x: 200, y: 20), now: start)
        brain.beginScene(mood: .idle, now: start, pick: .gym)
        brain.sceneFocus = CGPoint(x: 130, y: 100)
        for step in 1...20 {
            brain.move(to: CGPoint(x: 200 + CGFloat(step % 3) * 10, y: 20), now: start + Double(step) * 0.2)
            XCTAssertNil(brain.sceneFrame(now: start + Double(step) * 0.2, mood: .idle)?.noticed)
        }
        // Close to it: noticed.
        brain.move(to: CGPoint(x: 140, y: 95), now: start + 5)
        XCTAssertNotNil(brain.sceneFrame(now: start + 5.05, mood: .idle)?.noticed)
        // Another opening: out and back in counts as a visit.
        brain.beginScene(mood: .idle, now: start + 10, pick: .pool)
        brain.sceneFocus = CGPoint(x: 0, y: 0)
        brain.move(to: nil, now: start + 11)
        _ = brain.sceneFrame(now: start + 11, mood: .idle)
        brain.move(to: CGPoint(x: 250, y: 10), now: start + 12)
        XCTAssertNotNil(brain.sceneFrame(now: start + 12.05, mood: .idle)?.noticed)
    }
}

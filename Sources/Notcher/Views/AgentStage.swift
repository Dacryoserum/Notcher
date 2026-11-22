import SwiftUI
import NotcherCore

/// What Claude Code is up to, told by a small pixel creature of Notcher's own: asleep when nothing runs,
/// hopping while it answers, waving when it waits for you, cheering when it is done. Each sub-agent at
/// work stands beside it as a smaller, paler clone.
///
/// It also has a temper. It follows the pointer, walks where you click, jumps when poked, gets dizzy when
/// poked too much, turns its back when angry, and if you keep at it, leaves the stage, peeks from the edge
/// until you are gone and comes back sulking under a little cloud. Petting it (stroking it with the pointer)
/// makes it happy and forgives everything. It can be picked up and thrown.
struct AgentStage: View {
    enum Mood: Equatable { case idle, working, waiting, done }
    let mood: Mood
    let clones: [ClaudeSubagent]
    /// Start of the current celebration, for the confetti.
    let doneAt: Date?
    /// The Agents page shows it doing something each time it opens; the picker does not.
    var scenes = false
    @Environment(\.notcherAccent) var accent
    @Environment(\.notcherPanelActive) private var active
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var brain = CreatureBrain()
    @State private var dragging = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active || reduceMotion)) { context in
            Canvas { canvas, size in draw(in: &canvas, size: size, now: context.date) }
        }
        .contentShape(Rectangle())
        .clipped()
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): brain.move(to: point)
            case .ended: brain.move(to: nil)
            }
        }
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in
                let moved = hypot(value.translation.width, value.translation.height) > 4
                if !dragging, moved, brain.grab(at: value.startLocation) { dragging = true }
                if dragging { brain.hold(at: value.location) }
            }
            .onEnded { value in
                if dragging { brain.release(velocity: value.velocity) } else { brain.tap(at: value.location) }
                dragging = false
            })
        .onAppear { if scenes { brain.beginScene(mood: mood) } }
        .onChange(of: active) { _, value in if value && scenes { brain.beginScene(mood: mood) } }
        .accessibilityElement().accessibilityLabel(L(label))
    }
    private var label: String {
        switch mood {
        case .idle: return "Claude Code est au repos"
        case .working: return "Claude Code travaille"
        case .waiting: return "Claude Code attend ta réponse"
        case .done: return "Claude Code a terminé"
        }
    }

    // MARK: Scene

    static let pixel: CGFloat = 4
    static let width = 13 * pixel
    static let height = 11 * pixel

    private func draw(in canvas: inout GraphicsContext, size: CGSize, now: Date) {
        let t = reduceMotion ? 0 : now.timeIntervalSinceReferenceDate
        // Caught doing something: the scene covers the stage, then fades into it.
        if let scene = brain.sceneFrame(now: now, mood: mood) {
            if scene.opacity < 1 { drawStage(in: &canvas, size: size, now: now, t: t) }
            canvas.drawLayer { layer in
                layer.opacity = scene.opacity
                brain.sceneFocus = drawScene(scene.scene, in: &layer, size: size, t: t, elapsed: scene.elapsed, noticed: scene.noticed)
            }
            return
        }
        drawStage(in: &canvas, size: size, now: now, t: t)
    }
    private func drawStage(in canvas: inout GraphicsContext, size: CGSize, now: Date, t: Double) {
        let ground = size.height - 16
        backdrop(in: &canvas, size: size, ground: ground, t: t)

        // Clones take the right of the stage; the creature lives on the left part and wanders over all of it.
        let cloneSpacing: CGFloat = 36
        // At work, the desk takes room on the creature's right.
        let room = Int(max(0, (size.width - Self.width - 40 - (mood == .working ? 78 : 0)) / cloneSpacing))
        let shown = Array(clones.prefix(min(5, room)))
        let home = shown.isEmpty ? size.width / 2 : 18 + Self.width / 2
        let state = brain.step(now: now, home: home, width: size.width, mood: mood, ground: ground)

        // Clones first, so the creature walks in front of them.
        for (index, clone) in shown.enumerated() {
            let small: CGFloat = 2.2, cloneWidth = 13 * small
            let x = size.width - 14 - CGFloat(shown.count - index) * cloneSpacing + (cloneSpacing - cloneWidth) / 2
            let phase = Double(index) * 0.9
            let hop = reduceMotion ? 0 : CGFloat(abs(sin(t * 6 + phase))) * 4
            shadow(in: &canvas, center: CGPoint(x: x + cloneWidth / 2, y: ground + 2), width: cloneWidth)
            var look = Look(eyes: .open(dx: 0, dy: 0), tint: accent.opacity(0.7), walking: true)
            // The clones watch the boss when something happens to it.
            if state.angry || state.fled || state.held { look.eyes = .open(dx: state.x < x ? -1 : 1, dy: state.held ? -1 : 0) }
            creature(in: &canvas, at: CGPoint(x: x, y: ground - 11 * small - hop), pixel: small, t: t + phase, look: look, facing: 1, tilt: 0, squash: 1)
            let name = Text(clone.type.count > 9 ? String(clone.type.prefix(8)) + "…" : clone.type)
                .font(.system(size: 7.5, weight: .medium, design: .monospaced)).foregroundColor(.white.opacity(0.5))
            canvas.draw(name, at: CGPoint(x: x + cloneWidth / 2, y: ground + 9))
        }
        if clones.count > shown.count, !shown.isEmpty {
            canvas.draw(Text("+\(clones.count - shown.count)").font(.system(size: 9, weight: .semibold, design: .rounded)).foregroundColor(accent),
                        at: CGPoint(x: size.width - 12, y: 14))
        }

        // The creature.
        guard state.visible else { return }
        if state.seated {
            office(in: &canvas, x: state.x, ground: ground, t: t, look: state.look, glance: state.glance)
            if state.hearts { hearts(in: &canvas, from: CGPoint(x: state.x, y: ground - 60), t: t) }
            return
        }
        let left = state.x - Self.width / 2
        let origin = CGPoint(x: left, y: ground - Self.height - state.lift)
        if !state.peeking { shadow(in: &canvas, center: CGPoint(x: state.x, y: ground + 2), width: Self.width * max(0.3, 1 - state.lift / 60)) }
        creature(in: &canvas, at: origin, pixel: Self.pixel, t: t, look: state.look, facing: state.facing, tilt: state.tilt, squash: state.squash)
        let side = CGPoint(x: state.facing > 0 ? left + Self.width + 2 : left - 24, y: origin.y)
        if state.cloud { cloud(in: &canvas, over: CGPoint(x: state.x, y: origin.y - 10), t: t) }
        if state.dizzy { stars(in: &canvas, around: CGPoint(x: state.x, y: origin.y + 4), t: t) }
        if state.hearts { hearts(in: &canvas, from: CGPoint(x: state.x, y: origin.y), t: t) }
        if state.spotted { bubble(in: &canvas, text: "!", color: .white, at: CGPoint(x: state.facing > 0 ? left + Self.width - 6 : left - 10, y: origin.y + 6), t: t) }
        else if state.angry { bubble(in: &canvas, text: "#!", color: Color(red: 0.95, green: 0.35, blue: 0.3), at: CGPoint(x: left + Self.width + 2, y: origin.y + 2), t: t) }
        else if state.hmph { mutter(in: &canvas, "hmph", at: CGPoint(x: side.x + 12, y: origin.y + 4)) }
        else if state.held { mutter(in: &canvas, L("hé !"), at: CGPoint(x: state.x, y: origin.y - 8)) }
        else if mood == .waiting && !state.sulking { bubble(in: &canvas, text: "!", color: Theme.orange, at: CGPoint(x: left + Self.width + 2, y: origin.y - 4), t: t) }
        else if case .closed = state.look.eyes, mood == .idle, !reduceMotion { sleep(in: &canvas, at: CGPoint(x: left + Self.width - 4, y: origin.y + 6), t: t) }
        if mood == .done, let doneAt, !state.sulking { confetti(in: &canvas, from: CGPoint(x: state.x, y: origin.y + 8), elapsed: now.timeIntervalSince(doneAt)) }
    }

    // MARK: Creature

    struct Look {
        enum Eyes { case open(dx: Int, dy: Int), closed, happy, dizzy, wide, up, grumpy(dx: Int), hidden }
        enum Mouth { case none, talk, open, frown }
        var eyes: Eyes
        var tint: Color
        var walking = false
        var mouth = Mouth.none
        var wave = false
        var hat = false
        var blush = false
        /// Held in the air: the feet paddle.
        var paddling = false
    }
    private static let shape: [String] = [
        "....*.*.*....",
        ".....***.....",
        "....*.*.*....",
        "......|......",
        "...#######...",
        "..#########..",
        ".###########.",
        ".###########.",
        ".###########.",
        "..%%%%%%%%%..",
    ]
    private static let feet = ["...##...##...", "..##.....##.."]
    /// December: a red hat with a white pompom replaces the antenna.
    private static let hat: [String] = [
        "........o....",
        ".......rr....",
        "......rrr....",
        "....rrrrr....",
        "...wwwwwww...",
    ]

    func creature(in canvas: inout GraphicsContext, at origin: CGPoint, pixel: CGFloat, t: Double, look: Look, facing: CGFloat, tilt: Double, squash: CGFloat) {
        var layer = canvas
        // Turned around, tilted and squashed about the middle of its feet.
        let pivot = CGPoint(x: origin.x + 6.5 * pixel, y: origin.y + 11 * pixel)
        layer.translateBy(x: pivot.x, y: pivot.y)
        if tilt != 0 { layer.rotate(by: .radians(tilt)) }
        layer.scaleBy(x: facing * (squash == 1 ? 1 : 1 / squash), y: squash)
        layer.translateBy(x: -pivot.x, y: -pivot.y)
        func dot(_ column: Int, _ row: Int, _ color: Color) {
            layer.fill(Path(CGRect(x: origin.x + CGFloat(column) * pixel, y: origin.y + CGFloat(row) * pixel, width: pixel, height: pixel)), with: .color(color))
        }
        let busy = look.walking || look.mouth == .talk || look.paddling
        let sparkle = busy ? (sin(t * 9) > 0 ? Color.white : look.tint) : look.tint.opacity(0.6)
        for (row, line) in Self.shape.enumerated() {
            for (column, character) in line.enumerated() {
                switch character {
                case "*" where !look.hat: dot(column, row, sparkle)
                case "|" where !look.hat: dot(column, row, look.tint.opacity(0.7))
                case "#": dot(column, row, look.tint)
                case "%": dot(column, row, look.tint.opacity(0.72))
                default: break
                }
            }
        }
        if look.hat {
            for (row, line) in Self.hat.enumerated() {
                for (column, character) in line.enumerated() {
                    switch character {
                    case "r": dot(column, row, Color(red: 0.86, green: 0.2, blue: 0.22))
                    case "w", "o": dot(column, row, .white)
                    default: break
                    }
                }
            }
        }
        let step = look.paddling ? Int(t * 14) % 2 : busy ? Int(t * 6) % 2 : 0
        for (column, character) in Self.feet[step].enumerated() where character == "#" { dot(column, 10, look.tint.opacity(0.72)) }

        let eye = Color(white: 0.06)
        let blink = t.truncatingRemainder(dividingBy: 3.7) < 0.12
        switch look.eyes {
        case .hidden: break
        case .closed: dot(3, 7, eye); dot(4, 7, eye); dot(8, 7, eye); dot(9, 7, eye)
        case .happy: dot(3, 7, eye); dot(4, 6, eye); dot(5, 7, eye); dot(7, 7, eye); dot(8, 6, eye); dot(9, 7, eye)
        case .wide: for column in [3, 4, 8, 9] { dot(column, 6, eye); dot(column, 7, eye) }
        case .up: dot(4, 5, eye); dot(4, 6, eye); dot(8, 5, eye); dot(8, 6, eye)
        case .dizzy:
            // Spinning eyes: the two diagonals take turns.
            let flip = Int(t * 8) % 2 == 0
            dot(3, flip ? 6 : 7, eye); dot(4, flip ? 7 : 6, eye); dot(8, flip ? 7 : 6, eye); dot(9, flip ? 6 : 7, eye)
        case .grumpy(let dx):
            // Half-closed, frowning eyes, slanted towards the middle.
            let x = dx * Int(facing)
            dot(3 + x, 7, eye); dot(4 + x, 7, eye); dot(4 + x, 6, eye)
            dot(8 + x, 6, eye); dot(8 + x, 7, eye); dot(9 + x, 7, eye)
        case .open(let dx, let dy):
            // Eyes look where the pointer is (dx is in the creature's own direction, it may be turned around).
            let x = dx * Int(facing)
            if blink { dot(4 + x, 7, eye); dot(8 + x, 7, eye) }
            else { dot(4 + x, 6 + dy, eye); dot(4 + x, 7 + dy, eye); dot(8 + x, 6 + dy, eye); dot(8 + x, 7 + dy, eye) }
        }
        switch look.mouth {
        case .talk where pixel > 3: if Int(t * 4) % 3 != 0 { dot(6, 8, eye) }
        case .open: dot(6, 8, eye); dot(6, 9, eye)
        case .frown: dot(5, 9, eye); dot(6, 8, eye); dot(7, 9, eye)
        default: break
        }
        if look.blush { dot(2, 8, Color(red: 1, green: 0.55, blue: 0.6)); dot(10, 8, Color(red: 1, green: 0.55, blue: 0.6)) }
        if look.wave {
            let up = sin(t * 8) > 0
            dot(12, up ? 5 : 7, look.tint); dot(12, 6, look.tint); dot(0, 7, look.tint)
        }
    }

    /// Claude at work: on an office chair, seen from behind and a little from the side, typing on a small
    /// computer. Its trousers being what they are, a tiny line shows above the seat.
    private func office(in canvas: inout GraphicsContext, x: CGFloat, ground: CGFloat, t: Double, look: Look, glance: Bool) {
        func rect(_ minX: CGFloat, _ minY: CGFloat, _ width: CGFloat, _ height: CGFloat, _ color: Color) {
            canvas.fill(Path(CGRect(x: minX, y: minY, width: width, height: height)), with: .color(color))
        }
        let metal = Color(white: 0.24), wood = Color(red: 0.36, green: 0.26, blue: 0.2), dark = Color(white: 0.06)
        let seat = ground - 15
        shadow(in: &canvas, center: CGPoint(x: x + 28, y: ground + 2), width: 120)

        // The desk, its computer, a mug.
        // A low desk: the keyboard sits just under its hands.
        let desk = x + 24, top = ground - 17
        rect(desk, top, 62, 3, wood)
        rect(desk + 3, top + 3, 3, ground - top - 3, wood.opacity(0.8)); rect(desk + 56, top + 3, 3, ground - top - 3, wood.opacity(0.8))
        rect(desk + 30, top - 6, 4, 6, metal)
        let screen = CGRect(x: desk + 14, y: top - 32, width: 38, height: 26)
        canvas.fill(Path(roundedRect: screen, cornerRadius: 2), with: .color(Color(white: 0.13)))
        let glass = screen.insetBy(dx: 2, dy: 2)
        canvas.fill(Path(glass), with: .color(Color(red: 0.04, green: 0.08, blue: 0.09)))
        // Code scrolling up the screen.
        var inner = canvas
        inner.clip(to: Path(glass))
        let scroll = CGFloat((t * 9).truncatingRemainder(dividingBy: 4))
        for line in 0..<7 {
            let index = Int(t * 9 / 4) + line
            let width = CGFloat(6 + (index * 37) % 22), indent = CGFloat((index * 13) % 3) * 3
            let color = (index % 4 == 0 ? accent : index % 3 == 0 ? Theme.orange : Color.white).opacity(index % 4 == 0 ? 0.8 : 0.45)
            inner.fill(Path(CGRect(x: glass.minX + 2 + indent, y: glass.maxY - 3 - CGFloat(line) * 4 + scroll - 4 + 4, width: min(width, glass.width - 4 - indent), height: 1.5)), with: .color(color))
        }
        // Cursor blinking.
        if Int(t * 2) % 2 == 0 { inner.fill(Path(CGRect(x: glass.minX + 3, y: glass.maxY - 4, width: 2, height: 2)), with: .color(.white.opacity(0.8))) }
        // Keyboard, keys jumping under the fingers.
        let keyboard = top - 3
        rect(desk + 2, keyboard, 20, 3, Color(white: 0.55))
        for key in 0..<5 where Int(t * 10 + Double(key) * 1.7) % 3 == 0 { rect(desk + 3 + CGFloat(key) * 4, keyboard - 1, 2, 1, .white.opacity(0.7)) }
        // Mug and its steam.
        rect(desk + 52, top - 6, 6, 6, Color(white: 0.85)); rect(desk + 58, top - 4, 2, 3, Color(white: 0.85))
        for wisp in 0..<2 {
            let progress = (t * 0.7 + Double(wisp) / 2).truncatingRemainder(dividingBy: 1)
            rect(desk + 53 + CGFloat(wisp) * 3 + CGFloat(sin(t * 3 + Double(wisp))) * 1.5, top - 9 - CGFloat(progress) * 12, 1.5, 3, .white.opacity(0.35 * (1 - progress)))
        }

        // The chair: wheels, post, seat, and a backrest on the far side.
        rect(x - 15, ground - 2, 30, 2, metal)
        for wheel in [x - 16, x - 1, x + 13] { rect(wheel, ground - 1, 3, 3, Color(white: 0.12)) }
        rect(x - 1.5, seat + 4, 3, ground - seat - 6, metal)
        canvas.fill(Path(roundedRect: CGRect(x: x - 17, y: seat, width: 34, height: 5), cornerRadius: 2), with: .color(Color(white: 0.2)))

        // The creature, from behind: no face, the antenna, a hand on the keyboard.
        let pixel = Self.pixel
        let origin = CGPoint(x: x - 6.5 * pixel, y: seat - 10 * pixel + 2)
        let bob = CGFloat(abs(sin(t * 3))).rounded()
        func dot(_ column: Int, _ row: Int, _ color: Color) {
            rect(origin.x + CGFloat(column) * pixel, origin.y + CGFloat(row) * pixel - bob, pixel, pixel, color)
        }
        let sparkle = sin(t * 9) > 0 ? Color.white : look.tint
        for (row, line) in Self.shape.enumerated() {
            for (column, character) in line.enumerated() {
                switch character {
                case "*" where !look.hat: dot(column, row, sparkle)
                case "|" where !look.hat: dot(column, row, look.tint.opacity(0.7))
                case "#": dot(column, row, look.tint)
                // Seen from behind the lower row is as bright as the rest.
                case "%": dot(column, row, look.tint.opacity(0.9))
                default: break
                }
            }
        }
        if look.hat {
            for (row, line) in Self.hat.enumerated() {
                for (column, character) in line.enumerated() {
                    switch character {
                    case "r": dot(column, row, Color(red: 0.86, green: 0.2, blue: 0.22))
                    case "w", "o": dot(column, row, .white)
                    default: break
                    }
                }
            }
        }
        // The very small line, slightly off centre since it sits a little sideways.
        rect(origin.x + 7 * pixel - 0.5, origin.y + 9 * pixel + 1 - bob, 1.5, pixel + 1, dark.opacity(0.85))
        // One eye shows on the side facing the screen, or over the shoulder when you come near.
        if glance { dot(2, 6, dark); dot(2, 7, dark) } else { dot(11, 6, dark) }
        // The arm reaching for the keyboard, typing.
        // The arm goes down from its side to the keyboard; the hand taps on the keys.
        let typing = Int(t * 10) % 2 == 0
        var arm = Path()
        arm.move(to: CGPoint(x: origin.x + 12 * pixel, y: origin.y + 7 * pixel - bob))
        arm.addLine(to: CGPoint(x: origin.x + 13.5 * pixel, y: origin.y + 8 * pixel - bob))
        arm.addLine(to: CGPoint(x: desk + 9, y: keyboard - 2 - (typing ? 1.5 : 0)))
        canvas.stroke(arm, with: .color(look.tint), style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
        // Little legs swinging under the seat.
        for (index, start) in [x + 7, x + 13].enumerated() {
            let angle = sin(t * 4 + Double(index) * .pi) * 0.45
            let foot = CGPoint(x: start + CGFloat(sin(angle)) * 8, y: seat + 4 + CGFloat(cos(angle)) * 8)
            var leg = Path(); leg.move(to: CGPoint(x: start, y: seat + 3)); leg.addLine(to: foot)
            canvas.stroke(leg, with: .color(look.tint.opacity(0.85)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            canvas.fill(Path(ellipseIn: CGRect(x: foot.x - 2, y: foot.y - 1, width: 5, height: 3)), with: .color(look.tint.opacity(0.7)))
        }
        // The backrest, in front of the far side of its back.
        canvas.fill(Path(roundedRect: CGRect(x: x - 21, y: seat - 22, width: 6, height: 24), cornerRadius: 2), with: .color(Color(white: 0.18)))
        rect(x - 17, seat - 2, 3, 4, metal)
        if glance { mutter(in: &canvas, "?", at: CGPoint(x: x - 30, y: origin.y + 16)) }
    }

    func shadow(in canvas: inout GraphicsContext, center: CGPoint, width: CGFloat) {
        canvas.fill(Path(ellipseIn: CGRect(x: center.x - width / 2.6, y: center.y - 2, width: width / 1.3, height: 4)), with: .color(.black.opacity(0.45)))
    }

    private func backdrop(in canvas: inout GraphicsContext, size: CGSize, ground: CGFloat, t: Double) {
        for x in stride(from: CGFloat(6), to: size.width - 6, by: 7) {
            canvas.fill(Path(CGRect(x: x, y: ground + 2, width: 3, height: 1)), with: .color(.white.opacity(0.07)))
        }
        switch mood {
        case .idle:
            for index in 0..<14 {
                let x = CGFloat((index * 73 + 19) % 997) / 997 * size.width
                let y = CGFloat((index * 41 + 7) % 89) / 89 * (ground - 20) + 6
                let glow = 0.06 + 0.1 * (0.5 + 0.5 * sin(t * 0.9 + Double(index) * 1.3))
                canvas.fill(Path(CGRect(x: x, y: y, width: 1.5, height: 1.5)), with: .color(.white.opacity(glow)))
            }
        case .working, .done:
            for index in 0..<22 {
                let speed = 10 + Double(index % 5) * 4
                let span = Double(ground)
                let y = CGFloat(span - (t * speed + Double(index) * 37).truncatingRemainder(dividingBy: span))
                let x = CGFloat((index * 131 + 11) % 991) / 991 * size.width
                let color = (index % 3 == 0 ? accent : Theme.orange).opacity(0.05 + 0.22 * Double(y / ground))
                canvas.fill(Path(CGRect(x: x, y: y, width: index % 4 == 0 ? 5 : 2, height: 2)), with: .color(color))
            }
        case .waiting:
            let center = CGPoint(x: size.width / 2, y: ground)
            for ring in 0..<3 {
                let progress = (t * 0.6 + Double(ring) / 3).truncatingRemainder(dividingBy: 1)
                let radius = CGFloat(20 + progress * Double(size.width) * 0.45)
                let rect = CGRect(x: center.x - radius, y: center.y - radius * 0.35, width: radius * 2, height: radius * 0.7)
                canvas.stroke(Path(ellipseIn: rect), with: .color(Theme.orange.opacity(0.22 * (1 - progress))), lineWidth: 1)
            }
        }
    }

    func bubble(in canvas: inout GraphicsContext, text: String, color: Color, at point: CGPoint, t: Double) {
        let bob = CGFloat(sin(t * 4)) * 1.5
        let width: CGFloat = text.count > 1 ? 22 : 16
        let rect = CGRect(x: point.x, y: point.y - 14 + bob, width: width, height: 15)
        canvas.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(color))
        canvas.fill(Path(CGRect(x: rect.minX + 2, y: rect.maxY - 1, width: 3, height: 3)), with: .color(color))
        canvas.draw(Text(text).font(.system(size: 10, weight: .black, design: .rounded)).foregroundColor(Color(white: 0.06)), at: CGPoint(x: rect.midX, y: rect.midY))
    }
    func mutter(in canvas: inout GraphicsContext, _ text: String, at point: CGPoint) {
        canvas.draw(Text(text).font(.system(size: 8, weight: .bold, design: .rounded)).foregroundColor(.white.opacity(0.55)), at: point)
    }
    /// A small grey cloud raining on a sulking creature.
    private func cloud(in canvas: inout GraphicsContext, over point: CGPoint, t: Double) {
        let grey = Color(white: 0.42), size: CGFloat = 3
        let shape = [".xxx...", "xxxxxx.", ".xxxxxx"]
        let drift = CGFloat(sin(t * 1.3)) * 2
        let origin = CGPoint(x: point.x - 10 + drift, y: point.y - 8)
        for (row, line) in shape.enumerated() {
            for (column, character) in line.enumerated() where character == "x" {
                canvas.fill(Path(CGRect(x: origin.x + CGFloat(column) * size, y: origin.y + CGFloat(row) * size, width: size, height: size)), with: .color(grey))
            }
        }
        for drop in 0..<3 {
            let progress = (t * 1.6 + Double(drop) / 3).truncatingRemainder(dividingBy: 1)
            let x = origin.x + CGFloat(3 + drop * 6), y = origin.y + 10 + CGFloat(progress) * 12
            canvas.fill(Path(CGRect(x: x, y: y, width: 1.5, height: 3)), with: .color(Color(red: 0.45, green: 0.7, blue: 1).opacity(0.8 * (1 - progress))))
        }
    }
    func hearts(in canvas: inout GraphicsContext, from point: CGPoint, t: Double) {
        let shape = [".x.x.", "xxxxx", ".xxx.", "..x.."]
        for index in 0..<3 {
            let progress = (t * 0.9 + Double(index) / 3).truncatingRemainder(dividingBy: 1)
            let x = point.x - 14 + CGFloat(index) * 12 + CGFloat(sin(t * 3 + Double(index))) * 3
            let y = point.y - CGFloat(progress) * 26
            for (row, line) in shape.enumerated() {
                for (column, character) in line.enumerated() where character == "x" {
                    canvas.fill(Path(CGRect(x: x + CGFloat(column) * 1.6, y: y + CGFloat(row) * 1.6, width: 1.6, height: 1.6)),
                                with: .color(Color(red: 1, green: 0.42, blue: 0.55).opacity(1 - progress)))
                }
            }
        }
    }
    private func stars(in canvas: inout GraphicsContext, around point: CGPoint, t: Double) {
        for index in 0..<3 {
            let angle = t * 5 + Double(index) * 2 * .pi / 3
            let x = point.x + CGFloat(cos(angle)) * 22, y = point.y + CGFloat(sin(angle)) * 5
            let size: CGFloat = sin(angle) > 0 ? 3 : 2
            canvas.fill(Path(CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size)), with: .color(Color(red: 1, green: 0.85, blue: 0.3)))
        }
    }

    func sleep(in canvas: inout GraphicsContext, at point: CGPoint, t: Double) {
        for index in 0..<3 {
            let progress = (t * 0.35 + Double(index) / 3).truncatingRemainder(dividingBy: 1)
            let position = CGPoint(x: point.x + CGFloat(progress) * 18 + CGFloat(index) * 2, y: point.y - CGFloat(progress) * 26)
            canvas.draw(Text("z").font(.system(size: 7 + CGFloat(progress) * 5, weight: .bold, design: .rounded)).foregroundColor(.white.opacity(0.45 * (1 - progress))), at: position)
        }
    }

    private func confetti(in canvas: inout GraphicsContext, from point: CGPoint, elapsed: Double) {
        guard elapsed >= 0, elapsed < 2.6 else { return }
        let colors = [Theme.orange, accent, Theme.green, Color.white]
        for index in 0..<26 {
            let angle = Double(index) / 26 * 2 * .pi + Double(index % 3) * 0.2
            let speed = 38 + Double((index * 37) % 23)
            let x = point.x + CGFloat(cos(angle) * speed * elapsed)
            let y = point.y + CGFloat(-abs(sin(angle)) * speed * elapsed * 1.3 + 60 * elapsed * elapsed)
            let size: CGFloat = index % 2 == 0 ? 3 : 2
            canvas.fill(Path(CGRect(x: x, y: y, width: size, height: size)), with: .color(colors[index % colors.count].opacity(max(0, 1 - elapsed / 2.6))))
        }
    }
}

/// Where the creature is and what it feels, advanced once per frame. Kept in a reference so drawing can move it.
final class CreatureBrain {
    struct Frame {
        var x: CGFloat
        var lift: CGFloat
        var facing: CGFloat
        var tilt: Double
        var squash: CGFloat = 1
        var look: AgentStage.Look
        var visible = true
        var peeking = false
        var dizzy = false
        var angry = false
        var fled = false
        var held = false
        var sulking = false
        var cloud = false
        var hearts = false
        var spotted = false
        var hmph = false
        /// At its desk, seen from behind, typing.
        var seated = false
        /// Seated, it looks over its shoulder at the pointer.
        var glance = false
    }
    /// After being pushed too far: off the stage, then peeking from its edge until you are gone.
    enum Flight: Equatable {
        case running
        case hidden(until: Date)
        case peeking(since: Date)
        case returning
    }

    private(set) var pointer: CGPoint?
    private(set) var flight: Flight?
    private(set) var sulkUntil = Date.distantPast
    private(set) var angryUntil = Date.distantPast
    private(set) var dizzyUntil = Date.distantPast
    private(set) var x: CGFloat?
    private var pointerMoved = Date()
    private var pointerAt = Date()
    private var pointerSpeed: CGFloat = 0
    private var facing: CGFloat = 1
    private var destination: CGFloat?
    private var lastStep: Date?
    private var annoyance: Double = 0
    /// Times it fled: each one makes the next sulk longer.
    private var grudge = 0
    private var side: CGFloat = 1
    private var hiddenAt = Date.distantPast
    private var jumpAt = Date.distantPast
    private var happyUntil = Date.distantPast
    private var scaredUntil = Date.distantPast
    private var angryHover: Double = 0
    private var reachSince: Date?
    private var petStrokes: [Date] = []
    private var petSign: CGFloat = 0
    private var forgiveness = 0
    private var glanceAt = Date.distantPast
    private var nextFidget = Date().addingTimeInterval(8)
    private var fidget: (kind: Int, until: Date)?
    // Carried and thrown.
    private var held = false
    private var grip = CGSize.zero
    private var heldPoint = CGPoint.zero
    private var heldVelocity: CGFloat = 0
    private var airborne = false
    private var height: CGFloat = 0
    private var velocity = CGVector.zero
    private var landedAt = Date.distantPast
    private var body = CGRect.zero
    /// Poked or picked up: it leaves its desk for a while.
    private var disturbedAt = Date.distantPast
    private var seated = false
    private var width: CGFloat = 0
    private var ground: CGFloat = 0
    private var half: CGFloat { AgentStage.width / 2 }
    private var offstage: CGFloat { side > 0 ? width + half + 14 : -half - 14 }
    private var peekSpot: CGFloat { side > 0 ? width + half - 22 : -half + 22 }

    // MARK: Scenes

    /// What it is caught doing when the page opens. The last three are embarrassing: it tidies up at once.
    enum Scene: CaseIterable {
        case pool, plane, fishing, gym, couch, party, nose, mirror, fridge
        var embarrassing: Bool { self == .nose || self == .mirror || self == .fridge }
        static var last: Scene?
    }
    struct SceneFrame { var scene: Scene; var elapsed: Double; var noticed: Double?; var opacity: Double }
    private(set) var scene: Scene?
    private var sceneStart = Date.distantPast
    private var sceneNoticed: Date?
    private var sceneEnding: Date?
    static let sceneFade = 0.4
    /// How long an embarrassing scene lasts: caught, tidied up, whistling innocently.
    static let shameLength = 7.1
    /// Where the creature is in the current scene, so coming close to it gets noticed.
    var sceneFocus: CGPoint?
    /// The pointer was already over the stage when the scene began (it rests where the card was clicked):
    /// it does not count until it has left once.
    private var sceneInherited = false

    func beginScene(mood: AgentStage.Mood, now: Date = Date(), pick: Scene? = nil) {
        guard mood == .idle || mood == .working, flight == nil, !held else { return }
        let embarrassing = Int.random(in: 0..<6) == 0
        let choices = Scene.allCases.filter { $0.embarrassing == embarrassing && $0 != Scene.last }
        let chosen = pick ?? choices.randomElement() ?? .pool
        Scene.last = chosen
        scene = chosen; sceneStart = now; sceneNoticed = nil; sceneEnding = nil; sceneFocus = nil
        sceneInherited = pointer != nil
    }
    func sceneFrame(now: Date, mood: AgentStage.Mood) -> SceneFrame? {
        guard let scene else { return nil }
        let elapsed = now.timeIntervalSince(sceneStart)
        if sceneEnding == nil {
            if mood == .waiting || mood == .done { sceneEnding = now }
            else if scene.embarrassing { if elapsed > Self.shameLength { sceneEnding = now } }
            else {
                // You come in from outside, or you come close to it: it notices you, then the scene gives way.
                // A pointer arriving in the first moment is the one that opened the page, not a visit.
                if pointer != nil, elapsed < 0.8 { sceneInherited = true }
                let near = pointer.flatMap { point in sceneFocus.map { hypot(point.x - $0.x, point.y - $0.y) < 46 } } ?? false
                if sceneNoticed == nil, let _ = pointer, elapsed > 0.3, !sceneInherited || near { sceneNoticed = now }
                if let noticed = sceneNoticed, now.timeIntervalSince(noticed) > 0.75 { sceneEnding = now }
            }
        }
        var opacity = 1.0
        if let ending = sceneEnding {
            let progress = now.timeIntervalSince(ending) / Self.sceneFade
            if progress >= 1 { self.scene = nil; return nil }
            opacity = 1 - progress
        }
        return SceneFrame(scene: scene, elapsed: elapsed, noticed: sceneNoticed.map { now.timeIntervalSince($0) }, opacity: opacity)
    }

    // MARK: Input

    func move(to point: CGPoint?, now: Date = Date()) {
        defer { pointer = point; pointerAt = now }
        guard let point else { pointerSpeed = 0; sceneInherited = false; return }
        pointerMoved = now
        guard let old = pointer else { return }
        let dt = now.timeIntervalSince(pointerAt)
        if dt > 0.001 { pointerSpeed = hypot(point.x - old.x, point.y - old.y) / CGFloat(dt) }
        // A very fast pass right beside it gives it a fright.
        if pointerSpeed > 2600, abs(point.x - (x ?? point.x)) < 90, flight == nil, !held, !airborne { scaredUntil = now.addingTimeInterval(0.9) }
        // Stroking it back and forth is petting.
        if body.insetBy(dx: -4, dy: -8).contains(point) {
            let dx = point.x - old.x
            if abs(dx) > 1.5 {
                let sign: CGFloat = dx > 0 ? 1 : -1
                if petSign != 0, sign != petSign { petStrokes.append(now) }
                petSign = sign
            }
            petStrokes = petStrokes.filter { now.timeIntervalSince($0) < 1.6 }
            if petStrokes.count >= 4 { petStrokes = []; pet(now) }
        }
    }

    /// A click on the creature pokes it; a click on the floor sends it there.
    @MainActor func tap(at point: CGPoint, now: Date = Date()) {
        guard !held else { return }
        if scene != nil { if sceneNoticed == nil { sceneNoticed = now }; return }
        if let flight {
            // Poked while it peeks: it ducks out of sight for longer.
            if case .peeking = flight { duckFrom = x ?? offstage; duck(now, extra: 1.5) }
            return
        }
        guard body.insetBy(dx: -8, dy: -8).contains(point) else {
            if now > dizzyUntil, now > angryUntil, now > sulkUntil { destination = point.x }
            return
        }
        if now < angryUntil { flee(now); Haptics.play(.generic); return }
        jumpAt = now; disturbedAt = now
        annoyance += now < sulkUntil ? 2 : 1
        if annoyance >= 8 {
            angryUntil = now.addingTimeInterval(5); dizzyUntil = .distantPast; destination = nil; annoyance = 4
            Haptics.play(.generic)
        } else if annoyance >= 4.5, now > dizzyUntil {
            dizzyUntil = now.addingTimeInterval(2.5)
            Haptics.play(.generic)
        } else { Haptics.play(.alignment) }
    }

    /// Picks it up when the drag starts on it.
    func grab(at point: CGPoint) -> Bool {
        guard scene == nil, flight == nil, body.insetBy(dx: -6, dy: -6).contains(point) else { return false }
        held = true; airborne = false; destination = nil; disturbedAt = Date()
        grip = CGSize(width: point.x - (x ?? point.x), height: point.y - body.minY)
        heldPoint = point
        return true
    }
    func hold(at point: CGPoint) {
        heldVelocity = point.x - heldPoint.x
        heldPoint = point
    }
    func release(velocity: CGSize) {
        guard held else { return }
        held = false; airborne = true
        self.velocity = CGVector(dx: max(-700, min(700, velocity.width)), dy: max(-500, min(800, -velocity.height)))
    }

    private func pet(_ now: Date) {
        guard flight == nil || flight == .returning, !held else { return }
        happyUntil = now.addingTimeInterval(2.4)
        if now < sulkUntil || now < angryUntil {
            // A sulking creature needs a little more convincing.
            forgiveness += 1
            if forgiveness >= 2 { forgive() }
        } else { annoyance = 0 }
    }
    private func forgive() {
        sulkUntil = .distantPast; angryUntil = .distantPast; annoyance = 0; grudge = 0; forgiveness = 0
        if flight == .returning { flight = nil }
    }
    private func flee(_ now: Date) {
        // Away from the pointer, off the nearest side.
        side = (pointer?.x ?? width / 2) < (x ?? width / 2) ? 1 : -1
        flight = .running
        grudge += 1; angryUntil = .distantPast; dizzyUntil = .distantPast; annoyance = 0; destination = nil; forgiveness = 0
    }
    static let peekSlide = 1.7
    static let peekLook = 1.2
    /// Looking around before it can notice you.
    static let peekScan = 0.6
    private var noticedAt = Date.distantPast
    static let duckTime = 0.1
    private var duckFrom: CGFloat = 0
    private func duck(_ now: Date, extra: Double = 0) {
        hiddenAt = now
        flight = .hidden(until: now.addingTimeInterval(1.2 + Double.random(in: 0...1) + extra))
    }

    // MARK: Time

    func step(now: Date, home: CGFloat, width: CGFloat, mood: AgentStage.Mood, ground: CGFloat) -> Frame {
        self.width = width; self.ground = ground
        let dt = CGFloat(min(0.1, max(0, now.timeIntervalSince(lastStep ?? now))))
        lastStep = now
        var position = x ?? home
        let t = now.timeIntervalSinceReferenceDate
        if now > angryUntil { annoyance = max(0, annoyance - Double(dt) * 0.35) }
        if now > sulkUntil && flight == nil { forgiveness = 0 }
        let inside = pointer != nil
        let month = Calendar.current.component(.month, from: now)
        var look = AgentStage.Look(eyes: .open(dx: 0, dy: 0), tint: Theme.orange, walking: false, hat: month == 12)
        var frame = Frame(x: position, lift: 0, facing: facing, tilt: 0, look: look)

        func walk(to goal: CGFloat, speed: CGFloat) -> Bool {
            let distance = goal - position
            guard abs(distance) > 2 else { return false }
            position += max(-speed * dt, min(speed * dt, distance))
            facing = distance > 0 ? 1 : -1
            return true
        }

        // Off the stage after being pushed too far.
        if let flight {
            frame.fled = true; seated = false
            look.eyes = .grumpy(dx: 0); look.mouth = .frown
            switch flight {
            case .running:
                look.walking = walk(to: offstage, speed: 190)
                frame.tilt = Double(facing) * 0.12
                if !look.walking { duckFrom = offstage; duck(now) }
            case .hidden(let until):
                // A very quick slide back out of view after ducking: it bolts.
                let out = now.timeIntervalSince(hiddenAt)
                if out < Self.duckTime { position = duckFrom + (offstage - duckFrom) * CGFloat(out / Self.duckTime); facing = -side }
                else { position = offstage; frame.visible = false }
                // Then, whatever happens, it comes and looks before stepping back in.
                if now >= until { self.flight = .peeking(since: now) }
            case .peeking(let since):
                // The head comes in slowly, leaning, then it looks around.
                let seen = now.timeIntervalSince(since)
                let progress = min(1, seen / Self.peekSlide)
                let eased = progress * progress * (3 - 2 * progress)
                position = offstage + (peekSpot - offstage) * CGFloat(eased)
                facing = -side
                frame.peeking = true
                frame.tilt = Double(-side) * 0.28 * eased
                // Fully out, it looks one way, then the other.
                look.eyes = .grumpy(dx: seen > Self.peekSlide ? (Int((seen - Self.peekSlide) / 0.3) % 2 == 0 ? 1 : -1) : 1)
                let scanned = seen > Self.peekSlide + Self.peekScan
                if noticedAt >= since {
                    // It has seen you: eyes on you, away, back on you (a double take), a start, and gone.
                    let toward = ((pointer?.x ?? position) < position ? -1 : 1) * Int(facing)
                    let beat = now.timeIntervalSince(noticedAt)
                    switch beat {
                    case ..<0.4: look.eyes = .open(dx: toward, dy: 0)
                    case ..<0.6: look.eyes = .open(dx: -toward, dy: 0)
                    case ..<0.9: look.eyes = .wide
                    default: look.eyes = .wide; look.mouth = .open; frame.spotted = true
                    }
                    if beat > 1.25 { duckFrom = position; duck(now) }
                } else if scanned, inside {
                    noticedAt = now
                } else if seen > Self.peekSlide + Self.peekLook {
                    // Nobody: in it goes.
                    self.flight = .returning
                }
            case .returning:
                // Back in, slowly, still vexed.
                if inside {
                    // You came back before it was home: off it goes again.
                    self.flight = .running; frame.spotted = true; look.eyes = .wide
                } else {
                    look.walking = walk(to: home, speed: 32)
                    sulkUntil = max(sulkUntil, now.addingTimeInterval(8 + 3 * Double(grudge)))
                    if !look.walking { self.flight = nil }
                }
            }
            if self.flight == .returning || self.flight == nil { frame.cloud = true; frame.sulking = true }
            x = position
            body = CGRect(x: position - half, y: ground - AgentStage.height, width: AgentStage.width, height: AgentStage.height)
            frame.x = position; frame.facing = facing; frame.look = look
            return frame
        }

        let angry = now < angryUntil, dizzy = now < dizzyUntil, sulking = now < sulkUntil
        let happy = now < happyUntil, scared = now < scaredUntil
        var lift: CGFloat = 0
        var squash: CGFloat = 1
        var tilt: Double = 0

        if held {
            position = heldPoint.x - grip.width
            lift = max(0, ground - AgentStage.height - (heldPoint.y - grip.height))
            height = lift
            tilt = Double(max(-0.5, min(0.5, heldVelocity / 30)))
            heldVelocity *= 0.8
            look.eyes = .wide; look.mouth = .open; look.paddling = true
            frame.held = true
        } else if airborne {
            velocity.dy -= 1500 * dt
            height += velocity.dy * dt
            position += velocity.dx * dt
            if position < half + 2 || position > width - half - 2 {
                position = min(max(position, half + 2), width - half - 2); velocity.dx = -velocity.dx * 0.6
            }
            tilt = Double(velocity.dx / 900)
            look.eyes = .wide; look.mouth = .open; look.paddling = true
            if height <= 0 {
                let impact = -velocity.dy
                height = 0; airborne = false; landedAt = now; velocity = .zero
                if impact > 520 { dizzyUntil = now.addingTimeInterval(2); annoyance += 1.5 }
            }
            lift = max(0, height)
        } else {
            // On its feet: decide where to go.
            var goal = home
            // While Claude works, it goes back to its desk unless you just bothered it.
            let atWork = mood == .working && !angry && !dizzy && !sulking && !scared && !happy && now.timeIntervalSince(disturbedAt) > 6
            if atWork { goal = home; destination = nil }
            else if angry {
                goal = (pointer?.x ?? 0) < width / 2 ? width - half - 10 : half + 10
                // You keep hovering over it while it is angry: it has had enough.
                if let pointer, body.insetBy(dx: -6, dy: -6).contains(pointer) {
                    angryHover += Double(dt)
                    if angryHover > 1.2 { angryHover = 0; flee(now) }
                } else { angryHover = 0 }
            } else if dizzy || sulking { goal = position }
            else if scared, let pointer { goal = position + (position >= pointer.x ? 80 : -80) }
            else if let pointer { goal = pointer.x; destination = nil }
            else if let destination { goal = destination }
            goal = min(max(goal, half + 6), width - half - 6)
            let walking = walk(to: goal, speed: angry ? 80 : scared ? 140 : 50)
            look.walking = walking || mood == .working || mood == .done
            seated = atWork && !walking
            if !walking, let pointer, !angry, !sulking { facing = pointer.x >= position ? 1 : -1 }
            if let destination, abs(destination - position) <= 2 { self.destination = nil }

            if !angry && !dizzy && !sulking && !seated {
                switch mood {
                case .working: lift = CGFloat(abs(sin(t * 5.5))) * 4
                case .done: lift = CGFloat(abs(sin(t * 7))) * 9
                default: break
                }
            }
            // The pointer stays just above its head: it jumps to catch it.
            if let pointer, !angry, !dizzy, !sulking, pointer.y < ground - AgentStage.height - 6, abs(pointer.x - position) < 26 {
                if reachSince == nil { reachSince = now }
                if now.timeIntervalSince(reachSince!) > 0.6 { lift = max(lift, CGFloat(abs(sin(t * 7))) * 14); look.eyes = .up }
            } else { reachSince = nil }
        }

        let jump = now.timeIntervalSince(jumpAt)
        if jump < 0.5 && !held && !airborne { lift = max(lift, CGFloat(sin(jump / 0.5 * .pi)) * 14) }
        let landed = now.timeIntervalSince(landedAt)
        if landed < 0.3 { squash = 1 - 0.3 * CGFloat(1 - landed / 0.3) }

        // Fidgets when left alone: looking around, a stretch, a little hop.
        if pointer == nil, !held, !airborne, !angry, !dizzy, !sulking, !seated, mood != .idle {
            if fidget == nil, now > nextFidget {
                fidget = (Int.random(in: 0..<3), now.addingTimeInterval(1.6))
                nextFidget = now.addingTimeInterval(Double.random(in: 7...14))
                if fidget?.kind == 2 { jumpAt = now }
            }
        } else { fidget = nil }
        if let current = fidget, now > current.until { fidget = nil }

        if !held && !airborne {
            if angry {
                look.eyes = .hidden; look.tint = Color(red: 0.93, green: 0.45, blue: 0.36)
                facing = (pointer?.x ?? width / 2) >= position ? -1 : 1
                tilt = sin(t * 30) * 0.03
            } else if dizzy {
                look.eyes = .dizzy; tilt = sin(t * 9) * 0.16
            } else if scared {
                look.eyes = .wide; look.mouth = .open; tilt = sin(t * 40) * 0.05
            } else if happy {
                look.eyes = .happy; look.blush = true; frame.hearts = true
                if !sulking { lift = max(lift, CGFloat(abs(sin(t * 6))) * 3) }
            } else if sulking {
                // Back turned to you, a glance now and then, and a "hmph".
                look.eyes = .grumpy(dx: 0); look.mouth = .frown
                let glancing = now.timeIntervalSince(glanceAt) < 0.6
                if let pointer {
                    facing = pointer.x >= position ? (glancing ? 1 : -1) : (glancing ? -1 : 1)
                    if now.timeIntervalSince(glanceAt) > 3.5 { glanceAt = now }
                    frame.hmph = now.timeIntervalSince(glanceAt) > 0.6 && now.timeIntervalSince(glanceAt) < 1.6
                }
            } else if jump < 0.8 {
                look.eyes = .wide
            } else if case .up = look.eyes {
            } else if mood == .done {
                look.eyes = .happy
            } else if mood == .idle && pointer == nil && destination == nil && !look.walking {
                look.eyes = .closed
            } else if let pointer {
                let dx = pointer.x > position + 30 ? 1 : pointer.x < position - 30 ? -1 : 0
                look.eyes = .open(dx: dx, dy: pointer.y < ground - AgentStage.height ? -1 : 0)
                // You stay still beside it: it waves at you.
                if abs(pointer.x - position) < 60 && now.timeIntervalSince(pointerMoved) > 1.2 { look.wave = true }
            } else if let current = fidget {
                switch current.kind {
                case 0: look.eyes = .open(dx: Int(t * 2) % 2 == 0 ? -1 : 1, dy: 0)
                case 1: squash = 1 + 0.12 * CGFloat(sin(min(1, 1.6 - current.until.timeIntervalSince(now)) / 1.6 * .pi))
                default: break
                }
            }
            if mood == .working, !sulking, !angry, case .open = look.eyes { look.mouth = .talk }
            if mood == .waiting, !sulking, !angry, !scared { look.wave = true }
        }

        x = position
        body = CGRect(x: position - half, y: ground - AgentStage.height - lift, width: AgentStage.width, height: AgentStage.height)
        frame.x = position; frame.lift = lift; frame.facing = facing; frame.tilt = tilt; frame.squash = squash
        frame.look = look; frame.dizzy = dizzy; frame.angry = angry
        frame.sulking = sulking; frame.cloud = sulking
        if held || airborne { seated = false }
        frame.seated = seated
        frame.glance = seated && pointer.map { abs($0.x - position) < 70 } == true
        return frame
    }
}

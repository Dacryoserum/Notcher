import SwiftUI
import NotcherCore

/// What the creature is caught doing when the Agents page opens, like switching to another character in an
/// open-world game: a moment of its own life, interrupted by you. Each scene fills the whole stage.
extension AgentStage {
    /// Draws the scene and returns where the creature is in it.
    @discardableResult
    func drawScene(_ scene: CreatureBrain.Scene, in canvas: inout GraphicsContext, size: CGSize, t: Double, elapsed: Double, noticed: Double?) -> CGPoint? {
        let ground = size.height - 16
        switch scene {
        case .pool:
            pool(&canvas, size, t, noticed)
            return CGPoint(x: size.width * 0.42 + CGFloat(sin(t * 0.23)) * 50, y: size.height * 0.55 + CGFloat(sin(t * 0.37)) * 10)
        case .plane:
            plane(&canvas, size, t, noticed)
            return CGPoint(x: size.width / 2 - 2, y: size.height / 2)
        case .fishing:
            fishing(&canvas, size, ground, t, noticed)
            return CGPoint(x: size.width * 0.46 - 30, y: size.height * 0.64 - 24)
        case .gym:
            gym(&canvas, size, ground, t, noticed)
            return CGPoint(x: size.width / 2, y: ground - 22)
        case .couch:
            couch(&canvas, size, ground, t, elapsed, noticed)
            return CGPoint(x: size.width / 2 - 10, y: ground - 38)
        case .party:
            party(&canvas, size, ground, t, noticed)
            return CGPoint(x: size.width / 2, y: ground - 36)
        case .nose, .mirror, .fridge:
            embarrassing(scene, &canvas, size, ground, t, elapsed)
            return nil
        }
    }

    // MARK: Pieces

    private func box(_ canvas: inout GraphicsContext, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ color: Color) {
        canvas.fill(Path(CGRect(x: x, y: y, width: width, height: height)), with: .color(color))
    }
    private func pixels(_ canvas: inout GraphicsContext, _ rows: [String], at origin: CGPoint, size: CGFloat, _ palette: [Character: Color]) {
        for (row, line) in rows.enumerated() {
            for (column, character) in line.enumerated() {
                guard let color = palette[character] else { continue }
                box(&canvas, origin.x + CGFloat(column) * size, origin.y + CGFloat(row) * size, size, size, color)
            }
        }
    }
    private var orange: Color { Theme.orange }
    private func look(_ eyes: Look.Eyes, mouth: Look.Mouth = .none, walking: Bool = false) -> Look {
        Look(eyes: eyes, tint: Theme.orange, walking: walking, mouth: mouth)
    }
    /// The creature standing with its feet at `ground`, centred on `x`.
    private func stand(_ canvas: inout GraphicsContext, x: CGFloat, ground: CGFloat, t: Double, look: Look, facing: CGFloat = 1, lift: CGFloat = 0, tilt: Double = 0, squash: CGFloat = 1) {
        creature(in: &canvas, at: CGPoint(x: x - AgentStage.width / 2, y: ground - AgentStage.height - lift), pixel: AgentStage.pixel, t: t, look: look, facing: facing, tilt: tilt, squash: squash)
    }
    private func surprise(_ canvas: inout GraphicsContext, at point: CGPoint, t: Double) {
        bubble(in: &canvas, text: "!", color: .white, at: point, t: t)
    }
    private func room(_ canvas: inout GraphicsContext, _ size: CGSize, _ ground: CGFloat, wall: Color = Color(white: 0.1)) {
        box(&canvas, 0, 0, size.width, size.height, wall)
        box(&canvas, 0, ground + 2, size.width, size.height - ground, Color(white: 0.14))
        box(&canvas, 0, ground, size.width, 2, Color(white: 0.2))
    }
    private func notes(_ canvas: inout GraphicsContext, from point: CGPoint, t: Double, color: Color = .white) {
        for index in 0..<3 {
            let progress = (t * 0.6 + Double(index) / 3).truncatingRemainder(dividingBy: 1)
            let position = CGPoint(x: point.x + CGFloat(progress) * 22 + CGFloat(sin(t * 3 + Double(index))) * 4, y: point.y - CGFloat(progress) * 30)
            canvas.draw(Text(index % 2 == 0 ? "♪" : "♫").font(.system(size: 9, weight: .bold)).foregroundColor(color.opacity(0.75 * (1 - progress))), at: position)
        }
    }

    // MARK: Pool, seen from above

    private func pool(_ canvas: inout GraphicsContext, _ size: CGSize, _ t: Double, _ noticed: Double?) {
        box(&canvas, 0, 0, size.width, size.height, Color(red: 0.8, green: 0.76, blue: 0.68))
        let water = CGRect(x: 8, y: 8, width: size.width - 16, height: size.height - 16)
        canvas.fill(Path(roundedRect: water, cornerRadius: 6), with: .color(Color(red: 0.12, green: 0.52, blue: 0.72)))
        var inside = canvas
        inside.clip(to: Path(roundedRect: water, cornerRadius: 6))
        for x in stride(from: water.minX, to: water.maxX, by: 18) { box(&inside, x, water.minY, 1, water.height, .white.opacity(0.06)) }
        for y in stride(from: water.minY, to: water.maxY, by: 18) { box(&inside, water.minX, y, water.width, 1, .white.opacity(0.06)) }
        // Light rippling on the bottom.
        for line in 0..<8 {
            var path = Path()
            let base = water.minY + CGFloat(line) * 17 + 6
            for step in stride(from: CGFloat(0), through: water.width, by: 6) {
                let point = CGPoint(x: water.minX + step, y: base + CGFloat(sin(Double(step) * 0.07 + t * 1.4 + Double(line))) * 3)
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            inside.stroke(path, with: .color(.white.opacity(0.13)), lineWidth: 1.2)
        }
        // A rubber ring and the ladder.
        let ring = CGPoint(x: water.maxX - 40 + CGFloat(sin(t * 0.5)) * 4, y: water.minY + 26)
        inside.stroke(Path(ellipseIn: CGRect(x: ring.x - 13, y: ring.y - 13, width: 26, height: 26)), with: .color(Color(red: 1, green: 0.45, blue: 0.55)), lineWidth: 7)
        for angle in stride(from: 0.0, to: 2 * .pi, by: .pi / 2) {
            box(&inside, ring.x + CGFloat(cos(angle + t * 0.3)) * 13 - 2.5, ring.y + CGFloat(sin(angle + t * 0.3)) * 13 - 2.5, 5, 5, .white)
        }
        for rail in [water.minX + 18, water.minX + 30] { box(&canvas, rail, 2, 3, 18, Color(white: 0.75)) }
        for rung in 0..<3 { box(&canvas, water.minX + 18, 6 + CGFloat(rung) * 5, 15, 1.5, Color(white: 0.75)) }

        // The creature, floating on its back, drifting.
        let center = CGPoint(x: size.width * 0.42 + CGFloat(sin(t * 0.23)) * 50, y: size.height * 0.55 + CGFloat(sin(t * 0.37)) * 10)
        for ripple in 0..<2 {
            let progress = (t * 0.5 + Double(ripple) / 2).truncatingRemainder(dividingBy: 1)
            let radius = 26 + CGFloat(progress) * 24
            inside.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)), with: .color(.white.opacity(0.25 * (1 - progress))), lineWidth: 1)
        }
        var body = inside
        body.translateBy(x: center.x, y: center.y)
        body.rotate(by: .radians(sin(t * 0.2) * 0.5))
        let size4: CGFloat = 4
        let stroke = Int(t * 2) % 2 == 0
        let rows = [
            "....*.*....",
            ".....*.....",
            "...#####...",
            "..#######..",
            ".#########.",
            "a#########b",
            ".#########.",
            ".#########.",
            "..#######..",
            "...#####...",
            "...l...r...",
        ]
        let shades = noticed == nil
        var palette: [Character: Color] = ["#": orange, "*": orange.opacity(0.7)]
        palette["a"] = stroke ? orange : nil; palette["b"] = stroke ? nil : orange
        palette["l"] = Int(t * 4) % 2 == 0 ? orange.opacity(0.8) : nil; palette["r"] = Int(t * 4) % 2 == 1 ? orange.opacity(0.8) : nil
        pixels(&body, rows, at: CGPoint(x: -22, y: -22), size: size4, palette)
        // Arms reaching back in turn, sunglasses, a smile.
        if stroke { box(&body, -26, -30, 4, 10, orange) } else { box(&body, 22, -30, 4, 10, orange) }
        let dark = Color(white: 0.06)
        if shades { box(&body, -14, -6, 12, 4, dark); box(&body, 2, -6, 12, 4, dark); box(&body, -2, -5, 4, 1.5, dark) }
        else { box(&body, -10, -6, 4, 4, dark); box(&body, 6, -6, 4, 4, dark) }
        box(&body, -4, 2, 8, 2, dark)
        if let noticed, noticed < 0.75 { surprise(&canvas, at: CGPoint(x: center.x + 18, y: center.y - 22), t: t) }
    }

    // MARK: Plane

    private func plane(_ canvas: inout GraphicsContext, _ size: CGSize, _ t: Double, _ noticed: Double?) {
        canvas.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(Gradient(colors: [Color(red: 0.15, green: 0.2, blue: 0.4), Color(red: 0.62, green: 0.45, blue: 0.5)]),
                                                                                  startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        canvas.fill(Path(ellipseIn: CGRect(x: size.width - 70, y: size.height - 46, width: 40, height: 40)), with: .color(Color(red: 1, green: 0.7, blue: 0.4).opacity(0.7)))
        // Clouds rushing past, the near ones faster.
        let cloud = ["..xxx...", ".xxxxxx.", "xxxxxxxx"]
        for index in 0..<7 {
            let speed = 40 + Double(index % 3) * 35
            let span = Double(size.width + 90)
            let x = CGFloat(span - (t * speed + Double(index) * 83).truncatingRemainder(dividingBy: span)) - 50
            let y = CGFloat((index * 37) % 100) + 6
            pixels(&canvas, cloud, at: CGPoint(x: x, y: y), size: index % 3 == 2 ? 5 : 3, ["x": .white.opacity(index % 3 == 2 ? 0.8 : 0.45)])
        }
        let center = CGPoint(x: size.width / 2, y: size.height / 2 + CGFloat(sin(t * 1.3)) * 3)
        // Contrail.
        for trail in 0..<2 { box(&canvas, 0, center.y - 2 + CGFloat(trail) * 6, center.x - 70, 2, .white.opacity(0.25)) }
        // Tail fin, wing, body, nose.
        var fin = Path()
        fin.move(to: CGPoint(x: center.x - 74, y: center.y - 8)); fin.addLine(to: CGPoint(x: center.x - 86, y: center.y - 34))
        fin.addLine(to: CGPoint(x: center.x - 70, y: center.y - 34)); fin.addLine(to: CGPoint(x: center.x - 54, y: center.y - 8)); fin.closeSubpath()
        canvas.fill(fin, with: .color(orange))
        let fuselage = CGRect(x: center.x - 80, y: center.y - 12, width: 150, height: 26)
        canvas.fill(Path(roundedRect: fuselage, cornerRadius: 13), with: .color(Color(white: 0.94)))
        box(&canvas, fuselage.minX + 10, center.y + 6, fuselage.width - 22, 3, accent.opacity(0.8))
        var wing = Path()
        wing.move(to: CGPoint(x: center.x - 10, y: center.y + 6)); wing.addLine(to: CGPoint(x: center.x + 24, y: center.y + 6))
        wing.addLine(to: CGPoint(x: center.x - 6, y: center.y + 30)); wing.addLine(to: CGPoint(x: center.x - 26, y: center.y + 30)); wing.closeSubpath()
        canvas.fill(wing, with: .color(Color(white: 0.7)))
        box(&canvas, fuselage.maxX - 22, center.y - 7, 10, 6, Color(red: 0.2, green: 0.3, blue: 0.45))
        // Windows; the creature's face in one of them, asleep against the glass.
        for index in 0..<8 {
            let window = CGRect(x: fuselage.minX + 22 + CGFloat(index) * 13, y: center.y - 6, width: 8, height: 8)
            if index == 4 {
                let face = window.insetBy(dx: -2, dy: -2)
                canvas.fill(Path(roundedRect: face, cornerRadius: 3), with: .color(orange))
                let dark = Color(white: 0.06)
                if noticed == nil { box(&canvas, face.minX + 2, face.midY, 3, 1.5, dark); box(&canvas, face.maxX - 5, face.midY, 3, 1.5, dark) }
                else { box(&canvas, face.minX + 2.5, face.midY - 2, 2, 3, dark); box(&canvas, face.maxX - 4.5, face.midY - 2, 2, 3, dark) }
            } else { canvas.fill(Path(roundedRect: window, cornerRadius: 2), with: .color(Color(red: 0.3, green: 0.42, blue: 0.58))) }
        }
        let window = CGPoint(x: fuselage.minX + 22 + 4 * 13 + 4, y: center.y - 8)
        if let noticed, noticed < 0.75 { surprise(&canvas, at: CGPoint(x: window.x + 6, y: window.y - 6), t: t) }
        else if noticed == nil { sleep(in: &canvas, at: CGPoint(x: window.x + 6, y: window.y - 4), t: t) }
    }

    // MARK: Fishing at night

    private func fishing(_ canvas: inout GraphicsContext, _ size: CGSize, _ ground: CGFloat, _ t: Double, _ noticed: Double?) {
        let waterline = size.height * 0.64
        box(&canvas, 0, 0, size.width, waterline, Color(red: 0.05, green: 0.07, blue: 0.16))
        for index in 0..<16 {
            let glow = 0.2 + 0.25 * (0.5 + 0.5 * sin(t + Double(index)))
            box(&canvas, CGFloat((index * 71) % Int(size.width)), CGFloat((index * 23) % Int(waterline - 10)), 1.5, 1.5, .white.opacity(glow))
        }
        let moon = CGPoint(x: size.width - 46, y: 24)
        canvas.fill(Path(ellipseIn: CGRect(x: moon.x - 11, y: moon.y - 11, width: 22, height: 22)), with: .color(Color(red: 0.95, green: 0.93, blue: 0.8)))
        box(&canvas, 0, waterline, size.width, size.height - waterline, Color(red: 0.06, green: 0.13, blue: 0.24))
        for line in 0..<6 {
            let y = waterline + 4 + CGFloat(line) * 7
            let offset = CGFloat((t * 8 + Double(line) * 13).truncatingRemainder(dividingBy: 40))
            for x in stride(from: -40 + offset, to: size.width, by: 40) { box(&canvas, x, y, 14, 1, .white.opacity(0.08)) }
            box(&canvas, moon.x - 8 + CGFloat(sin(t * 2 + Double(line))) * 3, y, 16 - CGFloat(line) * 2, 1.5, Color(red: 0.95, green: 0.93, blue: 0.8).opacity(0.5))
        }
        // The dock and the creature sitting at its end.
        let dockEnd = size.width * 0.46
        box(&canvas, 0, waterline - 6, dockEnd, 6, Color(red: 0.42, green: 0.3, blue: 0.2))
        for post in stride(from: CGFloat(10), to: dockEnd, by: 34) { box(&canvas, post, waterline, 4, 18, Color(red: 0.3, green: 0.2, blue: 0.13)) }
        let x = dockEnd - 30
        let watching = noticed != nil
        stand(&canvas, x: x, ground: waterline - 2, t: t, look: look(watching ? .open(dx: -1, dy: 0) : .open(dx: 1, dy: 1)))
        // Rod, line and float; now and then a fish nibbles.
        let tip = CGPoint(x: x + 64, y: waterline - 58)
        var rod = Path(); rod.move(to: CGPoint(x: x + 22, y: waterline - 18)); rod.addLine(to: tip)
        canvas.stroke(rod, with: .color(Color(red: 0.55, green: 0.38, blue: 0.22)), lineWidth: 2)
        let nibble = t.truncatingRemainder(dividingBy: 5) < 0.5
        let float = CGPoint(x: tip.x + 34, y: waterline + 3 + CGFloat(sin(t * 3)) * 1.5 + (nibble ? 4 : 0))
        var line = Path(); line.move(to: tip); line.addQuadCurve(to: float, control: CGPoint(x: tip.x + 30, y: tip.y + 20))
        canvas.stroke(line, with: .color(.white.opacity(0.5)), lineWidth: 0.7)
        box(&canvas, float.x - 2, float.y - 4, 4, 3, .red); box(&canvas, float.x - 2, float.y - 1, 4, 2, .white)
        let ring = 6 + CGFloat((t * 1.2).truncatingRemainder(dividingBy: 1)) * 10
        canvas.stroke(Path(ellipseIn: CGRect(x: float.x - ring, y: float.y - ring / 3, width: ring * 2, height: ring * 0.66)), with: .color(.white.opacity(0.2)), lineWidth: 1)
        if let noticed, noticed < 0.75 { surprise(&canvas, at: CGPoint(x: x + 28, y: waterline - 60), t: t) }
    }

    // MARK: Gym

    private func gym(_ canvas: inout GraphicsContext, _ size: CGSize, _ ground: CGFloat, _ t: Double, _ noticed: Double?) {
        room(&canvas, size, ground, wall: Color(red: 0.1, green: 0.1, blue: 0.13))
        box(&canvas, size.width / 2 - 60, ground - 2, 120, 4, Color(red: 0.45, green: 0.12, blue: 0.14))
        // A rack of dumbbells on the wall side.
        for index in 0..<4 { box(&canvas, 16 + CGFloat(index) * 12, ground - 30, 8, 5, Color(white: 0.35)) }
        box(&canvas, 12, ground - 25, 50, 3, Color(white: 0.25))
        let x = size.width / 2
        let dropped = noticed != nil
        let up = !dropped && sin(t * 2.4) > 0
        let squash: CGFloat = up ? 1 : 0.94
        stand(&canvas, x: x, ground: ground, t: t, look: look(dropped ? .wide : up ? .grumpy(dx: 0) : .closed, mouth: dropped ? .open : .frown), squash: squash)
        let barY = dropped ? ground - 6 : up ? ground - AgentStage.height - 12 : ground - AgentStage.height + 12
        if !dropped {
            // Arms from the shoulders to the bar, fists on it.
            let shoulder = ground - AgentStage.height + 5.5 * AgentStage.pixel * squash
            for side in [-1.0, 1.0] {
                var arm = Path()
                arm.move(to: CGPoint(x: x + CGFloat(side) * 20, y: shoulder))
                arm.addLine(to: CGPoint(x: x + CGFloat(side) * (up ? 30 : 32), y: shoulder + (up ? -6 : 6)))
                arm.addLine(to: CGPoint(x: x + CGFloat(side) * 30, y: barY + 1.5))
                canvas.stroke(arm, with: .color(orange), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                box(&canvas, x + CGFloat(side) * 30 - 3, barY - 2, 6, 6, Color(red: 0.8, green: 0.48, blue: 0.3))
            }
        }
        box(&canvas, x - 50, barY, 100, 3, Color(white: 0.7))
        for side in [-1.0, 1.0] {
            box(&canvas, x + CGFloat(side) * 46 - 4, barY - 9, 8, 21, Color(red: 0.6, green: 0.15, blue: 0.17))
            box(&canvas, x + CGFloat(side) * 54 - 2, barY - 6, 4, 15, Color(white: 0.15))
        }
        if !dropped {
            for drop in 0..<2 {
                let progress = (t * 1.5 + Double(drop) / 2).truncatingRemainder(dividingBy: 1)
                box(&canvas, x + (drop == 0 ? -24 : 22), ground - AgentStage.height + 4 + CGFloat(progress) * 14, 2, 3, Color(red: 0.5, green: 0.75, blue: 1).opacity(1 - progress))
            }
            let reps = 8 + Int(t * 2.4 / (2 * .pi)) % 20
            canvas.draw(Text("× \(reps)").font(.system(size: 11, weight: .heavy, design: .rounded)).foregroundColor(.white.opacity(0.6)), at: CGPoint(x: size.width - 30, y: 18))
        } else if let noticed, noticed < 0.75 { surprise(&canvas, at: CGPoint(x: x + 28, y: ground - AgentStage.height - 6), t: t) }
    }

    // MARK: Couch and TV

    private func couch(_ canvas: inout GraphicsContext, _ size: CGSize, _ ground: CGFloat, _ t: Double, _ elapsed: Double, _ noticed: Double?) {
        room(&canvas, size, ground, wall: Color(red: 0.13, green: 0.1, blue: 0.16))
        let x = size.width / 2
        let red = Color(red: 0.6, green: 0.17, blue: 0.2)
        canvas.fill(Path(roundedRect: CGRect(x: x - 64, y: ground - 50, width: 128, height: 30), cornerRadius: 6), with: .color(red.opacity(0.85)))
        stand(&canvas, x: x - 10, ground: ground - 16, t: t, look: look(noticed != nil ? .wide : .open(dx: 0, dy: 0), mouth: noticed != nil ? .open : .none))
        canvas.fill(Path(roundedRect: CGRect(x: x - 64, y: ground - 22, width: 128, height: 20), cornerRadius: 4), with: .color(red))
        for arm in [x - 72, x + 58] { canvas.fill(Path(roundedRect: CGRect(x: arm, y: ground - 36, width: 14, height: 34), cornerRadius: 4), with: .color(red.opacity(0.95))) }
        // Popcorn, one piece flying into its mouth now and then (frozen in the air when you come in).
        let bucket = CGPoint(x: x + 30, y: ground - 34)
        box(&canvas, bucket.x - 7, bucket.y, 14, 14, .white)
        for stripe in 0..<3 { box(&canvas, bucket.x - 6 + CGFloat(stripe) * 5, bucket.y, 2, 14, .red) }
        for kernel in 0..<4 { box(&canvas, bucket.x - 6 + CGFloat(kernel) * 3.5, bucket.y - 3 - CGFloat(kernel % 2) * 2, 3, 3, Color(red: 1, green: 0.93, blue: 0.6)) }
        let cycle = noticed == nil ? (t * 0.5).truncatingRemainder(dividingBy: 1) : 0.5
        if cycle < 0.7 {
            let progress = CGFloat(cycle / 0.7)
            let from = CGPoint(x: bucket.x, y: bucket.y - 4), to = CGPoint(x: x - 4, y: ground - 16 - 14)
            let point = CGPoint(x: from.x + (to.x - from.x) * progress, y: from.y + (to.y - from.y) * progress - sin(progress * .pi) * 30)
            box(&canvas, point.x, point.y, 3, 3, Color(red: 1, green: 0.93, blue: 0.6))
        }
        // The light of the TV, which we do not see, flickering on everything.
        let hue = Int(t * 3) % 4
        let light = [Color.blue, .white, Color(red: 1, green: 0.4, blue: 0.4), .cyan][hue]
        canvas.fill(Path(CGRect(origin: .zero, size: size)), with: .color(light.opacity(0.05 + 0.04 * (0.5 + 0.5 * sin(t * 13)))))
        if let noticed, noticed < 0.75 { surprise(&canvas, at: CGPoint(x: x + 18, y: ground - 16 - AgentStage.height - 4), t: t) }
    }

    // MARK: Party

    private func party(_ canvas: inout GraphicsContext, _ size: CGSize, _ ground: CGFloat, _ t: Double, _ noticed: Double?) {
        box(&canvas, 0, 0, size.width, size.height, Color(red: 0.05, green: 0.03, blue: 0.09))
        let frozen = noticed != nil
        let time = frozen ? 0 : t
        // Dance floor tiles lighting up.
        for column in 0..<Int(size.width / 20) + 1 {
            let on = (column + Int(time * 4)) % 3 == 0
            let colors = [Color.pink, .cyan, .yellow, .purple]
            box(&canvas, CGFloat(column) * 20, ground + 2, 19, size.height - ground, on ? colors[column % 4].opacity(0.45) : Color(white: 0.12))
        }
        // Beams from the disco ball.
        let ball = CGPoint(x: size.width / 2, y: 14)
        for beam in 0..<4 {
            let angle = sin(time * 1.1 + Double(beam) * 1.6) * 0.9 + .pi / 2
            var path = Path()
            path.move(to: ball)
            path.addLine(to: CGPoint(x: ball.x + CGFloat(cos(angle - 0.08)) * 220, y: ball.y + CGFloat(sin(angle - 0.08)) * 220))
            path.addLine(to: CGPoint(x: ball.x + CGFloat(cos(angle + 0.08)) * 220, y: ball.y + CGFloat(sin(angle + 0.08)) * 220))
            path.closeSubpath()
            canvas.fill(path, with: .color([Color.pink, .cyan, .yellow, .purple][beam].opacity(frozen ? 0.05 : 0.14)))
        }
        canvas.fill(Path(ellipseIn: CGRect(x: ball.x - 9, y: ball.y - 9, width: 18, height: 18)), with: .color(Color(white: 0.75)))
        for facet in 0..<6 where (facet + Int(time * 6)) % 3 == 0 { box(&canvas, ball.x - 6 + CGFloat(facet % 3) * 4, ball.y - 4 + CGFloat(facet / 3) * 5, 3, 3, .white) }
        box(&canvas, ball.x - 0.5, 0, 1, 5, Color(white: 0.5))
        // The creature behind its decks, headphones on, bobbing.
        let x = size.width / 2
        let lift = frozen ? 0 : CGFloat(abs(sin(t * 8))) * 4
        stand(&canvas, x: x, ground: ground - 14, t: time, look: look(frozen ? .wide : .closed, mouth: frozen ? .open : .none, walking: !frozen), lift: lift)
        let head = ground - 14 - AgentStage.height - lift
        let dark = Color(white: 0.08)
        var band = Path()
        band.addArc(center: CGPoint(x: x, y: head + 22), radius: 24, startAngle: .degrees(200), endAngle: .degrees(340), clockwise: false)
        canvas.stroke(band, with: .color(dark), lineWidth: 3)
        box(&canvas, x - 27, head + 18, 6, 10, dark); box(&canvas, x + 21, head + 18, 6, 10, dark)
        if !frozen, sin(t * 4) > 0.3 { box(&canvas, x + 26, head - 2, 4, 14, orange) }
        let booth = CGRect(x: x - 46, y: ground - 26, width: 92, height: 28)
        box(&canvas, booth.minX, booth.minY, booth.width, booth.height, Color(white: 0.16))
        box(&canvas, booth.minX, booth.minY + 10, booth.width, 2, accent.opacity(0.8))
        for deck in [booth.minX + 8, booth.maxX - 30] {
            canvas.fill(Path(ellipseIn: CGRect(x: deck, y: booth.minY - 4, width: 22, height: 7)), with: .color(dark))
            let spin = time * 6
            box(&canvas, deck + 11 + CGFloat(cos(spin)) * 7, booth.minY - 0.5 + CGFloat(sin(spin)) * 2, 2, 2, .white.opacity(0.6))
        }
        if !frozen { notes(&canvas, from: CGPoint(x: x + 30, y: head + 4), t: t, color: .pink) }
        if let noticed, noticed < 0.75 { surprise(&canvas, at: CGPoint(x: x + 28, y: head - 2), t: t) }
    }

    // MARK: Embarrassing moments, tidied up at once

    /// 0: caught in the act, 1: it sees you, 2: everything disappears, 3: whistling as if nothing happened.
    private func shame(_ elapsed: Double) -> (phase: Int, progress: Double) {
        // Long enough to see what it was doing, and to enjoy the innocent face afterwards.
        switch elapsed {
        case ..<2.8: return (0, elapsed / 2.8)
        case ..<3.6: return (1, (elapsed - 2.8) / 0.8)
        case ..<4.1: return (2, (elapsed - 3.6) / 0.5)
        default: return (3, (elapsed - 4.1) / 3)
        }
    }
    private func embarrassing(_ scene: CreatureBrain.Scene, _ canvas: inout GraphicsContext, _ size: CGSize, _ ground: CGFloat, _ t: Double, _ elapsed: Double) {
        let (phase, progress) = shame(elapsed)
        let x = size.width / 2 + (scene == .mirror ? 30 : scene == .fridge ? 20 : 0)
        let dark = Color(white: 0.06)
        let night = scene == .fridge
        room(&canvas, size, ground, wall: night ? Color(white: 0.04) : Color(red: 0.12, green: 0.11, blue: 0.1))
        let flung = phase >= 2 ? CGFloat(phase == 2 ? progress : 1) * 320 : 0

        switch scene {
        case .mirror:
            // A mirror on the wall, its reflection singing too.
            let frame = CGRect(x: 26 - flung * 0, y: ground - 82, width: 52, height: 80)
            canvas.stroke(Path(ellipseIn: frame), with: .color(Color(red: 0.85, green: 0.68, blue: 0.3)), lineWidth: 3)
            canvas.fill(Path(ellipseIn: frame.insetBy(dx: 2, dy: 2)), with: .color(Color(red: 0.55, green: 0.68, blue: 0.78).opacity(0.35)))
            if phase < 2 {
                var glass = canvas
                glass.clip(to: Path(ellipseIn: frame.insetBy(dx: 2, dy: 2)))
                glass.opacity = 0.45
                creature(in: &glass, at: CGPoint(x: frame.midX - AgentStage.width / 2, y: ground - AgentStage.height - 8), pixel: AgentStage.pixel, t: t,
                         look: look(phase == 0 ? .closed : .wide, mouth: .open), facing: 1, tilt: 0, squash: 1)
            }
        case .fridge:
            let fridge = CGRect(x: 20, y: ground - 92, width: 50, height: 92)
            let open = phase < 2
            if open {
                // Its light spills over the floor.
                var cone = Path()
                cone.move(to: CGPoint(x: fridge.maxX, y: fridge.minY + 6)); cone.addLine(to: CGPoint(x: size.width - 20, y: ground + 14))
                cone.addLine(to: CGPoint(x: fridge.maxX, y: ground + 14)); cone.closeSubpath()
                canvas.fill(cone, with: .color(Color(red: 1, green: 0.9, blue: 0.6).opacity(0.13)))
                box(&canvas, fridge.minX, fridge.minY, fridge.width, fridge.height, Color(red: 1, green: 0.95, blue: 0.8))
                for shelf in 1..<4 { box(&canvas, fridge.minX + 3, fridge.minY + CGFloat(shelf) * 22, fridge.width - 6, 2, Color(white: 0.75)) }
                box(&canvas, fridge.minX + 6, fridge.minY + 10, 8, 12, .green.opacity(0.7)); box(&canvas, fridge.minX + 30, fridge.minY + 34, 12, 8, .red.opacity(0.6))
                box(&canvas, fridge.minX - 8, fridge.minY, 8, fridge.height, Color(white: 0.82))
            } else {
                box(&canvas, fridge.minX, fridge.minY, fridge.width, fridge.height, Color(white: 0.3))
                box(&canvas, fridge.maxX - 8, fridge.minY + 20, 3, 18, Color(white: 0.5))
                // The door just slammed.
                if phase == 2 { canvas.draw(Text(L("clac")).font(.system(size: 9, weight: .heavy, design: .rounded)).foregroundColor(.white.opacity(0.7)), at: CGPoint(x: fridge.midX, y: fridge.minY - 8)) }
            }
        default: break
        }

        if phase < 3 {
            let caught = phase >= 1
            let facing: CGFloat = scene == .mirror || scene == .fridge ? (caught ? 1 : -1) : 1
            let eyes: Look.Eyes = caught ? .wide : scene == .nose ? .closed : scene == .mirror ? .closed : .happy
            let mouth: Look.Mouth = caught ? .open : scene == .fridge ? .talk : scene == .mirror ? (Int(t * 5) % 2 == 0 ? .open : .none) : .none
            let lift: CGFloat = phase == 0 && scene == .mirror ? CGFloat(abs(sin(t * 6))) * 4 : 0
            let tilt = phase == 2 ? sin(t * 40) * 0.1 : 0
            stand(&canvas, x: x, ground: ground, t: t, look: look(eyes, mouth: mouth), facing: facing, lift: lift, tilt: tilt)
            let top = ground - AgentStage.height - lift
            let pixel = AgentStage.pixel
            switch scene {
            case .nose:
                // A finger up its nose, wiggling, until it sees you.
                if phase < 2 {
                    // The arm comes out from its side, bends up, and crosses its face to the middle.
                    let wiggle: CGFloat = phase == 0 && Int(t * 6) % 2 == 0 ? 1.5 : 0
                    let arm = Color(red: 0.72, green: 0.4, blue: 0.24)
                    var path = Path()
                    path.move(to: CGPoint(x: x + 6 * pixel, y: top + 8.5 * pixel))
                    path.addLine(to: CGPoint(x: x + 8 * pixel, y: top + 7 * pixel))
                    path.addLine(to: CGPoint(x: x + 1.2 * pixel, y: top + 7.6 * pixel - wiggle))
                    canvas.stroke(path, with: .color(arm), style: StrokeStyle(lineWidth: pixel * 0.9, lineCap: .round, lineJoin: .round))
                    canvas.fill(Path(ellipseIn: CGRect(x: x - 0.2 * pixel, y: top + 7.1 * pixel - wiggle, width: pixel * 1.5, height: pixel * 1.1)), with: .color(Color(red: 1, green: 0.75, blue: 0.6)))
                }
            case .mirror:
                // A hairbrush for a microphone.
                let brush = CGPoint(x: x - 2.5 * pixel - flung, y: top + 7 * pixel - (phase == 2 ? CGFloat(progress) * 30 : 0))
                box(&canvas, brush.x, brush.y + 4, 3, 16, Color(red: 0.5, green: 0.3, blue: 0.18))
                canvas.fill(Path(ellipseIn: CGRect(x: brush.x - 3, y: brush.y - 4, width: 9, height: 9)), with: .color(Color(white: 0.15)))
                if phase == 0 { notes(&canvas, from: CGPoint(x: x - 30, y: top), t: t) }
            case .fridge:
                // A whole cake, eaten with both hands.
                let cake = CGRect(x: x - 3.5 * pixel - 14 - flung, y: top + 6 * pixel - (phase == 2 ? CGFloat(progress) * 20 : 0), width: 18, height: 12)
                box(&canvas, cake.minX, cake.minY, cake.width, cake.height, Color(red: 0.95, green: 0.85, blue: 0.75))
                box(&canvas, cake.minX, cake.minY, cake.width, 4, Color(red: 1, green: 0.5, blue: 0.65))
                box(&canvas, cake.midX - 1, cake.minY - 5, 2, 5, .white); box(&canvas, cake.midX - 1, cake.minY - 7, 2, 2, .orange)
                if phase == 0 {
                    for crumb in 0..<3 {
                        let fall = (t * 2 + Double(crumb) / 3).truncatingRemainder(dividingBy: 1)
                        box(&canvas, x - 14 + CGFloat(crumb) * 5, top + 9 * pixel + CGFloat(fall) * 12, 2, 2, Color(red: 0.95, green: 0.85, blue: 0.75).opacity(1 - fall))
                    }
                }
            default: break
            }
            if phase == 1 { bubble(in: &canvas, text: "!", color: Color(red: 0.95, green: 0.35, blue: 0.3), at: CGPoint(x: x + 26, y: top - 2), t: t) }
            if phase == 2 { poof(&canvas, at: CGPoint(x: x, y: ground - 20), progress: progress) }
        } else {
            // As if nothing happened: eyes elsewhere, whistling, a drop of sweat.
            let glance = Int(t * 1.5) % 2 == 0 ? 1 : -1
            stand(&canvas, x: x + (sin(t * 2) * 2).rounded(), ground: ground, t: t, look: look(.open(dx: glance, dy: -1), mouth: .open))
            let top = ground - AgentStage.height
            notes(&canvas, from: CGPoint(x: x + 30, y: top + 22), t: t)
            let drip = CGFloat((t * 0.8).truncatingRemainder(dividingBy: 1)) * 6
            box(&canvas, x + 18, top + 18 + drip, 3, 4, Color(red: 0.5, green: 0.75, blue: 1))
            if scene == .fridge { box(&canvas, x - 6, top + 33, 2, 2, Color(red: 1, green: 0.5, blue: 0.65)); box(&canvas, x + 4, top + 34, 2, 2, Color(red: 0.95, green: 0.85, blue: 0.75)) }
            _ = dark
        }
    }
    private func poof(_ canvas: inout GraphicsContext, at point: CGPoint, progress: Double) {
        for puff in 0..<7 {
            let angle = Double(puff) / 7 * 2 * .pi
            let distance = 10 + CGFloat(progress) * 26
            let radius = 8 + CGFloat(progress) * 6
            let center = CGPoint(x: point.x + CGFloat(cos(angle)) * distance, y: point.y + CGFloat(sin(angle)) * distance * 0.6)
            canvas.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)), with: .color(.white.opacity(0.55 * (1 - progress))))
        }
    }
}

import SwiftUI
import NotcherCore

struct HomeView: View {
    @ObservedObject var model: AppModel
    @ViewBuilder
    var body: some View {
        switch model.preferences.dashboardLayout {
        case .overview: overview
        case .media:
            VStack(spacing: 12) {
                MediaCard(media: model.media).frame(maxHeight: .infinity)
                AudioCard(system: model.system).frame(height: 108)
            }
        case .pomodoro: FocusView(focus: model.focus)
        }
    }
    /// Each widget is drawn in the cells its item covers; the grid itself is never visible.
    private var overview: some View {
        GeometryReader { geometry in
            let layout = model.preferences.homeLayout
            ZStack(alignment: .topLeading) {
                ForEach(layout.items) { item in
                    let frame = HomeLayout.frame(of: item, in: geometry.size, spacing: 12)
                    HomeWidgetView(model: model, widget: item.widget, size: frame.size)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .animation(.snappy(duration: 0.28), value: layout)
        }
    }
}

/// Position in the track. Dragging previews the position; releasing seeks.
struct MediaTimeline: View {
    @ObservedObject var media: MediaService
    var labels = true
    @State private var seeking = false
    @State private var seekPosition: Double = 0
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 8) {
                if labels { Text(clockString(seeking ? seekPosition : media.elapsed)) }
                Slider(value: Binding(get: { seeking ? seekPosition : media.elapsed }, set: { seekPosition = $0 }), in: 0...max(1, media.track?.duration ?? 1), onEditingChanged: { editing in
                    if editing { seekPosition = media.elapsed }
                    seeking = editing
                    if !editing { media.command("seek", value: seekPosition) }
                }).controlSize(.mini).disabled((media.track?.duration ?? 0) <= 0)
                if labels { Text(clockString(media.track?.duration ?? 0)) }
            }.font(.system(size: 8, design: .monospaced)).foregroundStyle(Theme.muted)
        }
    }
}

struct MediaCard: View {
    @Environment(\.notcherAccent) private var accent
    @ObservedObject var media: MediaService
    /// Space given to the card; nil draws the complete card.
    var size: CGSize? = nil
    /// From this width a compact card has room for the timeline as well as the buttons.
    static let timelineWidth: CGFloat = 380

    private var playing: Bool { media.track?.playing == true }
    private func playButton(_ side: CGFloat = 30) -> some View {
        Button { media.command("toggle"); Haptics.play(.generic) } label: {
            Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: side * 0.37, weight: .bold)).contentTransition(.symbolEffect(.replace))
                .foregroundStyle(accent.contrastingText).frame(width: side, height: side).background(accent, in: Circle()).contentShape(Rectangle())
        }.buttonStyle(PressStyle(scale: 0.9)).disabled(media.track == nil).accessibilityLabel(L(playing ? "Pause" : "Lecture"))
    }
    private var titles: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(media.track?.title ?? L("Aucune lecture")).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Text(media.track.map { $0.artist.isEmpty ? $0.application : $0.artist } ?? L("Lance un lecteur")).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
    }
    private func transports(previous: Bool = true, next: Bool = true) -> some View {
        HStack(spacing: 0) {
            if previous { transport("backward.fill", "Morceau précédent", "previous") }
            playButton()
            if next { transport("forward.fill", "Morceau suivant", "next") }
        }
    }
    @ViewBuilder var body: some View {
        if let size {
            let width = size.width, height = size.height
            if width >= 360 && height >= 195 { full }
            else if width < 110 && height < 110 { tile }
            else if height < 110 {
                // One row of cells: cover, then as much as the width allows.
                Card(padding: 8) {
                    HStack(spacing: 8) {
                        artwork(height - 16, radius: 10)
                        if width >= 215 {
                            VStack(alignment: .leading, spacing: 2) {
                                titles
                                if width >= Self.timelineWidth { MediaTimeline(media: media, labels: width >= 470) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        } else { Spacer(minLength: 0) }
                        transports(previous: width >= 300, next: width >= 140)
                    }
                }
            } else if width < 110 {
                Card(padding: 8) { VStack(spacing: 8) { artwork(width - 16, radius: 10); playButton(); if height >= 200 { transport("forward.fill", "Morceau suivant", "next") } }.frame(maxHeight: .infinity) }
            } else if height >= 180 {
                Card(padding: 14) {
                    VStack(spacing: 9) {
                        artwork(min(96, height - 130))
                        titles.frame(maxWidth: .infinity, alignment: .leading)
                        if width >= 300 { MediaTimeline(media: media) }
                        transports()
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                Card(padding: 12) {
                    VStack(spacing: 6) {
                        HStack(spacing: 12) {
                            if width >= 215 { artwork(width >= Self.timelineWidth ? 56 : 64) }
                            titles.frame(maxWidth: .infinity, alignment: .leading)
                            if width >= 300 { transports() }
                        }
                        if width < 300 { transports().frame(maxWidth: .infinity, alignment: width >= 215 ? .trailing : .leading) }
                        if width >= Self.timelineWidth { MediaTimeline(media: media) }
                    }.frame(maxHeight: .infinity)
                }
            }
        } else { full }
    }
    /// A single cell: the cover itself is the play button.
    private var tile: some View {
        Button { media.command("toggle"); Haptics.play(.generic) } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(Theme.surface)
                if let image = media.artwork { Image(nsImage: image).resizable().scaledToFill().opacity(0.55) }
                Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: 17, weight: .bold)).foregroundStyle(media.artwork == nil ? accent : .white)
                    .contentTransition(.symbolEffect(.replace)).shadow(color: .black.opacity(0.5), radius: 3)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.border)).contentShape(Rectangle())
        }.buttonStyle(PressStyle(scale: 0.95)).disabled(media.track == nil)
            .help(media.track.map { $0.title + " · " + $0.artist } ?? L("Aucune lecture")).accessibilityLabel(L(playing ? "Pause" : "Lecture"))
    }
    private var full: some View {
        Card {
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Eyebrow(text: "Médias")
                    Spacer()
                    if let track = media.track { Text(track.application).font(.system(size: 9)).foregroundStyle(accent).lineLimit(1) }
                    else { Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 10)).foregroundStyle(Theme.muted) }
                }
                HStack(spacing: 15) {
                    artwork(68)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(media.track?.title ?? L("Aucune lecture")).font(.system(size: 16, weight: .semibold)).lineLimit(2)
                        if let track = media.track { Text(track.artist.isEmpty ? track.application : track.artist).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                        if media.track == nil {
                            HStack(spacing: 10) {
                                Button("Spotify") { media.openPlayer("com.spotify.client") }
                                Button("Pistolame") { media.openPlayer("com.dacryoserum.pistolame") }
                                Button("Music") { media.openPlayer("com.apple.Music") }
                            }.buttonStyle(.plain).font(.system(size: 9, weight: .medium)).foregroundStyle(accent).padding(.top, 4)
                        } else { Text(media.track?.album ?? "").font(.system(size: 9)).foregroundStyle(Theme.muted).lineLimit(1) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
                VStack(spacing: 8) {
                    MediaTimeline(media: media)
                    HStack(spacing: 22) {
                        Spacer()
                        transport("backward.fill", "Morceau précédent", "previous")
                        playButton(34)
                        transport("forward.fill", "Morceau suivant", "next")
                        Spacer()
                    }
                }
            }.frame(maxHeight: .infinity)
        }.overlay(alignment: .bottomLeading) { if let error = media.error { Text(L(error)).font(.system(size: 8)).foregroundStyle(Theme.orange).lineLimit(1).padding(.horizontal, 16).padding(.bottom, 4) } }
    }
    private func artwork(_ side: CGFloat, radius: CGFloat = 13) -> some View {
        let side = max(24, side)
        return ZStack {
            RoundedRectangle(cornerRadius: radius).fill(LinearGradient(colors: [accent.opacity(0.23), accent.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing))
            if let image = media.artwork { Image(nsImage: image).resizable().scaledToFill() }
            else {
                if side >= 60 {
                    Circle().stroke(accent.opacity(0.16), lineWidth: 1).frame(width: side * 0.72, height: side * 0.72)
                    Circle().stroke(accent.opacity(0.12), lineWidth: 1).frame(width: side * 0.52, height: side * 0.52)
                }
                Image(systemName: "music.note").font(.system(size: side * 0.34, weight: .light)).foregroundStyle(accent)
            }
        }.frame(width: side, height: side).clipShape(RoundedRectangle(cornerRadius: radius))
            .animation(.easeOut(duration: 0.25), value: media.artwork)
    }
    private func transport(_ symbol: String, _ title: String, _ action: String) -> some View {
        Button { media.command(action); Haptics.play(.generic) } label: { Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(.white.opacity(0.8)).frame(width: 34, height: 32).contentShape(Rectangle()) }.buttonStyle(PressStyle(scale: 0.85)).disabled(media.track == nil).help(L(title)).accessibilityLabel(L(title))
    }
}

struct FocusMini: View {
    @Environment(\.notcherAccent) private var accent
    @ObservedObject var focus: FocusService
    /// Space given to the card; nil draws the complete column.
    var size: CGSize? = nil
    private var running: Bool { focus.clock.deadline != nil }
    private func ring(_ side: CGFloat) -> some View {
        ZStack {
            Circle().stroke(.white.opacity(0.06), lineWidth: 3)
            Circle().trim(from: 0, to: min(1, max(0.01, focus.progress))).stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
            Text(clockString(focus.remaining)).font(.system(size: side >= 90 ? 25 : side >= 58 ? 13 : 11, weight: side >= 90 ? .light : .medium, design: .rounded)).monospacedDigit()
        }.frame(width: side, height: side)
    }
    @ViewBuilder var body: some View {
        if let size {
            let width = size.width, height = size.height
            if height >= 190 && width >= 170 { column }
            else if width >= 230 {
                Card(padding: height < 110 ? 8 : 14) {
                    HStack(spacing: 12) {
                        ring(min(62, height - 16))
                        VStack(alignment: .leading, spacing: 9) {
                            if height >= 110 { Eyebrow(text: "Pomodoro") }
                            HStack(spacing: 8) {
                                CapsuleButton(title: running ? "Pause" : "Démarrer", symbol: running ? "pause.fill" : "play.fill", action: focus.toggle)
                                IconButton(symbol: "arrow.counterclockwise", help: "Réinitialiser", size: 28) { focus.reset() }
                            }
                        }
                        Spacer(minLength: 0)
                    }.frame(maxHeight: .infinity)
                }
            } else {
                // Too small for buttons: the dial itself starts and pauses the timer.
                Card(padding: 8) {
                    Button(action: focus.toggle) { ring(max(40, min(96, min(width, height) - 16))).contentShape(Circle()) }
                        .buttonStyle(PressStyle(scale: 0.95)).help("Démarrer ou mettre en pause · clic droit pour réinitialiser")
                        .contextMenu { Button("Réinitialiser", systemImage: "arrow.counterclockwise") { focus.reset() } }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else { column }
    }
    private var column: some View {
        Card {
            VStack(spacing: 12) {
                HStack { Eyebrow(text: "Pomodoro"); Spacer() }
                ring(96)
                HStack(spacing: 10) {
                    CapsuleButton(title: running ? "Pause" : "Démarrer", symbol: running ? "pause.fill" : "play.fill", action: focus.toggle)
                    IconButton(symbol: "arrow.counterclockwise", help: "Réinitialiser") { focus.reset() }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct AudioCard: View {
    @ObservedObject var system: SystemService
    /// Space given to the card; nil draws the complete card.
    var size: CGSize? = nil
    private var muteButton: some View {
        Button { system.setMuted(!system.muted) } label: { Image(systemName: system.muted ? "speaker.slash" : "speaker.wave.2").contentTransition(.symbolEffect(.replace)).frame(width: 28, height: 24).contentShape(Rectangle()) }
            .buttonStyle(PressStyle()).disabled(!system.canMute).help("Couper ou rétablir le son").font(.system(size: 12))
    }
    private var slider: some View { Slider(value: Binding(get: { system.volume }, set: system.changeVolume), in: 0...1).disabled(!system.canSetVolume) }
    private var percent: some View {
        Text("\(Int((system.volume * 100).rounded()))").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).frame(width: 22)
            .contentTransition(.numericText(value: system.volume)).animation(.easeOut(duration: 0.12), value: system.volume)
    }
    private var outputs: some View {
        Menu {
            ForEach(system.outputs) { output in Button(output.name) { system.selectOutput(output) } }
        } label: { Image(systemName: "airplay.audio").font(.system(size: 11)).foregroundStyle(.secondary) }
        .menuStyle(.borderlessButton).frame(width: 30, height: 20).help("Changer de sortie audio")
    }
    var body: some View {
        Group {
            if let size, size.width < 110 {
                Card(padding: 8) { VStack(spacing: 2) { HStack(spacing: 0) { muteButton; if size.width >= 80 { percent } }; slider.controlSize(.mini) }.frame(maxHeight: .infinity) }
            } else if let size, size.height < 105 {
                Card(padding: 10) { HStack(spacing: 8) { muteButton; slider.controlSize(.small); if size.width >= 170 { percent }; if size.width >= 260 { outputs } }.frame(maxHeight: .infinity) }
            } else {
                Card(padding: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Eyebrow(text: "Volume"); Spacer(); outputs }
                        HStack(spacing: 10) { muteButton; slider.controlSize(.small); if (size?.width ?? 300) >= 170 { percent } }
                        if let error = system.audioError { Text(L(error)).font(.system(size: 9)).foregroundStyle(Theme.orange).lineLimit(1).help(L(error)) }
                        else { Text(L(system.outputName)).font(.system(size: 9)).foregroundStyle(Theme.muted).lineLimit(1) }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
            }
        }.onAppear { system.refreshOutputs() }
    }
}

struct NextEventCard: View {
    @Environment(\.notcherAccent) private var accent
    @ObservedObject var calendar: CalendarService
    /// One row of cells: no header, a smaller date.
    var compact = false
    var open: () -> Void = {}
    var body: some View {
        Card(padding: compact ? 8 : 14) {
            VStack(alignment: .leading, spacing: 10) {
                if !compact {
                    Button(action: open) {
                        HStack { Eyebrow(text: "Agenda"); Spacer(); Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundStyle(Theme.muted) }
                            .frame(maxWidth: .infinity).frame(height: 16).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                if let event = calendar.nextEvent {
                    HStack(spacing: 10) {
                        Button(action: open) {
                            HStack(spacing: 10) {
                                VStack(spacing: 1) {
                                    Text(event.start, format: .dateTime.month(.abbreviated)).font(.system(size: 8, weight: .medium)).textCase(.uppercase)
                                    Text(event.start, format: .dateTime.day()).font(.system(size: compact ? 17 : 21, weight: .medium, design: .rounded))
                                }.foregroundStyle(accent).frame(width: 37, height: compact ? 38 : 42).background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(event.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                                    HStack(spacing: 5) {
                                        Circle().fill(Color(nsColor: event.color)).frame(width: 4, height: 4)
                                        Text(event.allDay ? L("Journée") : event.start.formatted(.dateTime.hour().minute())).font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        if !compact, let url = event.meeting { IconButton(symbol: "video", help: "Rejoindre", tint: accent, size: 28) { NSWorkspace.shared.open(url) } }
                    }
                } else if calendar.authorized {
                    Button(action: open) {
                        HStack(spacing: 8) {
                            if compact { Image(systemName: "calendar").font(.system(size: 13)).foregroundStyle(accent) }
                            Text("Aucun événement").font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                        }.frame(maxWidth: .infinity, minHeight: compact ? 30 : 42, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                } else { CapsuleButton(title: "Connecter", symbol: compact ? "calendar" : nil, action: calendar.requestAccess).frame(height: compact ? 30 : 42) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

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
    private var overview: some View {
        GeometryReader { geometry in
            let layout = model.preferences.homeLayout
            let heights = layout.heights(total: geometry.size.height, spacing: 12)
            VStack(spacing: 12) {
                ForEach(0..<2, id: \.self) { row in
                    if !layout.rows[row].isEmpty {
                        let widths = layout.widths(row: row, total: geometry.size.width, spacing: 12)
                        HStack(spacing: 12) {
                            ForEach(Array(layout.rows[row].enumerated()), id: \.element.id) { index, tile in
                                HomeWidgetView(model: model, widget: tile.widget, size: CGSize(width: widths[index], height: heights[row]))
                                    .frame(width: widths[index], height: heights[row])
                            }
                        }
                    }
                }
            }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .animation(.snappy(duration: 0.28), value: layout)
        }
    }
}

struct MediaCard: View {
    @Environment(\.notcherAccent) private var accent
    enum Form: Equatable { case full, column, stack, row(narrow: Bool) }
    @ObservedObject var media: MediaService
    var form = Form.full
    @State private var seeking = false
    @State private var seekPosition: Double = 0
    private var playButton: some View {
        Button { media.command("toggle"); Haptics.play(.generic) } label: {
            Image(systemName: media.track?.playing == true ? "pause.fill" : "play.fill").font(.system(size: 11, weight: .bold)).contentTransition(.symbolEffect(.replace))
                .foregroundStyle(accent.contrastingText).frame(width: 30, height: 30).background(accent, in: Circle()).contentShape(Rectangle())
        }.buttonStyle(PressStyle(scale: 0.9)).disabled(media.track == nil).accessibilityLabel(L(media.track?.playing == true ? "Pause" : "Lecture"))
    }
    private var titles: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(media.track?.title ?? L("Aucune lecture")).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Text(media.track.map { $0.artist.isEmpty ? $0.application : $0.artist } ?? L("Lance un lecteur")).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
    }
    @ViewBuilder var body: some View {
        switch form {
        case .full: full
        case .column:
            Card(padding: 14) {
                VStack(spacing: 9) {
                    artwork(58)
                    titles.frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 0) { transport("backward.fill", "Morceau précédent", "previous"); playButton; transport("forward.fill", "Morceau suivant", "next") }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .stack:
            Card(padding: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    titles
                    HStack(spacing: 0) { transport("backward.fill", "Morceau précédent", "previous"); playButton; transport("forward.fill", "Morceau suivant", "next") }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        case .row(let narrow):
            Card(padding: 14) {
                HStack(spacing: 12) {
                    artwork(narrow ? 42 : 64)
                    titles.frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 2) {
                        if !narrow { transport("backward.fill", "Morceau précédent", "previous") }
                        playButton
                        transport("forward.fill", "Morceau suivant", "next")
                    }
                }.frame(maxHeight: .infinity)
            }
        }
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
                VStack(spacing: 8) {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        HStack(spacing: 8) {
                            Text(clockString(seeking ? seekPosition : media.elapsed))
                            Slider(value: Binding(get: { seeking ? seekPosition : media.elapsed }, set: { seekPosition = $0 }), in: 0...max(1, media.track?.duration ?? 1), onEditingChanged: { editing in
                                if editing { seekPosition = media.elapsed }
                                seeking = editing
                                if !editing { media.command("seek", value: seekPosition) }
                            }).controlSize(.mini).disabled((media.track?.duration ?? 0) <= 0)
                            Text(clockString(media.track?.duration ?? 0))
                        }.font(.system(size: 8, design: .monospaced)).foregroundStyle(Theme.muted)
                    }
                    HStack(spacing: 22) {
                        Spacer()
                        transport("backward.fill", "Morceau précédent", "previous")
                        Button { media.command("toggle"); Haptics.play(.generic) } label: {
                            Image(systemName: media.track?.playing == true ? "pause.fill" : "play.fill").font(.system(size: 12, weight: .bold)).contentTransition(.symbolEffect(.replace)).foregroundStyle(accent.contrastingText).frame(width: 34, height: 34).background(accent, in: Circle()).contentShape(Rectangle())
                        }.buttonStyle(PressStyle(scale: 0.9)).disabled(media.track == nil).accessibilityLabel(L(media.track?.playing == true ? "Pause" : "Lecture"))
                        transport("forward.fill", "Morceau suivant", "next")
                        Spacer()
                    }
                }
            }
        }.overlay(alignment: .bottomLeading) { if let error = media.error { Text(L(error)).font(.system(size: 8)).foregroundStyle(Theme.orange).lineLimit(1).padding(.horizontal, 16).padding(.bottom, 4) } }
    }
    private func artwork(_ side: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13).fill(LinearGradient(colors: [accent.opacity(0.23), accent.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing))
            if let image = media.artwork { Image(nsImage: image).resizable().scaledToFill() }
            else {
                Circle().stroke(accent.opacity(0.16), lineWidth: 1).frame(width: 49, height: 49)
                Circle().stroke(accent.opacity(0.12), lineWidth: 1).frame(width: 35, height: 35)
                Image(systemName: "music.note").font(.system(size: 23, weight: .light)).foregroundStyle(accent)
            }
        }.frame(width: side, height: side).clipShape(RoundedRectangle(cornerRadius: 13))
            .animation(.easeOut(duration: 0.25), value: media.artwork)
    }
    private func transport(_ symbol: String, _ title: String, _ action: String) -> some View {
        Button { media.command(action); Haptics.play(.generic) } label: { Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(.white.opacity(0.8)).frame(width: 34, height: 32).contentShape(Rectangle()) }.buttonStyle(PressStyle(scale: 0.85)).disabled(media.track == nil).help(L(title)).accessibilityLabel(L(title))
    }
}

struct FocusMini: View {
    @Environment(\.notcherAccent) private var accent
    @ObservedObject var focus: FocusService
    var row = false
    /// Too narrow for buttons: the dial itself starts and pauses the timer.
    var dialOnly = false
    @ViewBuilder var body: some View {
        if dialOnly {
            Card(padding: 12) {
                VStack(spacing: 6) {
                    Button(action: focus.toggle) {
                        ZStack {
                            Circle().stroke(.white.opacity(0.06), lineWidth: 3)
                            Circle().trim(from: 0, to: min(1, max(0.01, focus.progress))).stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                            VStack(spacing: 1) {
                                Text(clockString(focus.remaining)).font(.system(size: 13, weight: .medium, design: .rounded)).monospacedDigit()
                                Image(systemName: focus.clock.deadline == nil ? "play.fill" : "pause.fill").font(.system(size: 7)).foregroundStyle(accent).contentTransition(.symbolEffect(.replace))
                            }
                        }.frame(maxWidth: 84, maxHeight: 84).aspectRatio(1, contentMode: .fit).contentShape(Circle())
                    }.buttonStyle(PressStyle(scale: 0.95)).help("Démarrer ou mettre en pause · clic droit pour réinitialiser")
                        .contextMenu { Button("Réinitialiser", systemImage: "arrow.counterclockwise") { focus.reset() } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if row {
            Card(padding: 14) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().stroke(.white.opacity(0.06), lineWidth: 3)
                        Circle().trim(from: 0, to: min(1, max(0.01, focus.progress))).stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                        Text(clockString(focus.remaining)).font(.system(size: 13, weight: .medium, design: .rounded)).monospacedDigit()
                    }.frame(width: 62, height: 62)
                    VStack(alignment: .leading, spacing: 9) {
                        Eyebrow(text: "Pomodoro")
                        HStack(spacing: 8) {
                            CapsuleButton(title: focus.clock.deadline == nil ? "Démarrer" : "Pause", symbol: focus.clock.deadline == nil ? "play.fill" : "pause.fill", action: focus.toggle)
                            IconButton(symbol: "arrow.counterclockwise", help: "Réinitialiser", size: 28) { focus.reset() }
                        }
                    }
                    Spacer(minLength: 0)
                }.frame(maxHeight: .infinity)
            }
        } else { column }
    }
    private var column: some View {
        Card {
            VStack(spacing: 12) {
                HStack { Eyebrow(text: "Pomodoro"); Spacer() }
                ZStack {
                    Circle().stroke(.white.opacity(0.06), lineWidth: 3)
                    Circle().trim(from: 0, to: min(1, max(0.01, focus.progress))).stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                    VStack(spacing: 3) {
                        Text(clockString(focus.remaining)).font(.system(size: 25, weight: .light, design: .rounded)).monospacedDigit()
                    }
                }.frame(width: 96, height: 96)
                HStack(spacing: 10) {
                    CapsuleButton(title: focus.clock.deadline == nil ? "Démarrer" : "Pause", symbol: focus.clock.deadline == nil ? "play.fill" : "pause.fill", action: focus.toggle)
                    IconButton(symbol: "arrow.counterclockwise", help: "Réinitialiser") { focus.reset() }
                }
            }
        }
    }
}

struct AudioCard: View {
    @ObservedObject var system: SystemService
    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Eyebrow(text: "Volume")
                    Spacer()
                    Menu {
                        ForEach(system.outputs) { output in Button(output.name) { system.selectOutput(output) } }
                    } label: { Image(systemName: "airplay.audio").font(.system(size: 11)).foregroundStyle(.secondary) }
                    .menuStyle(.borderlessButton).frame(width: 30, height: 20).help("Changer de sortie audio")
                }
                HStack(spacing: 10) {
                    Button { system.setMuted(!system.muted) } label: { Image(systemName: system.muted ? "speaker.slash" : "speaker.wave.2").contentTransition(.symbolEffect(.replace)).frame(width: 28, height: 24).contentShape(Rectangle()) }.buttonStyle(PressStyle()).disabled(!system.canMute).help("Couper ou rétablir le son")
                    Slider(value: Binding(get: { system.volume }, set: system.changeVolume), in: 0...1).controlSize(.small).disabled(!system.canSetVolume)
                    Text("\(Int((system.volume * 100).rounded()))").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).frame(width: 22)
                        .contentTransition(.numericText(value: system.volume)).animation(.easeOut(duration: 0.12), value: system.volume)
                }.font(.system(size: 12))
                if let error = system.audioError { Text(L(error)).font(.system(size: 9)).foregroundStyle(Theme.orange).lineLimit(1).help(L(error)) }
                else { Text(L(system.outputName)).font(.system(size: 9)).foregroundStyle(Theme.muted).lineLimit(1) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }.onAppear { system.refreshOutputs() }
    }
}

struct NextEventCard: View {
    @Environment(\.notcherAccent) private var accent
    @ObservedObject var calendar: CalendarService
    var open: () -> Void = {}
    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Button(action: open) {
                    HStack { Eyebrow(text: "Agenda"); Spacer(); Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundStyle(Theme.muted) }
                        .frame(maxWidth: .infinity).frame(height: 16).contentShape(Rectangle())
                }.buttonStyle(.plain)
                if let event = calendar.nextEvent {
                    HStack(spacing: 10) {
                        Button(action: open) {
                            HStack(spacing: 10) {
                                VStack(spacing: 1) {
                                    Text(event.start, format: .dateTime.month(.abbreviated)).font(.system(size: 8, weight: .medium)).textCase(.uppercase)
                                    Text(event.start, format: .dateTime.day()).font(.system(size: 21, weight: .medium, design: .rounded))
                                }.foregroundStyle(accent).frame(width: 37, height: 42).background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(event.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                                    HStack(spacing: 5) {
                                        Circle().fill(Color(nsColor: event.color)).frame(width: 4, height: 4)
                                        Text(event.allDay ? L("Journée") : event.start.formatted(.dateTime.hour().minute())).font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        if let url = event.meeting { IconButton(symbol: "video", help: "Rejoindre", tint: accent, size: 28) { NSWorkspace.shared.open(url) } }
                    }
                } else if calendar.authorized {
                    Button(action: open) { Text("Aucun événement").font(.system(size: 11)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, minHeight: 42, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain)
                } else { CapsuleButton(title: "Connecter", action: calendar.requestAccess).frame(height: 42) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

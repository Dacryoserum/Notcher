import SwiftUI
import NotcherCore
import UniformTypeIdentifiers

struct NotchView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: AppModel
    var followsWindow = false
    @Namespace private var tabMarker
    var body: some View {
        // In the notch window the controller animates `shapeSize`; the development preview has no controller.
        let size = followsWindow ? model.shapeSize : model.targetSize
        let shown = model.presentationExpanded
        let shift = followsWindow ? model.shapeShift : model.targetShift
        VStack(spacing: 0) {
            NotchHeader(model: model, width: size.width, shift: shift).frame(width: size.width, height: model.notchHeight)
            VStack(spacing: 14) {
                navigation.frame(height: 38)
                // Clicks stop at the edges of the page: whatever a page draws past them can never cover the navigation.
                page.frame(height: model.pageHeight).contentShape(Rectangle())
            }
            .padding(.horizontal, 32).padding(.top, 12).padding(.bottom, 20)
            .frame(width: model.expandedWidth)
            .opacity(shown ? 1 : 0)
            // The content fades on its own short curve: late on the way in, immediately on the way out.
            .animation(shown ? .easeOut(duration: 0.22).delay(0.05) : .easeOut(duration: 0.09), value: shown)
            .scaleEffect(shown || reduceMotion ? 1 : 0.94, anchor: .top)
            .allowsHitTesting(model.expanded)
            .accessibilityHidden(!model.expanded)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(NotchShape().fill(.black))
        .overlay(NotchShape(outline: true).stroke(model.dragging ? model.preferences.accentColor.opacity(0.8) : Color.white.opacity(shown ? 0.07 : model.hovering ? 0.22 : 0), lineWidth: 1))
        .overlay(alignment: .top) {
            // Under the closed notch: the extra line of an activity (each battery of a pair of earbuds).
            if !shown, let details = model.activity?.details, !details.isEmpty {
                HStack(spacing: 14) { ForEach(details, id: \.self) { Text($0) } }
                    .font(.system(size: 10, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                    .frame(height: AppModel.detailHeight).padding(.top, model.notchHeight - 3).transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            // Under the closed notch: Claude Code's question, answered without opening anything.
            if !shown, !model.expanded, let pending = model.permission {
                PermissionCard(pending: pending, waiting: model.agents.permissionRequests.count - 1) { model.agents.answer(pending.id, $0) }
                    .frame(width: AppModel.permissionCard.width, height: AppModel.permissionCard.height)
                    .padding(.top, model.notchHeight).transition(.opacity)
            }
        }
        .clipShape(NotchShape())
        .overlay(alignment: .bottom) {
            if model.expanded, shown, let pending = model.permission {
                PermissionCard(pending: pending, waiting: model.agents.permissionRequests.count - 1) { model.agents.answer(pending.id, $0) }
                    .frame(width: AppModel.permissionCard.width, height: AppModel.permissionCard.height)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.border))
                    .shadow(color: .black.opacity(0.5), radius: 14, y: 4)
                    .padding(.bottom, 14).transition(.opacity.combined(with: .offset(y: 8)))
            } else if model.expanded, let toast = model.toast {
                HStack(spacing: 10) {
                    Text(L(toast)).font(.system(size: 10)).lineLimit(2).multilineTextAlignment(.center)
                    if let action = model.toastAction {
                        Button { action.run() } label: {
                            Text(L(action.title)).font(.system(size: 10, weight: .semibold)).foregroundStyle(model.preferences.accentColor)
                                .padding(.horizontal, 4).frame(height: 18).contentShape(Rectangle())
                        }.buttonStyle(PressStyle(scale: 0.92)).help(L("%@ · ⌘Z", L(action.title)))
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Theme.raised, in: Capsule()).padding(.bottom, 8).padding(.horizontal, 40)
                .allowsHitTesting(model.toastAction != nil)
                .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.toast)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.permission)
        .offset(x: shift)
        .frame(maxWidth: followsWindow ? .infinity : nil, maxHeight: followsWindow ? .infinity : nil, alignment: .top)
        .foregroundStyle(.white)
        .environment(\.notcherAccent, model.preferences.accentColor)
        .environment(\.notcherPanelActive, model.expanded)
        .tint(model.preferences.accentColor)
        .onDrop(of: [UTType.fileURL, UTType.plainText], isTargeted: $model.dragging) { providers in
            model.expand(tab: .files)
            let accepted = model.shelf.accept(providers)
            if accepted { Haptics.play(.levelChange) }
            return accepted
        }
        .onChange(of: model.dragging) { _, value in if value { model.expand(tab: .files) } }
    }
    private var navigation: some View {
        HStack(spacing: 5) {
            ForEach(model.visibleTabs) { tab in
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) { model.select(tab) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.symbol).font(.system(size: 11))
                        if model.preferences.navigationStyle == .labels { Text(model.preferences.title(for: tab)).font(.system(size: 11, weight: .medium)).lineLimit(1) }
                        if tab == .files { ShelfCount(shelf: model.shelf) }
                    }.padding(.horizontal, 8).frame(maxWidth: .infinity).frame(height: 38)
                        .foregroundStyle(model.tab == tab ? model.preferences.accentColor : Color.white.opacity(0.55))
                        .background { if model.tab == tab { Capsule().fill(model.preferences.accentColor.opacity(0.10)).matchedGeometryEffect(id: "tab", in: tabMarker) } }
                        .contentShape(Rectangle())
                }.buttonStyle(PressStyle(scale: 0.97)).help(model.preferences.title(for: tab) + " · ⌘\((model.visibleTabs.firstIndex(of: tab) ?? 0) + 1)").accessibilityLabel(model.preferences.title(for: tab)).accessibilityAddTraits(model.tab == tab ? .isSelected : [])
            }
            Spacer(minLength: 2)
            UpdateButton(updates: model.updates) { model.openSettings?() }
            IconButton(symbol: model.pinned ? "pin.fill" : "pin", help: "Garder le panneau ouvert", tint: model.pinned ? model.preferences.accentColor : .secondary) { model.pinned.toggle(); Haptics.play(.levelChange) }
            IconButton(symbol: "gearshape", help: "Réglages") { model.openSettings?() }
            IconButton(symbol: "chevron.up", help: "Replier · Échap") { model.collapse() }
        }.animation(reduceMotion ? nil : .snappy(duration: 0.22), value: model.tab)
    }
    @ViewBuilder private var page: some View {
        switch model.tab {
        case .home: HomeView(model: model)
        case .files: ShelfView(model: model, shelf: model.shelf)
        case .notes: NotesView(model: model, notes: model.notes)
        case .agents: AgentsView(model: model, agents: model.agents)
        case .tools: ToolsView(model: model)
        }
    }
}

/// An agent asks before using a tool: what it wants to do, and the ways to answer.
struct PermissionCard: View {
    @Environment(\.notcherAccent) private var accent
    let pending: PendingPermission
    /// Other questions queued behind this one.
    let waiting: Int
    var answer: (ClaudePermissionAnswer) -> Void
    var body: some View {
        let request = pending.request
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                mark(request.agent)
                Text(L("%@ veut utiliser %@", request.agent == .codex ? "Codex" : "Claude", request.toolTitle)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if let project = request.project { Text(project).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1).layoutPriority(-1) }
                Spacer(minLength: 4)
                if waiting > 0 {
                    Text("+\(waiting)").font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).frame(height: 18).background(.white.opacity(0.08), in: Capsule())
                }
                IconButton(symbol: "terminal", help: "Répondre dans le terminal", size: 24) { answer(.pass) }
            }.frame(height: 24)
            Text(request.summary.isEmpty ? (request.note ?? "") : request.summary)
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.78)).lineLimit(2).truncationMode(.middle)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .topLeading)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
                .help(request.note ?? request.summary)
            HStack(spacing: 8) {
                DecisionButton(title: "Refuser") { answer(.deny); Haptics.play(.alignment) }
                DecisionButton(title: "Autoriser", primary: true) { answer(.allow); Haptics.play(.levelChange) }
            }
        }
        // The shape flares out at the top: its body is narrower than its frame by that much on each side.
        .padding(.horizontal, 28).padding(.top, 2).padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
    }
    @ViewBuilder private func mark(_ agent: ClaudePermissionRequest.Agent) -> some View {
        if agent == .claude, let icon = ClaudeMark.icon { Image(nsImage: icon).resizable().interpolation(.high).scaledToFit().frame(width: 18, height: 18) }
        else {
            Image(systemName: agent == .codex ? "chevron.left.forwardslash.chevron.right" : "asterisk").font(.system(size: 10, weight: .bold))
                .foregroundStyle(agent == .codex ? accent : Theme.orange).frame(width: 18, height: 18)
                .background((agent == .codex ? accent : Theme.orange).opacity(0.14), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }
}
/// The two answers share the width of the card, like the buttons of a macOS alert.
private struct DecisionButton: View {
    @Environment(\.notcherAccent) private var accent
    let title: String
    var primary = false
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Text(L(title)).font(.system(size: 12, weight: primary ? .semibold : .medium))
                .foregroundStyle(primary ? accent.contrastingText : Color.white.opacity(0.9))
                .frame(maxWidth: .infinity).frame(height: 30)
                .background(primary ? accent.opacity(hovering ? 0.86 : 1) : Color.white.opacity(hovering ? 0.16 : 0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(Rectangle())
        }.buttonStyle(PressStyle(scale: 0.98)).onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// A green dot in the navigation while a newer version waits; it opens the settings, where it installs.
private struct UpdateButton: View {
    @ObservedObject var updates: UpdateService
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        if let update = updates.available {
            Button(action: action) {
                Circle().fill(Theme.green).frame(width: 9, height: 9)
                    .frame(width: 32, height: 32)
                    .background(Theme.green.opacity(hovering ? 0.26 : 0.16), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle()).onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .help(L("Mise à jour disponible : Notcher %@", update.version)).accessibilityLabel(L("Mise à jour disponible : Notcher %@", update.version))
            .transition(.opacity)
        }
    }
}

private struct ShelfCount: View {
    @ObservedObject var shelf: ShelfService
    var body: some View { if !shelf.items.isEmpty { Text("\(shelf.items.count)").font(.system(size: 8, weight: .bold)).padding(.horizontal, 4).padding(.vertical, 1).background(.white.opacity(0.1), in: Capsule()) } }
}

struct NotchHeader: View {
    @Environment(\.notcherAccent) private var accent
    @ObservedObject var model: AppModel
    let width: CGFloat
    /// Half of what the right wing has over the left one.
    var shift: CGFloat = 0
    /// The shape flares out by this much at each end; nothing can be drawn in the flare.
    static let ear: CGFloat = 16
    var body: some View {
        let wing = max(0, (width - 2 * shift - model.notchWidth) / 2), rightWing = wing + 2 * shift
        let idle = model.preferences.compactStyle == .info || model.presentationExpanded
        // Music alone: narrow wings, the cover and the bars each centred in theirs.
        let slim = !model.presentationExpanded && model.compactPlaybackVisible
        return HStack(spacing: 0) {
                HStack(spacing: 7) {
                    if let activity = model.activity {
                        if let artwork = activity.artwork {
                            Image(nsImage: artwork).resizable().interpolation(.high).scaledToFit().frame(width: min(26, model.notchHeight - 6), height: min(26, model.notchHeight - 6))
                                .modifier(PopIn(active: activity.pictureOnly))
                        } else { Image(systemName: activity.symbol).foregroundStyle(activity.color ?? accent).contentTransition(.symbolEffect(.replace)) }
                        if !model.presentationExpanded && !activity.pictureOnly { Text(L(activity.title)).font(.system(size: 10, weight: .medium)).lineLimit(1) }
                    } else if let ambient = model.ambient, !model.presentationExpanded {
                        AmbientPicture(ambient: ambient, side: min(24, model.notchHeight - 6))
                    } else { CompactMedia(media: model.media, height: model.notchHeight, idle: idle) }
                }
                .frame(maxWidth: .infinity, alignment: model.presentationExpanded ? .leading : .center)
                .padding(.leading, model.presentationExpanded ? 34 : 16)
                .padding(.trailing, model.presentationExpanded ? 10 : slim ? 0 : 16)
                .frame(width: wing)
                Color.clear.frame(width: model.notchWidth, height: 1)
                HStack(spacing: 8) {
                    if let activity = model.activity, let value = activity.value {
                        ProgressView(value: min(1, max(0, value))).tint(activity.color ?? accent).frame(width: 44)
                            .animation(.easeOut(duration: 0.1), value: value)
                        Text("\(Int((value * 100).rounded()))").font(.system(size: 10, design: .monospaced)).contentTransition(.numericText(value: value))
                            .animation(.easeOut(duration: 0.1), value: value)
                    } else if let activity = model.activity, let trailing = activity.trailing {
                        Image(systemName: "battery.75percent").foregroundStyle(activity.color ?? accent)
                        Text(trailing).font(.system(size: 10, weight: .medium, design: .monospaced))
                    } else if let activity = model.activity, let mark = activity.mark {
                        Image(systemName: mark).font(.system(size: 15, weight: .semibold)).foregroundStyle(activity.markColor ?? accent)
                            .modifier(PopIn(active: true, delay: 0.18))
                    } else if let ambient = model.ambient, !model.presentationExpanded, model.activity == nil {
                        AmbientTrailing(ambient: ambient)
                    } else {
                        // Alone in its wing, the indicator takes the same room as the cover opposite and sits in its middle.
                        CompactStatus(media: model.media, focus: model.focus, idle: idle, hovered: model.playbackHover && slim,
                                      barsWidth: slim ? max(24, wing - Self.ear) : 24, volume: slim && shift > 0 ? model.musicVolume : nil)
                    }
                }
                .frame(maxWidth: .infinity, alignment: model.presentationExpanded ? .trailing : .leading)
                .padding(.leading, slim ? 0 : 10).padding(.trailing, model.presentationExpanded ? 34 : slim ? Self.ear : 24)
                .frame(width: rightWing)
        }.font(.system(size: 12))
        .frame(maxHeight: .infinity).clipped()
        .contentShape(Rectangle())
    }
}
/// Springs a picture into place when it appears, so an event reads as an arrival rather than a swap.
private struct PopIn: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let active: Bool
    var delay: Double = 0
    @State private var shown = false
    func body(content: Content) -> some View {
        let settled = shown || !active
        content.scaleEffect(settled || reduceMotion ? 1 : 0.3).opacity(settled ? 1 : 0)
            .onAppear { withAnimation(reduceMotion ? nil : .spring(duration: 0.5, bounce: 0.5).delay(delay)) { shown = true } }
    }
}
/// Left wing of a lasting state: its picture, alive while the state is.
private struct AmbientPicture: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.notcherAccent) private var accent
    let ambient: NotchAmbient
    let side: CGFloat
    @State private var beat = false
    var body: some View {
        Group {
            if let artwork = ambient.artwork { Image(nsImage: artwork).resizable().interpolation(.high).scaledToFit().frame(width: side, height: side) }
            else { Image(systemName: ambient.symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(ambient.color ?? accent) }
        }
        .scaleEffect(beat && ambient.motion == .breathing ? 0.84 : 1)
        .opacity(beat && ambient.motion == .pulsing ? 0.4 : 1)
        .modifier(PopIn(active: true))
        .onAppear { animate() }
        .onChange(of: ambient.motion) { _, _ in animate() }
    }
    private func animate() {
        beat = false
        guard ambient.motion != .none, !reduceMotion else { return }
        withAnimation(.easeInOut(duration: ambient.motion == .pulsing ? 0.6 : 1.1).repeatForever(autoreverses: true)) { beat = true }
    }
}
/// Right wing of a lasting state: a figure when there is one, a moving symbol otherwise.
private struct AmbientTrailing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.notcherAccent) private var accent
    let ambient: NotchAmbient
    var body: some View {
        if let trailing = ambient.trailing {
            Text(trailing).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
        } else if let mark = ambient.mark {
            Image(systemName: mark).font(.system(size: 12, weight: .semibold)).foregroundStyle(ambient.color ?? accent)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion && ambient.motion == .breathing)
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion && ambient.motion == .pulsing)
        }
    }
}
private struct CompactMedia: View {
    @Environment(\.notcherAccent) private var accent
    @ObservedObject var media: MediaService
    let height: CGFloat
    let idle: Bool
    var body: some View {
        if let track = media.compactTrack {
            let side = min(22, max(16, height - 8))
            Group {
                if let artwork = media.artwork { Image(nsImage: artwork).resizable().scaledToFill().allowsHitTesting(false) }
                else { Image(systemName: "music.note").foregroundStyle(accent).frame(maxWidth: .infinity, maxHeight: .infinity).background(accent.opacity(0.12)) }
            }.frame(width: side, height: side).clipShape(RoundedRectangle(cornerRadius: 5))
                .animation(.easeOut(duration: 0.25), value: media.artwork)
                .help(track.title + " · " + track.artist).accessibilityLabel(track.title + " · " + track.artist)
        } else if idle {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(context.date, format: .dateTime.day().month(.abbreviated)).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}
private struct CompactStatus: View {
    @Environment(\.notcherAccent) private var accent
    @ObservedObject var media: MediaService
    @ObservedObject var focus: FocusService
    let idle: Bool
    let hovered: Bool
    var barsWidth: CGFloat = 24
    var volume: VolumeReadout? = nil
    var body: some View {
        if focus.clock.deadline != nil {
            Image(systemName: "timer").foregroundStyle(accent)
            Text(clockString(focus.remaining)).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(accent)
        } else if let track = media.compactTrack {
            // Under the pointer the bars step back, blurred but still moving, behind a play/pause button.
            ZStack {
                PlaybackIndicator(playing: track.playing).foregroundStyle(media.tint ?? accent)
                    .blur(radius: hovered ? 1.8 : 0).opacity(hovered ? 0.45 : 1)
                if hovered {
                    Image(systemName: track.playing ? "pause.fill" : "play.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace)).transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
            }
            .frame(width: barsWidth, height: 18)
            .animation(.easeOut(duration: 0.16), value: hovered)
            .animation(.easeOut(duration: 0.3), value: media.tint)
            if let volume {
                // The volume moved while music plays: its level, small, in the part of the wing that just grew.
                Group {
                    if volume.muted { Image(systemName: "speaker.slash.fill").font(.system(size: 9)) }
                    else { Text("\(Int((volume.level * 100).rounded()))").font(.system(size: 10, weight: .medium, design: .monospaced)).contentTransition(.numericText(value: volume.level)) }
                }.foregroundStyle(.white.opacity(0.75)).frame(width: 18, alignment: .trailing)
                Capsule().fill(.white.opacity(0.14)).frame(width: 34, height: 3)
                    .overlay(alignment: .leading) { Capsule().fill(media.tint ?? accent).frame(width: 34 * min(1, max(0, volume.level)), height: 3) }
                    .animation(.easeOut(duration: 0.1), value: volume.level)
                    .accessibilityLabel(L("Volume")).accessibilityValue("\(Int((volume.level * 100).rounded())) %")
            }
        } else if idle {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(context.date, format: .dateTime.hour().minute()).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
    }
}

/// A quiet playback indicator, not a measurement of the audio signal.
struct PlaybackIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let playing: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !playing || reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4) { index in
                    Capsule().frame(width: 2, height: playing ? (reduceMotion ? 10 : 4 + 11 * (0.5 + 0.5 * sin(time * 4 + Double(index) * 1.7))) : 3)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.accessibilityLabel(L(playing ? "Lecture en cours" : "En pause"))
    }
}

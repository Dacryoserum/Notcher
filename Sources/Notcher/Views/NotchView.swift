import SwiftUI
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
        VStack(spacing: 0) {
            NotchHeader(model: model, width: size.width).frame(width: size.width, height: model.notchHeight)
            VStack(spacing: 14) {
                navigation.frame(height: 38)
                page.frame(height: model.pageHeight)
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
        .clipShape(NotchShape())
        .overlay(alignment: .bottom) {
            if model.expanded, let toast = model.toast {
                Text(toast).font(.system(size: 10)).lineLimit(2).multilineTextAlignment(.center).padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Theme.raised, in: Capsule()).padding(.bottom, 8).padding(.horizontal, 40).allowsHitTesting(false)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.toast)
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

private struct ShelfCount: View {
    @ObservedObject var shelf: ShelfService
    var body: some View { if !shelf.items.isEmpty { Text("\(shelf.items.count)").font(.system(size: 8, weight: .bold)).padding(.horizontal, 4).padding(.vertical, 1).background(.white.opacity(0.1), in: Capsule()) } }
}

struct NotchHeader: View {
    @Environment(\.notcherAccent) private var accent
    @ObservedObject var model: AppModel
    let width: CGFloat
    var body: some View {
        let wing = max(0, (width - model.notchWidth) / 2)
        let idle = model.preferences.compactStyle == .info || model.presentationExpanded
        return HStack(spacing: 0) {
                HStack(spacing: 7) {
                    if let activity = model.activity {
                        Image(systemName: activity.symbol).foregroundStyle(activity.color ?? accent).contentTransition(.symbolEffect(.replace))
                        if !model.presentationExpanded { Text(activity.title).font(.system(size: 10, weight: .medium)).lineLimit(1) }
                    } else { CompactMedia(media: model.media, height: model.notchHeight, idle: idle) }
                }
                .frame(maxWidth: .infinity, alignment: model.presentationExpanded ? .leading : .center)
                .padding(.leading, model.presentationExpanded ? 34 : 16)
                .padding(.trailing, model.presentationExpanded ? 10 : 16)
                .frame(width: wing)
                Color.clear.frame(width: model.notchWidth, height: 1)
                HStack(spacing: 8) {
                    if let activity = model.activity, let value = activity.value {
                        ProgressView(value: min(1, max(0, value))).tint(activity.color ?? accent).frame(width: 44)
                            .animation(.easeOut(duration: 0.1), value: value)
                        Text("\(Int((value * 100).rounded()))").font(.system(size: 10, design: .monospaced)).contentTransition(.numericText(value: value))
                            .animation(.easeOut(duration: 0.1), value: value)
                    } else { CompactStatus(media: model.media, focus: model.focus, idle: idle) }
                }
                .frame(maxWidth: .infinity, alignment: model.presentationExpanded ? .trailing : .leading)
                .padding(.leading, 10).padding(.trailing, model.presentationExpanded ? 34 : 24)
                .frame(width: wing)
        }.font(.system(size: 12))
        .frame(maxHeight: .infinity).clipped()
        .contentShape(Rectangle())
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
                if let artwork = media.artwork { Image(nsImage: artwork).resizable().scaledToFill() }
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
    var body: some View {
        if focus.clock.deadline != nil {
            Image(systemName: "timer").foregroundStyle(accent)
            Text(clockString(focus.remaining)).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(accent)
        } else if let track = media.compactTrack {
            PlaybackIndicator(playing: track.playing).frame(width: 18, height: 16).foregroundStyle(accent)
            TimelineView(.periodic(from: .now, by: track.playing ? 1 : 60)) { _ in
                Text(clockString(media.elapsed)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
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
        }.accessibilityLabel(playing ? "Lecture en cours" : "En pause")
    }
}

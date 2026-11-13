import SwiftUI
import NotcherCore

/// Draws one widget of the overview in the form that suits the space its tile was given.
struct HomeWidgetView: View {
    @ObservedObject var model: AppModel
    let widget: HomeWidget
    let size: CGSize
    private var short: Bool { size.height < 130 }
    private var tall: Bool { size.height >= 190 }
    private var narrow: Bool { size.width < 230 }

    @ViewBuilder var body: some View {
        switch widget {
        case .media:
            MediaCard(media: model.media, form: size.width >= 360 && tall ? .full : narrow && size.height >= 180 ? .column : size.width < 215 ? .stack : .row(narrow: size.width < 300))
        case .focus:
            FocusMini(focus: model.focus, row: !tall, dialOnly: size.width < (tall ? 170 : 225))
        case .volume: AudioCard(system: model.system)
        case .agenda:
            if tall { AgendaWidget(calendar: model.calendar, limit: size.height >= 250 ? 5 : 3, open: openCalendar) }
            else { NextEventCard(calendar: model.calendar, open: openCalendar) }
        case .note: NoteWidget(notes: model.notes) { model.tab = .notes }
        case .clipboard: ClipboardWidget(model: model, clipboard: model.clipboard, limit: short ? 1 : tall ? (size.height >= 250 ? 6 : 4) : 2)
        case .files: FilesWidget(model: model, shelf: model.shelf, columns: max(1, Int((size.width - 28) / 58)), rows: short ? 1 : tall ? 2 : 1)
        case .battery: BatteryWidget(system: model.system, compact: short || narrow)
        case .agents: AgentsWidget(agents: model.agents, compact: short) { model.tab = .agents }
        case .clock: ClockWidget(large: !short && !narrow, narrow: narrow)
        }
    }
    private func openCalendar() { model.toolTab = .calendar; model.tab = .tools }
}

/// Title of a widget, with the way to its full view when it has one.
private struct WidgetHeader: View {
    let title: String
    var detail: String? = nil
    var open: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 6) {
            Eyebrow(text: title).lineLimit(1)
            if let detail { Text(detail).font(.system(size: 9)).foregroundStyle(Theme.muted).lineLimit(1) }
            Spacer(minLength: 4)
            if let open {
                Button(action: open) {
                    Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundStyle(Theme.muted).frame(width: 18, height: 16).contentShape(Rectangle())
                }.buttonStyle(PressStyle()).help("Ouvrir en grand").accessibilityLabel(L("Ouvrir %@ en grand", L(title)))
            }
        }.frame(height: 16)
    }
}

private struct AgendaWidget: View {
    @Environment(\.notcherAccent) private var accent
    @ObservedObject var calendar: CalendarService
    let limit: Int
    var open: () -> Void
    private var upcoming: [CalendarItem] { Array(calendar.events.filter { $0.end > Date() }.prefix(limit)) }
    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                WidgetHeader(title: "Agenda", open: open)
                if !calendar.authorized {
                    CapsuleButton(title: "Connecter", action: calendar.requestAccess)
                } else if upcoming.isEmpty {
                    Text("Aucun événement à venir").font(.system(size: 11)).foregroundStyle(Theme.muted)
                } else {
                    ForEach(upcoming) { event in
                        Button(action: open) {
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 1.5).fill(Color(nsColor: event.color)).frame(width: 3, height: 26)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                                    Text(when(event)).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if let url = event.meeting { IconButton(symbol: "video", help: "Rejoindre", tint: accent, size: 24) { NSWorkspace.shared.open(url) } }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
    private func when(_ event: CalendarItem) -> String {
        let day = Calendar.current.isDateInToday(event.start) ? L("Aujourd’hui") : Calendar.current.isDateInTomorrow(event.start) ? L("Demain") : event.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        return event.allDay ? day + L(" · journée") : day + " · " + event.start.formatted(.dateTime.hour().minute())
    }
}

/// The selected sheet, editable in place. The tab keeps every sheet and the transformations.
private struct NoteWidget: View {
    @ObservedObject var notes: NotesService
    var open: () -> Void
    var body: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 6) {
                WidgetHeader(title: notes.selected.map { $0.title.isEmpty ? "Texte" : $0.title } ?? "Texte", open: open)
                ZStack(alignment: .topLeading) {
                    if notes.selected?.text.isEmpty != false {
                        Text("Écris ici…").font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.22)).padding(.leading, 5).allowsHitTesting(false)
                    }
                    TextEditor(text: Binding(get: { notes.selected?.text ?? "" }, set: { notes.update(text: $0) }))
                        .font(.system(size: 11, design: .monospaced)).scrollContentBackground(.hidden).scrollIndicators(.never)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct ClipboardWidget: View {
    @Environment(\.notcherAccent) private var accent
    @ObservedObject var model: AppModel
    @ObservedObject var clipboard: ClipboardService
    let limit: Int
    var body: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 7) {
                WidgetHeader(title: "Presse-papiers") { model.toolTab = .clipboard; model.tab = .tools }
                if !model.preferences.clipboardEnabled {
                    CapsuleButton(title: "Activer l’historique", symbol: "power") { model.preferences.clipboardEnabled = true }
                } else if clipboard.items.isEmpty {
                    Text("Ce que tu copies apparaîtra ici").font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(2)
                } else {
                    ForEach(clipboard.items.prefix(limit)) { item in
                        Button { clipboard.copy(item); model.notify("Copié"); Haptics.play(.generic) } label: {
                            HStack(spacing: 6) {
                                Text(item.text.trimmingCharacters(in: .whitespacesAndNewlines)).font(.system(size: 10, design: .monospaced)).lineLimit(1)
                                Spacer(minLength: 0)
                                Image(systemName: "doc.on.doc").font(.system(size: 8)).foregroundStyle(accent)
                            }.padding(.horizontal, 8).frame(height: 24).background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 7)).contentShape(Rectangle())
                        }.buttonStyle(PressStyle(scale: 0.98)).help("Copier à nouveau")
                    }
                }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct FilesWidget: View {
    @Environment(\.notcherAccent) private var accent
    @ObservedObject var model: AppModel
    @ObservedObject var shelf: ShelfService
    let columns: Int
    let rows: Int
    var body: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(title: "Dépôt", detail: shelf.items.isEmpty ? nil : "\(shelf.items.count)") { model.tab = .files }
                if shelf.items.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "tray.and.arrow.down").foregroundStyle(accent)
                        Text("Dépose un fichier sur le notch").lineLimit(2)
                    }.font(.system(size: 10)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(RoundedRectangle(cornerRadius: 9).strokeBorder(accent.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
                } else {
                    let shown = Array(shelf.items.suffix(columns * rows).reversed())
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), alignment: .leading, spacing: 6) {
                        ForEach(shown) { item in
                            let url = shelf.url(for: item)
                            VStack(spacing: 2) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 26, height: 26)
                                Text(item.name).font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }.frame(maxWidth: .infinity).contentShape(Rectangle())
                                .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                                .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                                .help(item.name + L(" · glisser pour exporter, double-clic pour ouvrir"))
                        }
                    }
                    Spacer(minLength: 0)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct BatteryWidget: View {
    @Environment(\.notcherAccent) private var accent
    @ObservedObject var system: SystemService
    let compact: Bool
    private var symbol: String {
        guard let level = system.battery else { return "powerplug" }
        if system.charging { return "battery.100percent.bolt" }
        return level > 87 ? "battery.100percent" : level > 62 ? "battery.75percent" : level > 37 ? "battery.50percent" : level > 12 ? "battery.25percent" : "battery.0percent"
    }
    var body: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Eyebrow(text: "Batterie"); Spacer(minLength: 4)
                    IconButton(symbol: "cup.and.saucer.fill", help: system.awake ? "Laisser le Mac se mettre en veille" : "Garder le Mac éveillé", tint: system.awake ? accent : .secondary, size: 24, action: system.toggleAwake)
                }.frame(height: 20)
                Spacer(minLength: 0)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(system.battery.map { "\($0)" } ?? "—").font(.system(size: compact ? 26 : 38, weight: .light, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText(value: Double(system.battery ?? 0)))
                    if system.battery != nil { Text("%").font(.system(size: 12)).foregroundStyle(.secondary) }
                    Spacer(minLength: 0)
                    Image(systemName: symbol).font(.system(size: compact ? 15 : 20)).foregroundStyle((system.battery ?? 100) <= 12 && !system.charging ? Theme.orange : accent)
                        .contentTransition(.symbolEffect(.replace))
                }
                Text(L(system.battery == nil ? "Sur secteur" : system.charging ? "En charge" : "Sur batterie")).font(.system(size: 9)).foregroundStyle(Theme.muted).lineLimit(1)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .animation(.easeOut(duration: 0.2), value: system.battery)
        }
    }
}

private struct AgentsWidget: View {
    @Environment(\.notcherAccent) private var accent
    @ObservedObject var agents: AgentService
    let compact: Bool
    var open: () -> Void
    var body: some View {
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: compact ? 7 : 11) {
                WidgetHeader(title: "Quotas", open: open)
                if agents.claude == nil && agents.codex == nil {
                    Button(action: open) { Text("Connecte Claude Code ou Codex").font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(2).multilineTextAlignment(.leading) }.buttonStyle(.plain)
                } else {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        VStack(spacing: compact ? 7 : 11) {
                            line("Claude", agents.claude, Theme.orange, at: context.date)
                            line("Codex", agents.codex, accent, at: context.date)
                        }
                    }
                }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
    /// The fullest window that is still current: the one that will run out first.
    @ViewBuilder private func line(_ name: String, _ usage: AgentUsage?, _ color: Color, at now: Date) -> some View {
        if let window = usage?.windows.filter({ !$0.isExpired(at: now) }).max(by: { $0.usedPercent < $1.usedPercent }) {
            let tint = window.usedPercent >= 90 ? Theme.orange : color
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(name).font(.system(size: 10, weight: .medium)).lineLimit(1)
                    Text(window.title).font(.system(size: 9)).foregroundStyle(Theme.muted).lineLimit(1)
                    Spacer(minLength: 2)
                    Text("\(Int(window.usedPercent)) %").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(tint)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.06))
                        Capsule().fill(tint).frame(width: max(0, geo.size.width * window.fraction))
                    }
                }.frame(height: 3)
            }
        }
    }
}

private struct ClockWidget: View {
    @Environment(\.notcherAccent) private var accent
    let large: Bool
    let narrow: Bool
    var body: some View {
        Card(padding: 12) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 3) {
                    Spacer(minLength: 0)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(context.date, format: .dateTime.hour().minute()).font(.system(size: large ? 44 : 28, weight: .light, design: .rounded)).monospacedDigit()
                        if !narrow { Text(context.date, format: .dateTime.second(.twoDigits)).font(.system(size: large ? 15 : 11, design: .rounded)).monospacedDigit().foregroundStyle(accent) }
                    }.lineLimit(1).minimumScaleFactor(0.6)
                    Text(context.date.formatted(narrow ? .dateTime.weekday(.abbreviated).day().month(.abbreviated) : .dateTime.weekday(.wide).day().month(.wide)).capitalized)
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    if large { Text(L("Semaine %lld", Calendar.current.component(.weekOfYear, from: context.date))).font(.system(size: 9)).foregroundStyle(Theme.muted) }
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
    }
}

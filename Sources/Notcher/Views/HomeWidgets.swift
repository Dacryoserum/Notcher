import SwiftUI
import NotcherCore

/// Draws one widget of the overview in the form that suits the space its cells give it.
/// A single cell is roughly 68 × 71 pt; every widget has something useful to show from its minimum size up.
struct HomeWidgetView: View {
    @ObservedObject var model: AppModel
    let widget: HomeWidget
    let size: CGSize
    /// One row of cells high.
    private var flat: Bool { size.height < 110 }

    @ViewBuilder var body: some View {
        switch widget {
        case .media: MediaCard(media: model.media, size: size)
        case .focus: FocusMini(focus: model.focus, size: size)
        case .volume: AudioCard(system: model.system, size: size)
        case .agenda:
            if size.height >= 190 { AgendaWidget(calendar: model.calendar, limit: max(1, Int((size.height - 54) / 36)), open: openCalendar) }
            else { NextEventCard(calendar: model.calendar, compact: flat, open: openCalendar) }
        case .note: NoteWidget(model: model, notes: model.notes, bare: flat)
        case .clipboard: ClipboardWidget(model: model, clipboard: model.clipboard, limit: flat ? 1 : max(1, Int((size.height - 46) / 30)), bare: flat)
        case .files: FilesWidget(model: model, shelf: model.shelf, size: size)
        case .battery: BatteryWidget(system: model.system, size: size)
        case .agents: AgentsWidget(agents: model.agents, flat: flat) { model.tab = .agents }
        case .clock: ClockWidget(size: size)
        case .awake: AwakeWidget(system: model.system, size: size)
        }
    }
    private func openCalendar() { model.toolTab = .calendar; model.tab = .tools }
}

/// Title of a widget, with the way to its full view when it has one.
private struct WidgetHeader<Extra: View>: View {
    let title: String
    var detail: String? = nil
    var open: (() -> Void)? = nil
    @ViewBuilder var extra: Extra
    var body: some View {
        HStack(spacing: 6) {
            Eyebrow(text: title).lineLimit(1)
            if let detail { Text(detail).font(.system(size: 9)).foregroundStyle(Theme.muted).lineLimit(1) }
            Spacer(minLength: 4)
            extra
            if let open {
                Button(action: open) {
                    Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundStyle(Theme.muted).frame(width: 18, height: 16).contentShape(Rectangle())
                }.buttonStyle(PressStyle()).help("Ouvrir en grand").accessibilityLabel(L("Ouvrir %@ en grand", L(title)))
            }
        }.frame(height: 16)
    }
}
extension WidgetHeader where Extra == EmptyView {
    init(title: String, detail: String? = nil, open: (() -> Void)? = nil) { self.init(title: title, detail: detail, open: open) { EmptyView() } }
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
    @Environment(\.notcherAccent) private var accent
    @ObservedObject var model: AppModel
    @ObservedObject var notes: NotesService
    /// One row of cells: the text only.
    let bare: Bool
    var body: some View {
        Card(padding: bare ? 8 : 12) {
            VStack(alignment: .leading, spacing: 6) {
                if !bare {
                    WidgetHeader(title: notes.selected.map { $0.title.isEmpty ? "Texte" : $0.title } ?? "Texte", open: { model.tab = .notes }) {
                        Button { model.sendSelectedNoteToNotes() } label: {
                            Image(systemName: "square.and.arrow.up.on.square").font(.system(size: 9)).foregroundStyle(notes.sending ? accent : Theme.muted).frame(width: 18, height: 16).contentShape(Rectangle())
                        }.buttonStyle(PressStyle()).disabled(notes.sending).help("Envoyer vers Notes").accessibilityLabel("Envoyer vers Notes")
                    }
                }
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
    /// One row of cells: the latest text only.
    let bare: Bool
    var body: some View {
        Card(padding: bare ? 8 : 12) {
            VStack(alignment: .leading, spacing: 7) {
                if !bare { WidgetHeader(title: "Presse-papiers") { model.toolTab = .clipboard; model.tab = .tools } }
                if !model.preferences.clipboardEnabled {
                    CapsuleButton(title: bare ? "Activer" : "Activer l’historique", symbol: "doc.on.clipboard") { model.preferences.clipboardEnabled = true }
                } else if clipboard.items.isEmpty {
                    HStack(spacing: 6) {
                        if bare { Image(systemName: "doc.on.clipboard").foregroundStyle(accent) }
                        Text("Ce que tu copies apparaîtra ici").foregroundStyle(Theme.muted).lineLimit(2)
                    }.font(.system(size: 10))
                } else {
                    ForEach(clipboard.items.prefix(limit)) { item in
                        Button { clipboard.copy(item); model.notify("Copié"); Haptics.play(.generic) } label: {
                            HStack(spacing: 6) {
                                Text(item.text.trimmingCharacters(in: .whitespacesAndNewlines)).font(.system(size: 10, design: .monospaced)).lineLimit(bare ? 2 : 1)
                                Spacer(minLength: 0)
                                Image(systemName: "doc.on.doc").font(.system(size: 8)).foregroundStyle(accent)
                            }.padding(.horizontal, 8).frame(minHeight: 24, maxHeight: bare ? .infinity : 24).background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 7)).contentShape(Rectangle())
                        }.buttonStyle(PressStyle(scale: 0.98)).help("Copier à nouveau")
                    }
                }
                if !bare { Spacer(minLength: 0) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: bare ? .leading : .topLeading)
        }
    }
}

private struct FilesWidget: View {
    @Environment(\.notcherAccent) private var accent
    @ObservedObject var model: AppModel
    @ObservedObject var shelf: ShelfService
    let size: CGSize
    var body: some View {
        if size.width < 110 || (size.height < 110 && size.width < 200) {
            // Too small for file icons: a count, and a way into the shelf.
            Button { model.tab = .files } label: {
                Card(padding: 8) {
                    VStack(spacing: 4) {
                        Image(systemName: shelf.items.isEmpty ? "tray" : "tray.full").font(.system(size: 17)).foregroundStyle(accent)
                        Text("\(shelf.items.count)").font(.system(size: 13, weight: .medium, design: .rounded)).monospacedDigit().contentTransition(.numericText())
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }.contentShape(Rectangle())
            }.buttonStyle(PressStyle(scale: 0.96)).help("Dépôt").accessibilityLabel("Dépôt")
        } else {
            let flat = size.height < 110
            let columns = max(1, Int((size.width - 24) / (flat ? 40 : 58)))
            let rows = flat ? 1 : max(1, Int((size.height - 50) / 52))
            Card(padding: flat ? 8 : 12) {
                VStack(alignment: .leading, spacing: 8) {
                    if !flat { WidgetHeader(title: "Dépôt", detail: shelf.items.isEmpty ? nil : "\(shelf.items.count)") { model.tab = .files } }
                    if shelf.items.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "tray.and.arrow.down").foregroundStyle(accent)
                            Text("Dépose un fichier sur le notch").lineLimit(2)
                        }.font(.system(size: 10)).foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(RoundedRectangle(cornerRadius: 9).strokeBorder(accent.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), alignment: .leading, spacing: 6) {
                            ForEach(Array(shelf.items.suffix(columns * rows).reversed())) { item in
                                let url = shelf.url(for: item)
                                VStack(spacing: 2) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 26, height: 26)
                                    if !flat { Text(item.name).font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                                }.frame(maxWidth: .infinity).contentShape(Rectangle())
                                    .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                                    .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                                    .help(item.name + L(" · glisser pour exporter, double-clic pour ouvrir"))
                            }
                        }.frame(maxHeight: flat ? .infinity : nil)
                        if !flat { Spacer(minLength: 0) }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
}

/// "+15" and "+30": each press adds that many minutes to the awake period, starting one if needed.
struct AwakeSteps: View {
    @Environment(\.notcherAccent) private var accent
    @ObservedObject var system: SystemService
    var body: some View {
        HStack(spacing: 4) {
            ForEach([15, 30], id: \.self) { minutes in
                Button { system.extendAwake(minutes: minutes); Haptics.play(.generic) } label: {
                    Text(verbatim: "+\(minutes)").font(.system(size: 9, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(accent).frame(width: 28, height: 20).background(accent.opacity(0.12), in: Capsule()).contentShape(Rectangle())
                }.buttonStyle(PressStyle(scale: 0.9)).help(L("Garder le Mac éveillé %lld minutes de plus", minutes)).accessibilityLabel(L("Garder le Mac éveillé %lld minutes de plus", minutes))
            }
        }
    }
}
/// Time left of a timed awake period, refreshed every second. Empty when the period is open-ended.
struct AwakeCountdown: View {
    @ObservedObject var system: SystemService
    var size: CGFloat = 10
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            if let left = system.awakeRemaining {
                Text(clockString(left)).font(.system(size: size, weight: .medium, design: .monospaced)).monospacedDigit().lineLimit(1)
            }
        }
    }
}

private struct AwakeWidget: View {
    @Environment(\.notcherAccent) private var accent
    @ObservedObject var system: SystemService
    let size: CGSize
    private var cup: some View {
        Button(action: system.toggleAwake) {
            Image(systemName: "cup.and.saucer.fill").font(.system(size: 14)).foregroundStyle(system.awake ? accent : .secondary)
                .frame(width: 30, height: 30).background(system.awake ? accent.opacity(0.14) : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9)).contentShape(Rectangle())
        }.buttonStyle(PressStyle()).help(L(system.awake ? "Laisser le Mac se mettre en veille" : "Garder le Mac éveillé"))
            .accessibilityLabel(L(system.awake ? "Laisser le Mac se mettre en veille" : "Garder le Mac éveillé"))
    }
    @ViewBuilder private var state: some View {
        if system.awakeUntil != nil { AwakeCountdown(system: system).foregroundStyle(accent) }
        else { Text(L(system.awake ? "Activé" : "Désactivé")).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
    }
    var body: some View {
        Card(padding: 8) {
            if size.width < 110 {
                // A single cell: the cup toggles, a right-click adds time.
                VStack(spacing: 3) { cup; if system.awakeUntil != nil { AwakeCountdown(system: system, size: 9).foregroundStyle(accent) } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contextMenu {
                        Button("+15 min") { system.extendAwake(minutes: 15) }
                        Button("+30 min") { system.extendAwake(minutes: 30) }
                    }
            } else if size.height < 110 {
                HStack(spacing: 8) {
                    cup
                    if size.width >= 190 { state } else if system.awakeUntil != nil { AwakeCountdown(system: system, size: 9).foregroundStyle(accent) }
                    Spacer(minLength: 0)
                    AwakeSteps(system: system)
                }.frame(maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Eyebrow(text: "Éveil"); Spacer(minLength: 0) }
                    HStack(spacing: 8) { cup; state }
                    Spacer(minLength: 0)
                    AwakeSteps(system: system)
                }.padding(4).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
}

private struct BatteryWidget: View {
    @Environment(\.notcherAccent) private var accent
    @ObservedObject var system: SystemService
    let size: CGSize
    private var symbol: String {
        guard let level = system.battery else { return "powerplug" }
        if system.charging { return "battery.100percent.bolt" }
        return level > 87 ? "battery.100percent" : level > 62 ? "battery.75percent" : level > 37 ? "battery.50percent" : level > 12 ? "battery.25percent" : "battery.0percent"
    }
    private var tint: Color { (system.battery ?? 100) <= 12 && !system.charging ? Theme.orange : accent }
    private func level(_ font: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(system.battery.map { "\($0)" } ?? "—").font(.system(size: font, weight: .light, design: .rounded)).monospacedDigit()
                .contentTransition(.numericText(value: Double(system.battery ?? 0)))
            if system.battery != nil { Text(verbatim: "%").font(.system(size: max(8, font * 0.4))).foregroundStyle(.secondary) }
        }.lineLimit(1).minimumScaleFactor(0.7)
    }
    private var status: String { system.battery == nil ? "Sur secteur" : system.charging ? "En charge" : "Sur batterie" }
    var body: some View {
        Card(padding: size.height < 110 || size.width < 110 ? 8 : 12) {
            Group {
                if size.width < 110 {
                    VStack(spacing: 2) { Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(tint).contentTransition(.symbolEffect(.replace)); level(19) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if size.height < 110 {
                    HStack(spacing: 8) {
                        Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(tint).contentTransition(.symbolEffect(.replace))
                        level(24)
                        if size.width >= 215 { Text(L(status)).font(.system(size: 9)).foregroundStyle(Theme.muted).lineLimit(1) }
                        Spacer(minLength: 0)
                    }.frame(maxHeight: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Eyebrow(text: "Batterie"); Spacer(minLength: 4) }.frame(height: 16)
                        Spacer(minLength: 0)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            level(size.width < 200 ? 28 : 38)
                            Spacer(minLength: 0)
                            Image(systemName: symbol).font(.system(size: 19)).foregroundStyle(tint).contentTransition(.symbolEffect(.replace))
                        }
                        Text(L(status)).font(.system(size: 9)).foregroundStyle(Theme.muted).lineLimit(1)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }.animation(.easeOut(duration: 0.2), value: system.battery)
        }
    }
}

private struct AgentsWidget: View {
    @Environment(\.notcherAccent) private var accent
    @ObservedObject var agents: AgentService
    /// One row of cells: the two gauges side by side, no header.
    let flat: Bool
    var open: () -> Void
    var body: some View {
        Card(padding: flat ? 10 : 12) {
            VStack(alignment: .leading, spacing: flat ? 0 : 11) {
                if !flat { WidgetHeader(title: "Quotas", open: open) }
                if agents.claude == nil && agents.codex == nil {
                    Button(action: open) {
                        HStack(spacing: 6) {
                            if flat { Image(systemName: "sparkles").foregroundStyle(accent) }
                            Text("Connecte Claude Code ou Codex").foregroundStyle(Theme.muted).lineLimit(2).multilineTextAlignment(.leading)
                        }.font(.system(size: 10)).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                } else {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        let layout = flat ? AnyLayout(HStackLayout(spacing: 14)) : AnyLayout(VStackLayout(spacing: 11))
                        layout {
                            line("Claude", agents.claude, Theme.orange, at: context.date)
                            line("Codex", agents.codex, accent, at: context.date)
                        }
                    }
                }
                if !flat { Spacer(minLength: 0) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: flat ? .leading : .topLeading)
        }
    }
    /// The fullest window that is still current: the one that will run out first.
    @ViewBuilder private func line(_ name: String, _ usage: AgentUsage?, _ color: Color, at now: Date) -> some View {
        if let window = usage?.windows.filter({ !$0.isExpired(at: now) }).max(by: { $0.usedPercent < $1.usedPercent }) {
            let tint = window.usedPercent >= 90 ? Theme.orange : color
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(verbatim: name).font(.system(size: 10, weight: .medium)).lineLimit(1)
                    if !flat { Text(window.title).font(.system(size: 9)).foregroundStyle(Theme.muted).lineLimit(1) }
                    Spacer(minLength: 2)
                    Text(verbatim: "\(Int(window.usedPercent)) %").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(tint)
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
    let size: CGSize
    var body: some View {
        let slim = size.width < 110, flat = size.height < 110
        let large = !flat && size.width >= 200
        Card(padding: slim || flat ? 8 : 12) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let time = Text(context.date, format: .dateTime.hour().minute()).font(.system(size: large ? 44 : slim ? 19 : 26, weight: .light, design: .rounded)).monospacedDigit()
                let day = Text(context.date.formatted(large ? .dateTime.weekday(.wide).day().month(.wide) : .dateTime.weekday(.abbreviated).day().month(.abbreviated)).capitalized)
                    .font(.system(size: slim ? 8 : 10)).foregroundStyle(.secondary)
                Group {
                    if flat && !slim {
                        HStack(alignment: .firstTextBaseline, spacing: 8) { time; if size.width >= 190 { day }; Spacer(minLength: 0) }
                    } else {
                        VStack(alignment: slim ? .center : .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                time
                                if large { Text(context.date, format: .dateTime.second(.twoDigits)).font(.system(size: 15, design: .rounded)).monospacedDigit().foregroundStyle(accent) }
                            }
                            day
                            if large && size.height >= 190 { Text("Semaine \(Calendar.current.component(.weekOfYear, from: context.date))").font(.system(size: 9)).foregroundStyle(Theme.muted) }
                        }
                    }
                }.lineLimit(1).minimumScaleFactor(0.6).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: slim ? .center : .leading)
            }
        }
    }
}

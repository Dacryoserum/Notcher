import SwiftUI
import NotcherCore

struct CalendarView: View {
    @Environment(\.notcherAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var calendar: CalendarService
    @State private var selected = Calendar.current.startOfDay(for: Date())
    private var grid: AgendaMonth { AgendaMonth(containing: calendar.month) }
    private var days: [CalendarItem] { calendar.events(on: selected) }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            monthGrid.frame(width: 252)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(selected.formatted(.dateTime.weekday(.wide).day().month(.wide)).capitalized)
                        .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    if calendar.loading { ProgressView().controlSize(.mini) }
                    else if !days.isEmpty { Text("\(days.count)").font(.system(size: 10, design: .rounded)).foregroundStyle(Theme.muted) }
                }.frame(height: 28)
                if !calendar.authorized {
                    VStack(spacing: 14) {
                        Spacer()
                        CapsuleButton(title: "Connecter Calendrier", symbol: "calendar.badge.plus", primary: true, action: calendar.requestAccess)
                        ErrorLine(message: calendar.error)
                        Spacer()
                    }.frame(maxWidth: .infinity)
                } else if days.isEmpty {
                    EmptyState(symbol: "calendar", title: calendar.loading ? "" : "Aucun événement")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(days) { event in CalendarEventRow(event: event) }
                        }.padding(.bottom, 2)
                    }.scrollIndicators(.hidden)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }.onAppear { calendar.showMonth(selected) }
    }
    private var monthGrid: some View {
        VStack(spacing: 9) {
            HStack(spacing: 5) {
                Text(calendar.month.formatted(.dateTime.month(.wide).year()).capitalized).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                monthButton("chevron.left", label: L("Mois précédent"), offset: -1)
                monthButton("chevron.right", label: L("Mois suivant"), offset: 1)
            }
            HStack(spacing: 0) {
                ForEach(0..<7) { index in
                    let weekday = (Calendar.current.firstWeekday - 1 + index) % 7
                    Text(Calendar.current.veryShortStandaloneWeekdaySymbols[weekday].uppercased())
                        .font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                ForEach(grid.days, id: \.self) { date in dayButton(date) }
            }
            Button { select(Date()) } label: {
                Text("Aujourd’hui").font(.system(size: 10, weight: .medium)).foregroundStyle(accent)
                    .frame(maxWidth: .infinity).frame(height: 26).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }.padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
    }
    private func monthButton(_ symbol: String, label: String, offset: Int) -> some View {
        Button {
            if let date = Calendar.current.date(byAdding: .month, value: offset, to: grid.month) { select(date) }
        } label: { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).frame(width: 26, height: 26).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(.secondary).help(label).accessibilityLabel(label)
    }
    private func dayButton(_ date: Date) -> some View {
        let chosen = Calendar.current.isDate(date, inSameDayAs: selected)
        let today = Calendar.current.isDateInToday(date)
        let inMonth = Calendar.current.isDate(date, equalTo: calendar.month, toGranularity: .month)
        let events = calendar.events(on: date)
        return Button { select(date) } label: {
            VStack(spacing: 2) {
                Text(date, format: .dateTime.day()).font(.system(size: 11, weight: chosen || today ? .semibold : .regular)).monospacedDigit()
                HStack(spacing: 2) {
                    ForEach(Array(events.prefix(3).enumerated()), id: \.offset) { _, event in
                        Circle().fill(chosen ? accent.contrastingText.opacity(0.6) : Color(nsColor: event.color)).frame(width: 3, height: 3)
                    }
                }.frame(height: 3)
            }.frame(maxWidth: .infinity).frame(height: 24)
                .foregroundStyle(chosen ? accent.contrastingText : today ? accent : Color.white.opacity(inMonth ? 0.85 : 0.27))
                .background(chosen ? accent : today ? accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(date.formatted(date: .complete, time: .omitted) + L(", %lld événements", events.count))
            .accessibilityAddTraits(chosen ? .isSelected : [])
    }
    private func select(_ date: Date) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { selected = Calendar.current.startOfDay(for: date) }
        calendar.showMonth(date)
    }
}

struct CalendarEventRow: View {
    @Environment(\.notcherAccent) private var accent
    let event: CalendarItem
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let ongoing = !event.allDay && event.start <= context.date && event.end > context.date
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: event.color)).frame(width: 3)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Text(event.allDay ? L("Journée") : event.start.formatted(.dateTime.hour().minute()) + " – " + event.end.formatted(.dateTime.hour().minute()))
                        Spacer(minLength: 0)
                        if ongoing { Text("En cours").foregroundStyle(accent) }
                    }.font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                    Text(event.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                    HStack {
                        Text(event.calendarName).font(.system(size: 9)).foregroundStyle(Theme.muted).lineLimit(1)
                        Spacer(minLength: 0)
                        if let url = event.meeting {
                            Button { NSWorkspace.shared.open(url) } label: {
                                Label("Rejoindre", systemImage: "video").font(.system(size: 9, weight: .medium))
                                    .padding(.horizontal, 7).frame(height: 24).foregroundStyle(accent)
                                    .background(accent.opacity(0.1), in: Capsule()).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                    if ongoing {
                        ProgressView(value: context.date.timeIntervalSince(event.start) / max(1, event.end.timeIntervalSince(event.start)))
                            .tint(Color(nsColor: event.color)).scaleEffect(y: 0.65)
                    }
                }
            }.padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 13))
        }
    }
}

import SwiftUI
import NotcherCore

/// The Agents page. The first visit asks which agents are used; with one, its page opens directly; with both,
/// two cards lead to each one's page.
struct AgentsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var agents: AgentService
    @State private var opened: AgentKind?
    var body: some View {
        let chosen = model.preferences.chosenAgents
        Group {
            if chosen.isEmpty {
                AgentPicker(initial: model.preferences.codexEnabled ? [.claude, .codex] : [.claude]) { choose($0) }
            } else if chosen.count == 1 {
                AgentDetail(kind: chosen[0], model: model, agents: agents, stats: model.usageStats, back: nil) { change() }
            } else if let opened {
                AgentDetail(kind: opened, model: model, agents: agents, stats: model.usageStats, back: { withAnimation(.snappy(duration: 0.25)) { self.opened = nil } }) { change() }
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else {
                AgentOverview(model: model, agents: agents, stats: model.usageStats, open: { kind in withAnimation(.snappy(duration: 0.25)) { opened = kind } }) { change() }
                    .transition(.opacity)
            }
        }
    }
    private func choose(_ kinds: Set<AgentKind>) {
        Haptics.play(.levelChange)
        withAnimation(.snappy(duration: 0.25)) {
            model.preferences.agentChoice = kinds.count == 2 ? "both" : kinds.first?.rawValue ?? ""
        }
        if kinds.contains(.codex), !model.preferences.codexEnabled {
            model.preferences.codexEnabled = true
            Task { await agents.refreshCodex() }
        }
    }
    private func change() {
        withAnimation(.snappy(duration: 0.25)) { opened = nil; model.preferences.agentChoice = "" }
    }
}

/// What Claude Code is doing, shared by the page and the overview.
@MainActor func claudeMood(_ agents: AgentService, at now: Date) -> AgentStage.Mood {
    if agents.claudeWaiting > 0 || !agents.permissionRequests.isEmpty { return .waiting }
    if let done = agents.claudeFinishedAt, now.timeIntervalSince(done) < 5, agents.claudeWorking == 0 { return .done }
    if agents.claudeWorking > 0 || !agents.subagents.isEmpty { return .working }
    return .idle
}
@MainActor func claudeStatus(_ agents: AgentService, _ mood: AgentStage.Mood) -> String {
    var parts: [String] = []
    switch mood {
    case .idle: parts.append(L("Au repos"))
    case .done: parts.append(L("Terminé"))
    case .waiting: parts.append(L(agents.claudeWaiting > 1 ? "%lld en attente" : "%lld en attente de toi", max(1, agents.claudeWaiting)))
    case .working: if agents.claudeWorking > 0 { parts.append(L(agents.claudeWorking > 1 ? "%lld sessions en cours" : "%lld session en cours", agents.claudeWorking)) }
    }
    if !agents.subagents.isEmpty { parts.append(L(agents.subagents.count > 1 ? "%lld sous-agents" : "%lld sous-agent", agents.subagents.count)) }
    return parts.joined(separator: " · ")
}

// MARK: - First visit

private struct AgentPicker: View {
    @Environment(\.notcherAccent) private var accent
    @State private var selection: Set<AgentKind>
    var done: (Set<AgentKind>) -> Void
    init(initial: Set<AgentKind>, done: @escaping (Set<AgentKind>) -> Void) { _selection = State(initialValue: initial); self.done = done }
    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 5) {
                Text("Quels agents utilises-tu ?").font(.system(size: 17, weight: .semibold))
                Text("Notcher suit leurs quotas et leur activité. Tu pourras changer plus tard.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                tile(.claude, detail: "Quotas, activité en direct, sous-agents et un petit compagnon.", color: Theme.orange) {
                    AgentStage(mood: .idle, clones: [], doneAt: nil).frame(height: 76)
                }
                tile(.codex, detail: "Quotas et statistiques d’utilisation.", color: accent) {
                    Text(">_").font(.system(size: 30, weight: .medium, design: .monospaced)).foregroundStyle(accent.opacity(0.8)).frame(maxWidth: .infinity).frame(height: 76)
                }
            }
            CapsuleButton(title: "Continuer", symbol: "arrow.right", primary: true) { done(selection) }
                .disabled(selection.isEmpty).opacity(selection.isEmpty ? 0.4 : 1)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func tile<Art: View>(_ kind: AgentKind, detail: String, color: Color, @ViewBuilder art: () -> Art) -> some View {
        let on = selection.contains(kind)
        return VStack(alignment: .leading, spacing: 8) {
            art()
            HStack {
                Text(kind.name).font(.system(size: 13, weight: .semibold))
                Spacer()
                Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.system(size: 15)).foregroundStyle(on ? color : Theme.muted)
                    .contentTransition(.symbolEffect(.replace))
            }
            Text(L(detail)).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).frame(height: 26, alignment: .topLeading)
        }
        .padding(13)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(on ? color.opacity(0.7) : Theme.border, lineWidth: on ? 1.5 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onTapGesture {
            if on { selection.remove(kind) } else { selection.insert(kind) }
            Haptics.play(.alignment)
        }
        .animation(.easeOut(duration: 0.15), value: on)
    }
}

// MARK: - Both agents

private struct AgentOverview: View {
    @Environment(\.notcherAccent) private var accent
    @ObservedObject var model: AppModel
    @ObservedObject var agents: AgentService
    @ObservedObject var stats: UsageStatsService
    var open: (AgentKind) -> Void
    var change: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Agents").font(.system(size: 17, weight: .semibold))
                Spacer()
                IconButton(symbol: "arrow.left.arrow.right", help: "Changer d’agents", action: change)
            }
            HStack(alignment: .top, spacing: 12) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let mood = claudeMood(agents, at: context.date)
                    AgentCard(name: "Claude Code", mark: "✳", color: Theme.orange, usage: agents.claude, status: agents.claudeStatus, connected: agents.claudeInstalled,
                              button: "Connecter Claude Code", live: mood == .idle ? nil : claudeStatus(agents, mood), today: stats.claude?.today, open: { open(.claude) }) {
                        do { try agents.installClaude(); model.notify("Claude Code est connecté. Les quotas arriveront à sa prochaine réponse.") }
                        catch { model.notify(error.localizedDescription) }
                    }
                }
                AgentCard(name: "Codex", mark: ">_", color: accent, usage: agents.codex, status: agents.codexStatus, connected: model.preferences.codexEnabled,
                          button: agents.refreshing ? "Connexion…" : "Connecter Codex", live: nil, today: stats.codex?.today, open: { open(.codex) }) {
                    model.preferences.codexEnabled = true
                    Task { await agents.refreshCodex() }
                }
            }.frame(maxHeight: .infinity)
        }
        .onAppear { stats.refresh(.claude); stats.refresh(.codex) }
    }
}

struct AgentCard: View {
    let name: String
    let mark: String
    let color: Color
    let usage: AgentUsage?
    let status: String
    let connected: Bool
    let button: String
    /// What the agent is doing right now, when it says.
    var live: String? = nil
    var today: Int? = nil
    var open: (() -> Void)? = nil
    var connect: () -> Void
    @State private var hovering = false
    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 9) {
                    Text(mark).font(.system(size: 19, weight: .medium, design: .monospaced)).foregroundStyle(color).frame(width: 32, height: 32).background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name).font(.system(size: 13, weight: .semibold))
                        if let live { Text(live).font(.system(size: 9, weight: .medium)).foregroundStyle(color).lineLimit(1) }
                        else if let model = usage?.model { Text(model).font(.system(size: 9)).foregroundStyle(Theme.muted).lineLimit(1) }
                    }
                    Spacer()
                    if open != nil { Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(hovering ? color : Theme.muted).offset(x: hovering ? 2 : 0) }
                }
                if let usage, !usage.windows.isEmpty {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        VStack(spacing: 12) { ForEach(usage.windows) { QuotaRow(window: $0, color: color, now: context.date) } }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("—").font(.system(size: 33, weight: .light)).foregroundStyle(.white.opacity(0.2))
                        Text(L(connected ? "En attente" : "Non connecté")).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if !connected { CapsuleButton(title: button, symbol: "link", action: connect) }
                else {
                    HStack {
                        if let today, today > 0 { Text(L("%@ tokens aujourd’hui", UsageHistory.short(today))).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary) }
                        else if usage == nil { Text(L(status)).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2) }
                        Spacer()
                        if open != nil { Text("Détails").font(.system(size: 9, weight: .semibold)).foregroundStyle(hovering ? color : Theme.muted) }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(color.opacity(hovering && open != nil ? 0.45 : 0), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onHover { hovering = $0 }
        .onTapGesture { if let open { Haptics.play(.alignment); open() } }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

private struct QuotaRow: View {
    let window: UsageWindow
    let color: Color
    let now: Date
    var compact = false
    var body: some View {
        let expired = window.isExpired(at: now)
        let tint = window.usedPercent >= 90 ? Theme.orange : color
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(window.title).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                if let reset = window.resetsAt, !expired, compact {
                    Text(L("Réinitialisation %@", reset.formatted(.relative(presentation: .named)))).font(.system(size: 8)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Text(expired ? L("À actualiser") : L("%lld %% utilisés", Int(window.usedPercent))).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(expired ? Theme.muted : tint)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.06))
                    Capsule().fill(tint.opacity(expired ? 0.3 : 1)).frame(width: max(0, geo.size.width * window.fraction))
                }
            }.frame(height: 4)
            if let reset = window.resetsAt, !compact {
                Text(expired ? L("À actualiser") : L("Réinitialisation %@", reset.formatted(.relative(presentation: .named))))
                    .font(.system(size: 8)).foregroundStyle(Theme.muted).lineLimit(1)
            }
        }
    }
}

// MARK: - One agent

private struct AgentDetail: View {
    @Environment(\.notcherAccent) private var accent
    let kind: AgentKind
    @ObservedObject var model: AppModel
    @ObservedObject var agents: AgentService
    @ObservedObject var stats: UsageStatsService
    var back: (() -> Void)?
    var change: () -> Void
    @State private var refreshing = false
    private var color: Color { kind == .claude ? Theme.orange : accent }
    private var usage: AgentUsage? { kind == .claude ? agents.claude : agents.codex }
    private var connected: Bool { kind == .claude ? agents.claudeInstalled : model.preferences.codexEnabled }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let mood = claudeMood(agents, at: context.date)
            VStack(alignment: .leading, spacing: 10) {
                header(mood)
                HStack(spacing: 10) {
                    if kind == .claude {
                        AgentStage(mood: mood, clones: agents.subagents, doneAt: agents.claudeFinishedAt, scenes: true)
                            .background(LinearGradient(colors: [Color(white: 0.045), mood == .waiting ? Theme.orange.opacity(0.12) : Theme.surface], startPoint: .top, endPoint: .bottom),
                                        in: RoundedRectangle(cornerRadius: 18))
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.border))
                            .frame(width: 260)
                            .animation(.easeOut(duration: 0.4), value: mood)
                    }
                    quotas(at: context.date)
                }.frame(height: 136)
                StatsCard(history: stats.history(kind), color: color, loading: stats.loading)
            }
        }
        .onAppear { stats.refresh(kind) }
    }
    private func header(_ mood: AgentStage.Mood) -> some View {
        HStack(spacing: 9) {
            if let back { IconButton(symbol: "chevron.left", help: "Retour", action: back) }
            Text(kind == .claude ? "✳" : ">_").font(.system(size: 16, weight: .medium, design: .monospaced)).foregroundStyle(color)
                .frame(width: 32, height: 32).background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.name).font(.system(size: 15, weight: .semibold))
                Group {
                    if kind == .claude, mood != .idle { Text(claudeStatus(agents, mood)).foregroundStyle(color) }
                    else if let favorite = stats.history(kind)?.favoriteModel ?? usage?.model { Text(L("Surtout %@", favorite)).foregroundStyle(Theme.muted) }
                    else { Text(L(kind == .claude ? "Au repos" : (connected ? "Connecté" : "Non connecté"))).foregroundStyle(Theme.muted) }
                }.font(.system(size: 10, weight: .medium)).lineLimit(1)
            }
            Spacer()
            IconButton(symbol: "arrow.clockwise", help: "Actualiser") {
                guard !refreshing else { return }
                refreshing = true; Haptics.play(.alignment); stats.refresh(kind, force: true)
                Task { model.notify(await agents.refreshAll()); refreshing = false }
            }
            .rotationEffect(.degrees(refreshing ? 360 : 0))
            .animation(refreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .easeOut(duration: 0.2), value: refreshing)
            .disabled(refreshing)
            IconButton(symbol: "arrow.left.arrow.right", help: "Changer d’agents", action: change)
        }.frame(height: 32)
    }
    private func quotas(at now: Date) -> some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 11) {
                Text("Quotas").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                if let usage, !usage.windows.isEmpty {
                    ForEach(usage.windows.prefix(3)) { QuotaRow(window: $0, color: color, now: now, compact: true) }
                    Spacer(minLength: 0)
                    Text(L("Relevé %@", usage.capturedAt.formatted(.dateTime.hour().minute())) + (usage.isStale() ? L(" · ancien") : ""))
                        .font(.system(size: 8)).foregroundStyle(usage.isStale() ? Theme.orange : Theme.muted)
                } else if !connected {
                    Spacer(minLength: 0)
                    CapsuleButton(title: kind == .claude ? "Connecter Claude Code" : "Connecter Codex", symbol: "link") {
                        if kind == .claude {
                            do { try agents.installClaude(); model.notify("Claude Code est connecté. Les quotas arriveront à sa prochaine réponse.") }
                            catch { model.notify(error.localizedDescription) }
                        } else { model.preferences.codexEnabled = true; Task { await agents.refreshCodex() } }
                    }
                } else {
                    Spacer(minLength: 0)
                    Text(L(kind == .claude ? agents.claudeStatus : agents.codexStatus)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// Tokens per day over the last thirty days, like Claude Code's own usage screen, and a few counts beside them.
private struct StatsCard: View {
    let history: UsageHistory?
    let color: Color
    let loading: Bool
    @State private var hovered: Int?
    var body: some View {
        Card(padding: 14) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        if let history, let index = hovered, history.days.indices.contains(index) {
                            let day = history.days[index]
                            Text(day.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))).font(.system(size: 11, weight: .semibold))
                            Text(L("%@ tokens", UsageHistory.short(day.tokens))).font(.system(size: 10, design: .monospaced)).foregroundStyle(color)
                        } else {
                            Text("30 derniers jours").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            if let history { Text(L("%@ tokens", UsageHistory.short(history.total))).font(.system(size: 10, design: .monospaced)).foregroundStyle(color) }
                        }
                    }
                    chart.frame(maxHeight: .infinity)
                }
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                    GridRow {
                        tile("Aujourd’hui", history.map { UsageHistory.short($0.today) })
                        tile("Sessions", history.map { "\($0.sessions)" })
                    }
                    GridRow {
                        tile("Jours actifs", history.map { "\($0.activeDays)/\($0.days.count)" })
                        tile("Série", history.map { L($0.streak > 1 ? "%lld jours" : "%lld jour", $0.streak) })
                    }
                }.frame(width: 190, alignment: .leading)
            }
        }.frame(maxHeight: .infinity)
    }
    @ViewBuilder private var chart: some View {
        if let history, history.total > 0 {
            let peak = max(1, history.days.map(\.tokens).max() ?? 1)
            GeometryReader { geo in
                let gap: CGFloat = 3
                let bar = max(2, (geo.size.width - gap * CGFloat(history.days.count - 1)) / CGFloat(history.days.count))
                HStack(alignment: .bottom, spacing: gap) {
                    ForEach(Array(history.days.enumerated()), id: \.offset) { index, day in
                        let height = day.tokens == 0 ? 2 : max(3, geo.size.height * CGFloat(day.tokens) / CGFloat(peak))
                        let last = index == history.days.count - 1
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(day.tokens == 0 ? Color.white.opacity(0.07) : color.opacity(hovered == index || last ? 1 : hovered == nil ? 0.55 : 0.3))
                            .frame(width: bar, height: height)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                            .contentShape(Rectangle())
                            .onHover { inside in if inside { hovered = index } else if hovered == index { hovered = nil } }
                    }
                }
            }
            .animation(.easeOut(duration: 0.12), value: hovered)
        } else {
            Text(L(loading ? "Lecture de l’historique…" : "Pas encore d’utilisation ces 30 derniers jours."))
                .font(.system(size: 10)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private func tile(_ title: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L(title)).font(.system(size: 9)).foregroundStyle(Theme.muted)
            Text(value ?? "—").font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
    }
}

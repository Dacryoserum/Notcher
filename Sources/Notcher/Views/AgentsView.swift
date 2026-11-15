import SwiftUI
import NotcherCore

struct AgentsView: View {
    @Environment(\.notcherAccent) private var accent
    @ObservedObject var model: AppModel
    @ObservedObject var agents: AgentService
    @State private var refreshing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Quotas").font(.system(size: 17, weight: .semibold))
                Spacer()
                activity
                IconButton(symbol: "arrow.clockwise", help: "Actualiser les limites") {
                    guard !refreshing else { return }
                    refreshing = true; Haptics.play(.alignment)
                    Task { model.notify(await agents.refreshAll()); refreshing = false }
                }
                .rotationEffect(.degrees(refreshing ? 360 : 0))
                .animation(refreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .easeOut(duration: 0.2), value: refreshing)
                .disabled(refreshing)
            }
            HStack(alignment: .top, spacing: 12) {
                AgentCard(name: "Claude Code", mark: "✳", color: Theme.orange, usage: agents.claude, status: agents.claudeStatus, connected: agents.claudeInstalled, button: "Connecter Claude Code") {
                    do { try agents.installClaude(); model.notify("Claude Code est connecté. Les quotas arriveront à sa prochaine réponse.") }
                    catch { model.notify(error.localizedDescription) }
                }
                AgentCard(name: "Codex", mark: ">_", color: accent, usage: agents.codex, status: agents.codexStatus, connected: model.preferences.codexEnabled, button: agents.refreshing ? "Connexion…" : "Connecter Codex") {
                    model.preferences.codexEnabled = true
                    Task { await agents.refreshCodex() }
                }
            }.frame(maxHeight: .infinity)
        }
    }
    /// What Claude Code is doing right now: sessions answering, sessions waiting, helpers at work.
    @ViewBuilder private var activity: some View {
        HStack(spacing: 6) {
            if agents.claudeWorking > 0 { chip("ellipsis", L(agents.claudeWorking > 1 ? "%lld sessions en cours" : "%lld session en cours", agents.claudeWorking), Theme.orange) }
            if agents.claudeWaiting > 0 { chip("hand.raised.fill", L(agents.claudeWaiting > 1 ? "%lld en attente" : "%lld en attente de toi", agents.claudeWaiting), Theme.orange) }
            if !agents.subagents.isEmpty {
                let kinds = Dictionary(grouping: agents.subagents, by: \.type).map { ($0.key, $0.value.count) }.sorted { ($1.1, $0.0) < ($0.1, $1.0) }
                chip("point.3.connected.trianglepath.dotted", L(agents.subagents.count > 1 ? "%lld sous-agents" : "%lld sous-agent", agents.subagents.count), accent)
                    .help(kinds.map { $0.1 > 1 ? "\($0.0) × \($0.1)" : $0.0 }.joined(separator: ", "))
                ForEach(kinds.prefix(3), id: \.0) { kind in
                    Text(kind.1 > 1 ? "\(kind.0) × \(kind.1)" : kind.0).font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                        .padding(.horizontal, 7).frame(height: 20).background(.white.opacity(0.06), in: Capsule())
                }
            }
        }.animation(.snappy(duration: 0.22), value: agents.subagents)
    }
    private func chip(_ symbol: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            Text(text).font(.system(size: 10, weight: .medium)).lineLimit(1)
        }.foregroundStyle(color).padding(.horizontal, 8).frame(height: 20).background(color.opacity(0.12), in: Capsule())
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
    var connect: () -> Void
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 9) {
                    Text(mark).font(.system(size: 19, weight: .medium, design: .monospaced)).foregroundStyle(color).frame(width: 32, height: 32).background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name).font(.system(size: 13, weight: .semibold))
                        if let model = usage?.model { Text(model).font(.system(size: 9)).foregroundStyle(Theme.muted).lineLimit(1) }
                    }
                    Spacer()
                    Circle().fill(usage != nil && usage?.isStale() == false ? color : Theme.muted).frame(width: 5, height: 5)
                }
                if let usage, !usage.windows.isEmpty {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        VStack(spacing: 16) { ForEach(usage.windows) { window in quota(window, at: context.date) } }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("—").font(.system(size: 33, weight: .light)).foregroundStyle(.white.opacity(0.2))
                        Text(L(connected ? "En attente" : "Non connecté"))
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if !connected { CapsuleButton(title: button, symbol: "link", action: connect) }
                else {
                    VStack(alignment: .leading, spacing: 4) {
                        if usage == nil { Text(L(status)).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2) }
                        if let usage {
                            Text(L("Relevé %@", usage.capturedAt.formatted(.dateTime.hour().minute())) + (usage.isStale() ? L(" · ancien") : "")).font(.system(size: 8)).foregroundStyle(usage.isStale() ? Theme.orange : Theme.muted)
                        }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
    private func quota(_ window: UsageWindow, at now: Date) -> some View {
        let expired = window.isExpired(at: now)
        let tint = window.usedPercent >= 90 ? Theme.orange : color
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(window.title).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Text(expired ? L("À actualiser") : L("%lld %% utilisés", Int(window.usedPercent))).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(expired ? Theme.muted : tint)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.06))
                    Capsule().fill(tint.opacity(expired ? 0.3 : 1)).frame(width: max(0, geo.size.width * window.fraction))
                }
            }.frame(height: 4)
            if let reset = window.resetsAt {
                Text(expired ? L("À actualiser") : L("Réinitialisation %@", reset.formatted(.relative(presentation: .named))))
                    .font(.system(size: 8)).foregroundStyle(Theme.muted).lineLimit(1)
            }
        }
    }
}

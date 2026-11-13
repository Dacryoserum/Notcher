import SwiftUI
import NotcherCore

struct AgentsView: View {
    @Environment(\.notcherAccent) private var accent
    @ObservedObject var model: AppModel
    @ObservedObject var agents: AgentService
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Quotas").font(.system(size: 17, weight: .semibold))
                Spacer()
                IconButton(symbol: "arrow.clockwise", help: "Actualiser les limites") { agents.readClaude(); if model.preferences.codexEnabled { Task { await agents.refreshCodex() } } }
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

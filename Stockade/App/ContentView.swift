import AppKit
import LauncherCore
import SwiftUI

enum Screen: String, CaseIterable, Identifiable {
    case game, setup, settings, diagnostics, backups

    var id: String { rawValue }

    var title: String {
        switch self {
        case .game: return "Game"
        case .setup: return "Setup"
        case .settings: return "Settings"
        case .diagnostics: return "Diagnostics"
        case .backups: return "Save Backups"
        }
    }

    var symbol: String {
        switch self {
        case .game: return "play.circle"
        case .setup: return "checklist"
        case .settings: return "gearshape"
        case .diagnostics: return "stethoscope"
        case .backups: return "externaldrive.badge.timemachine"
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Screen? = nil

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(Screen.allCases, selection: $selection) { screen in
                Label(screen.title, systemImage: screen.symbol)
                    .tag(screen)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            VStack(spacing: 0) {
                banners
                Group {
                    switch selection ?? defaultScreen {
                    case .game: GameView()
                    case .setup: SetupView()
                    case .settings: SettingsView()
                    case .diagnostics: DiagnosticsView()
                    case .backups: BackupsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .toolbar {
                ToolbarItem {
                    if let busy = model.busy {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(busy).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                ToolbarItem {
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .help("Refresh status (⌘R)")
                    .disabled(model.isBusy)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
        }
        .alert(item: $model.error) { error in
            Alert(
                title: Text(error.message),
                message: error.suggestion.map(Text.init),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var defaultScreen: Screen {
        model.readiness.canLaunch ? .game : .setup
    }

    @ViewBuilder
    private var banners: some View {
        if let message = model.readOnlyMessage {
            Banner(text: message, symbol: "lock.fill", tint: .orange)
        }
        if let notice = model.notice {
            Banner(text: notice, symbol: "info.circle.fill", tint: .blue) {
                model.dismissNotice()
            }
        }
    }
}

struct Banner: View {
    let text: String
    let symbol: String
    let tint: Color
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).textSelection(.enabled)
            Spacer()
            if let onDismiss {
                Button("Dismiss", action: onDismiss)
                    .buttonStyle(.borderless)
            }
        }
        .padding(10)
        .background(tint.opacity(0.12))
    }
}

/// Completion state shown by `StatusRow`.
enum RowState {
    case done, pending, problem, working

    var symbol: String {
        switch self {
        case .done: return "checkmark.circle.fill"
        case .pending: return "circle"
        case .problem: return "exclamationmark.triangle.fill"
        case .working: return "clock"
        }
    }

    var tint: Color {
        switch self {
        case .done: return .green
        case .pending: return .secondary
        case .problem: return .orange
        case .working: return .blue
        }
    }

    var label: String {
        switch self {
        case .done: return "Done"
        case .pending: return "Not done"
        case .problem: return "Needs attention"
        case .working: return "In progress"
        }
    }
}

/// A row with a state icon, a title and supporting detail.
struct StatusRow<Accessory: View>: View {
    let state: RowState
    let title: String
    let detail: String?
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: state.symbol)
                .foregroundStyle(state.tint)
                .font(.title3)
                .accessibilityLabel(state.label)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                if let detail {
                    Text(detail)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                accessory()
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

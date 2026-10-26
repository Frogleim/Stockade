import LauncherCore
import SwiftUI

struct GameView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmShutdown = false

    var body: some View {
        let ready = model.readiness
        let phase = model.displayPhase
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.configuration.activeProfile?.name ?? "Farthest Frontier")
                        .font(.largeTitle.bold())
                    Text("Windows Steam edition · app \(String(model.configuration.activeProfile?.steamAppID ?? GameProfile.farthestFrontierAppID)) · experimental")
                        .foregroundStyle(.secondary)
                }

                GroupBox {
                    HStack(alignment: .top, spacing: 14) {
                        PhaseIcon(phase: phase)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(phase.headline).font(.title2.weight(.semibold))
                            Text(explanation(for: phase))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let requested = model.session?.requestedAt, phase != .ready, phase != .notConfigured {
                                Text("Requested \(requested.formatted(date: .omitted, time: .standard))")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                    }
                    .padding(8)
                    .accessibilityElement(children: .combine)
                }

                HStack(spacing: 12) {
                    Button {
                        Task { await model.launch() }
                    } label: {
                        Label("Launch", systemImage: "play.fill")
                            .frame(minWidth: 120)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready.canLaunch || model.isBusy || model.sessionActive)

                    Button("Open Steam") {
                        Task { await model.openSteam() }
                    }
                    .controlSize(.large)
                    .disabled(!ready.canOpenSteam || model.isBusy)

                    if model.sessionActive {
                        Button("Stop Observing") {
                            Task { await model.stopObserving() }
                        }
                        .controlSize(.large)
                        .help("Stop watching for the game. The game and Steam keep running.")
                    }
                    Spacer()
                }

                if !ready.problems.isEmpty {
                    GroupBox("Before you can launch") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(ready.problems, id: \.self) { problem in
                                Label(problem, systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                    }
                }

                GroupBox("Installation") {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("Game", value: ready.installStatus?.summary ?? "Unknown")
                        LabeledContent("Runtime", value: ready.runtime?.versionOutput ?? "None")
                        LabeledContent("Graphics", value: model.configuration.activeProfile?.backend.displayName ?? "—")
                    }
                    .padding(4)
                }

                GroupBox("Maintenance") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Quitting the launcher leaves the game and Steam running. To stop everything in the launcher's prefix — including Steam and any unsaved game — shut down the prefix. Programs in other Wine prefixes are never affected.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Shut Down Prefix…", role: .destructive) { confirmShutdown = true }
                                .disabled(ready.prefixStatus != .initialized || model.isBusy)
                            Button("Show Logs") { model.reveal(model.engine.paths.logs) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .navigationTitle("Game")
        .confirmationDialog("Shut down the prefix?", isPresented: $confirmShutdown) {
            Button("Shut Down Prefix", role: .destructive) {
                Task { await model.shutdownPrefix() }
            }
        } message: {
            Text("This stops every Windows program in \(model.configuration.activePrefix?.url.lastPathComponent ?? "the prefix"), including Steam and Farthest Frontier. Unsaved progress is lost.")
        }
    }

    private func explanation(for phase: SessionPhase) -> String {
        switch phase {
        case .notConfigured:
            return "Finish Setup before launching."
        case .ready:
            return "Steam will be asked to start the game. If Steam needs to update or sign in first, that happens in its own window."
        case .launchRequested:
            return "The request was sent to Steam. Steam may be starting, updating, or waiting for you to sign in."
        case .starting:
            return "Steam is running in the launcher's prefix. Waiting for the game process to appear."
        case .runningObserved:
            return "A Farthest Frontier process was observed in the launcher's prefix."
        case .exited:
            return "The game process is no longer running. Steam may still be open."
        case .failed:
            return model.session?.failureReason ?? "The launch could not be completed. See Diagnostics."
        case .statusUnknown:
            return "The launcher could not observe the game process. Look at the Steam window. If the game is running, its process name may differ from the detection hints in Settings."
        }
    }
}

private struct PhaseIcon: View {
    let phase: SessionPhase

    var body: some View {
        Group {
            switch phase {
            case .launchRequested, .starting:
                ProgressView().controlSize(.large)
            default:
                Image(systemName: symbol)
                    .font(.system(size: 34))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: 44, height: 44)
        .accessibilityHidden(true)
    }

    private var symbol: String {
        switch phase {
        case .notConfigured: return "wrench.and.screwdriver"
        case .ready: return "checkmark.circle"
        case .runningObserved: return "gamecontroller.fill"
        case .exited: return "stop.circle"
        case .failed: return "xmark.octagon.fill"
        case .statusUnknown: return "questionmark.circle"
        default: return "circle"
        }
    }

    private var tint: Color {
        switch phase {
        case .ready, .runningObserved: return .green
        case .failed: return .red
        case .statusUnknown, .notConfigured: return .orange
        default: return .secondary
        }
    }
}

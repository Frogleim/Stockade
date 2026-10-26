import LauncherCore
import SwiftUI
import UniformTypeIdentifiers

struct SetupView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ready = model.readiness
        Form {
            Section {
                Text("Stockade prepares one dedicated Wine prefix, runs Windows Steam inside it and asks Steam to start Farthest Frontier. You need a Wine runtime that works on this Mac, the Windows Steam installer, and your own Steam copy of the game.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("1. Wine runtime") {
                StatusRow(
                    state: ready.runtime == nil ? .pending : (runtimeProblem == nil ? .done : .problem),
                    title: ready.runtime?.displayName ?? "No runtime selected",
                    detail: runtimeDetail
                ) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.runtimeWarnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                        Button(ready.runtime == nil ? "Choose Wine Executable…" : "Choose a Different Runtime…") {
                            if let url = FilePanels.chooseFile(message: "Select the `wine` or `wine64` executable inside your runtime's bin folder.") {
                                Task { await model.selectRuntime(url) }
                            }
                        }
                        .disabled(model.isBusy || model.sessionActive)
                    }
                }
            }

            Section("2. Game prefix") {
                StatusRow(
                    state: prefixState,
                    title: prefixTitle,
                    detail: ready.prefix?.url.path
                ) {
                    HStack {
                        if ready.canInitializePrefix || (ready.prefix == nil && ready.runtime != nil) {
                            Button(ready.prefix == nil ? "Create and Initialize Prefix" : "Initialize Prefix") {
                                Task { await model.createAndInitializePrefix() }
                            }
                            .disabled(model.isBusy)
                        }
                        if let url = ready.prefix?.url, ready.prefixStatus != .missing {
                            Button("Show in Finder") { model.reveal(url) }
                        }
                    }
                }
            }

            Section("3. Windows Steam") {
                StatusRow(
                    state: ready.steamExecutable != nil ? .done : .pending,
                    title: ready.steamExecutable != nil ? "Windows Steam is installed in the prefix" : "Windows Steam is not installed",
                    detail: ready.steamExecutable == nil
                        ? "Download SteamSetup.exe from store.steampowered.com, then run it here. Keep the default install location."
                        : nil
                ) {
                    Button(ready.steamExecutable == nil ? "Run Steam Installer…" : "Run Installer Again…") {
                        if let url = FilePanels.chooseFile(
                            message: "Select SteamSetup.exe",
                            allowedTypes: [UTType(filenameExtension: "exe") ?? .data],
                            startingAt: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                        ) {
                            Task { await model.runSteamInstaller(url) }
                        }
                    }
                    .disabled(!ready.canInstallSteam || model.isBusy || model.sessionActive)
                }
            }

            Section("4. Sign in and install the game") {
                StatusRow(
                    state: installState,
                    title: ready.installStatus?.summary ?? "Install status unknown",
                    detail: "Open Steam, sign in, then install Farthest Frontier from your library. Steam handles downloads and updates; the first sign-in and Steam's own update can take a while."
                ) {
                    Button("Open Steam") {
                        Task { await model.openSteam() }
                    }
                    .disabled(!ready.canOpenSteam || model.isBusy)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Setup")
    }

    private var runtimeProblem: String? {
        model.readiness.problems.first { $0.localizedCaseInsensitiveContains("runtime") }
    }

    private var runtimeDetail: String? {
        guard let runtime = model.readiness.runtime else {
            return "Choose a Wine build that is known to work with Direct3D 11 games on Apple Silicon. The launcher does not download runtimes."
        }
        if let runtimeProblem { return runtimeProblem }
        let arch = runtime.architectures.map(\.rawValue).joined(separator: ", ")
        let rosetta = runtime.needsRosetta ? " — runs through Rosetta 2" : ""
        return "\(runtime.versionOutput) · \(arch)\(rosetta)\n\(runtime.wineExecutable.path)"
    }

    private var prefixState: RowState {
        switch model.readiness.prefixStatus {
        case .initialized: return .done
        case .initializing: return .working
        case .interrupted, .missing: return .problem
        default: return .pending
        }
    }

    private var prefixTitle: String {
        switch model.readiness.prefixStatus {
        case .initialized: return "Prefix initialized"
        case .initializing: return "Prefix is initializing…"
        case .interrupted: return "Initialization was interrupted — reset the prefix in Settings"
        case .missing: return "Prefix folder is missing"
        case .uninitialized: return "Prefix created but not initialized"
        case nil: return "No prefix yet"
        }
    }

    private var installState: RowState {
        switch model.readiness.installStatus {
        case .installed: return .done
        case .needsUpdate, .incomplete: return .working
        case .unknown: return .problem
        default: return .pending
        }
    }
}

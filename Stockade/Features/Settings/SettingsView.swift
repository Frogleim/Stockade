import LauncherCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var argumentsText = ""
    @State private var hintsText = ""
    @State private var steamArgsText = ""
    @State private var confirmReset = false

    var body: some View {
        let config = model.configuration
        Form {
            Section("Runtime") {
                if let runtime = config.activeRuntime {
                    LabeledContent("Name", value: runtime.displayName)
                    LabeledContent("Version", value: runtime.versionOutput)
                    LabeledContent("Architecture", value: runtime.architectures.map(\.rawValue).joined(separator: ", "))
                    LabeledContent("Detected graphics", value: runtime.detectedBackends.map(\.displayName).joined(separator: ", "))
                    LabeledContent("wine") { PathText(runtime.wineExecutable.path) }
                    LabeledContent("SHA-256") { PathText(runtime.executableSHA256) }
                    LabeledContent("Validated", value: runtime.validatedAt.formatted())
                } else {
                    Text("No runtime selected. Choose one in Setup.").foregroundStyle(.secondary)
                }
            }

            Section {
                if let prefix = config.activePrefix {
                    LabeledContent("Location") { PathText(prefix.url.path) }
                    LabeledContent("Status", value: model.readiness.prefixStatus?.rawValue ?? "unknown")
                    if let last = prefix.lastSuccessfulLaunch {
                        LabeledContent("Last observed game run", value: last.formatted())
                    }
                    HStack {
                        Button("Show in Finder") { model.reveal(prefix.url) }
                        Spacer()
                        Button("Delete Prefix…", role: .destructive) { confirmReset = true }
                            .disabled(model.isBusy || model.sessionActive)
                    }
                } else {
                    Text("No prefix yet.").foregroundStyle(.secondary)
                }
            } header: {
                Text("Prefix")
            } footer: {
                Text("One launcher-owned prefix is used with one runtime. Never point a different Wine version at the same prefix.")
            }

            Section {
                LabeledContent("Steam location") {
                    PathText(model.readiness.steamExecutable?.path ?? "Not found")
                }
                HStack {
                    Button("Choose steam.exe…") {
                        if let url = FilePanels.chooseFile(message: "Select steam.exe inside the launcher's prefix", startingAt: config.activePrefix?.url) {
                            Task { await model.setSteamOverride(url) }
                        }
                    }
                    if config.steamExecutableOverride != nil {
                        Button("Use Automatic Detection") { Task { await model.setSteamOverride(nil) } }
                    }
                }
                .disabled(config.activePrefix == nil || model.isBusy)
                TextEditor(text: $steamArgsText)
                    .font(.body.monospaced())
                    .frame(minHeight: 44)
                    .accessibilityLabel("Steam client options, one per line")
                Button("Save Steam Options") { Task { await model.setSteamClientArguments(steamArgsText) } }
                    .disabled(model.isBusy)
            } header: {
                Text("Steam")
            } footer: {
                Text("The location is only needed if Steam was installed somewhere other than the default folder; it must be inside the prefix. Steam options, one per line, are passed to steam.exe every time it starts. If the Steam window is black or disappears, try -cef-disable-gpu. Restart Steam after changing them.")
            }

            if config.activeProfile != nil {
                Section {
                    TextEditor(text: $argumentsText)
                        .font(.body.monospaced())
                        .frame(minHeight: 60)
                        .accessibilityLabel("Launch arguments, one per line")
                    Button("Save Arguments") { Task { await model.setLaunchArguments(argumentsText) } }
                        .disabled(model.isBusy)
                } header: {
                    Text("Launch arguments")
                } footer: {
                    Text("One argument per line, passed to the game after `-applaunch`. Add only arguments you have verified; they are never interpreted by a shell.")
                }

                Section {
                    TextEditor(text: $hintsText)
                        .font(.body.monospaced())
                        .frame(minHeight: 50)
                        .accessibilityLabel("Process detection hints, one per line")
                    Button("Save Hints") { Task { await model.setProcessHints(hintsText) } }
                        .disabled(model.isBusy)
                } header: {
                    Text("Game process detection")
                } footer: {
                    Text("Text matched against process names in the prefix to recognize the running game. Confirm the real executable name during your compatibility baseline.")
                }
            }

            Section {
                Toggle("Verbose Wine logging", isOn: Binding(
                    get: { config.verboseWineLogging },
                    set: { value in Task { await model.setVerboseLogging(value) } }
                ))
                .disabled(model.isBusy)
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Verbose logging can lower performance and use a lot of disk space. Turn it on only while investigating a problem.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onAppear(perform: loadText)
        .onChange(of: model.configuration.activeProfile) { loadText() }
        .confirmationDialog("Delete the prefix?", isPresented: $confirmReset) {
            if let path = config.activePrefix?.url.path {
                Button("Delete Prefix", role: .destructive) {
                    Task { await model.resetPrefix(confirmation: path) }
                }
            }
        } message: {
            Text("This permanently deletes \(config.activePrefix?.url.path ?? "the prefix"): Windows Steam, the installed game, and any local saves inside it. Back up your saves first. Steam Cloud copies are not affected.")
        }
    }

    private func loadText() {
        argumentsText = model.configuration.activeProfile?.launchArguments.joined(separator: "\n") ?? ""
        hintsText = model.configuration.activeProfile?.processMatchHints.joined(separator: "\n") ?? ""
        steamArgsText = (model.configuration.steamClientArguments ?? []).joined(separator: "\n")
    }
}

struct PathText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.callout.monospaced())
            .textSelection(.enabled)
            .lineLimit(3)
            .truncationMode(.middle)
            .multilineTextAlignment(.trailing)
    }
}

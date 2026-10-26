import AppKit
import LauncherCore
import SwiftUI
import UniformTypeIdentifiers

struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @State private var report = ""

    var body: some View {
        Form {
            Section("Detected problems") {
                if model.readiness.problems.isEmpty {
                    Label("No problems detected", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                } else {
                    ForEach(model.readiness.problems, id: \.self) { problem in
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section("Recent sessions") {
                if model.configuration.recentSessions.isEmpty {
                    Text("No launches yet.").foregroundStyle(.secondary)
                }
                ForEach(model.configuration.recentSessions) { session in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(session.phase.headline).font(.headline)
                            Spacer()
                            Text(session.requestedAt.formatted()).foregroundStyle(.secondary)
                        }
                        if let reason = session.failureReason {
                            Text(reason).foregroundStyle(.red)
                        }
                        if let name = session.logFileName {
                            Text(name).font(.caption.monospaced()).foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            Section("Live output") {
                ScrollView {
                    Text(model.output.isEmpty ? "No output yet." : model.output.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 120, maxHeight: 200)
                Button("Show Log Files") { model.reveal(model.engine.paths.logs) }
            }

            Section {
                if report.isEmpty {
                    Button("Generate Report Preview") {
                        Task { report = await model.diagnosticsReport() }
                    }
                } else {
                    ScrollView {
                        Text(report)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 200, maxHeight: 320)
                    HStack {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(report, forType: .string)
                        }
                        Button("Export…") {
                            if let url = FilePanels.saveFile(named: "stockade-diagnostics.txt", type: .plainText) {
                                Task { await model.exportDiagnostics(to: url) }
                            }
                        }
                        Button("Regenerate") {
                            Task { report = await model.diagnosticsReport() }
                        }
                    }
                }
            } header: {
                Text("Diagnostics report")
            } footer: {
                Text("The report contains versions, statuses, the sanitized launch plan and the last log lines. It excludes Steam login data, cookies, tokens, your environment and your saves, and replaces your home folder and user name. Review it before sharing.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Diagnostics")
    }
}

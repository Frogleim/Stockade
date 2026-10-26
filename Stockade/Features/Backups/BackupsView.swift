import LauncherCore
import SwiftUI

struct BackupsView: View {
    @Environment(AppModel.self) private var model
    @State private var pendingRestore: BackupRecord?

    var body: some View {
        let saves = model.configuration.activeProfile?.saveDirectory
        Form {
            Section {
                LabeledContent("Save folder") { PathText(saves?.path ?? "Not set") }
                Button(saves == nil ? "Choose Save Folder…" : "Change Save Folder…") {
                    if let url = FilePanels.chooseDirectory(
                        message: "Select the folder where Farthest Frontier writes its saves inside the prefix.",
                        startingAt: model.configuration.activePrefix?.url.appendingPathComponent("drive_c/users")
                    ) {
                        Task { await model.setSaveDirectory(url) }
                    }
                }
                .disabled(model.configuration.activeProfile == nil || model.isBusy)
            } header: {
                Text("Save location")
            } footer: {
                Text("Verify the folder first: create a new save in the game, quit, and check that a file in this folder changed.")
            }

            Section {
                Button("Back Up Now") { Task { await model.backupNow() } }
                    .disabled(saves == nil || model.isBusy || model.sessionActive)
            } footer: {
                Text("Close the game before backing up. Each backup is checksummed and verified before it is reported as complete.")
            }

            Section {
                if model.backups.isEmpty {
                    Text("No backups yet.").foregroundStyle(.secondary)
                }
                ForEach(model.backups) { record in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(record.manifest.createdAt.formatted()).font(.headline)
                            Text("\(record.manifest.files.count) file(s)" + (record.manifest.gameVersion.map { " · build \($0)" } ?? ""))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restore…") { pendingRestore = record }
                            .disabled(saves == nil || model.isBusy || model.sessionActive)
                    }
                }
            } header: {
                Text("Backups")
            } footer: {
                Text("Steam Cloud may sync a different version of your saves the next time the game starts. If Steam reports a conflict, choose the local files to keep the restored saves.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Save Backups")
        .confirmationDialog(
            "Restore this backup?",
            isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
            presenting: pendingRestore
        ) { record in
            Button("Restore") { Task { await model.restore(record) } }
        } message: { record in
            Text("Saves in \(saves?.path ?? "the save folder") will be replaced with the backup from \(record.manifest.createdAt.formatted()). Your current saves are moved aside, not deleted.")
        }
    }
}

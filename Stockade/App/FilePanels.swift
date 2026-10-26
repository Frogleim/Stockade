import AppKit
import UniformTypeIdentifiers

/// AppKit panels give access to files inside app bundles, where many Wine runtimes keep `wine`.
@MainActor
enum FilePanels {
    static func chooseFile(message: String, allowedTypes: [UTType]? = nil, startingAt directory: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = directory
        if let allowedTypes { panel.allowedContentTypes = allowedTypes }
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseDirectory(message: String, startingAt directory: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = directory
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func saveFile(named name: String, type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        return panel.runModal() == .OK ? panel.url : nil
    }
}

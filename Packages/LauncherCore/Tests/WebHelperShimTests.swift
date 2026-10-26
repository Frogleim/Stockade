import Foundation
import Testing
@testable import LauncherCore

@Suite struct WebHelperShimTests {
    func setUp() -> (TempDirectory, URL, URL, URL) {
        let dir = TempDirectory()
        let steam = dir.file("Steam/steam.exe")
        let helper = dir.file("Steam/bin/cef/cef.win64/steamwebhelper.exe", contents: "VALVE ORIGINAL v1")
        let shim = dir.file("shim.exe", contents: "MZ...FRONTIER_LAUNCHER_WEBHELPER_SHIM_V1...")
        return (dir, steam, helper, shim)
    }

    @Test func installKeepsOriginalAndIsIdempotent() throws {
        let (dir, steam, helper, shim) = setUp(); _ = dir
        let original = helper.deletingLastPathComponent().appendingPathComponent(WebHelperShim.originalName)
        #expect(try WebHelperShim().install(shim, steamExecutable: steam).count == 1)
        #expect(WebHelperShim.isShim(helper))
        #expect(try String(contentsOf: original, encoding: .utf8) == "VALVE ORIGINAL v1")
        #expect(try WebHelperShim().install(shim, steamExecutable: steam).isEmpty)
        #expect(try String(contentsOf: original, encoding: .utf8) == "VALVE ORIGINAL v1")
    }

    @Test func steamUpdateRefreshesKeptOriginal() throws {
        let (dir, steam, helper, shim) = setUp(); _ = dir
        try WebHelperShim().install(shim, steamExecutable: steam)
        try Data("VALVE ORIGINAL v2".utf8).write(to: helper)   // Steam updated itself
        try WebHelperShim().install(shim, steamExecutable: steam)
        let original = helper.deletingLastPathComponent().appendingPathComponent(WebHelperShim.originalName)
        #expect(try String(contentsOf: original, encoding: .utf8) == "VALVE ORIGINAL v2")
        #expect(WebHelperShim.isShim(helper))
    }

    @Test func refusesWhenValveBinaryIsGone() throws {
        let (dir, steam, helper, shim) = setUp(); _ = dir
        try Data(contentsOf: shim).write(to: helper)   // shim present, no original kept
        #expect(throws: LauncherError.self) { try WebHelperShim().install(shim, steamExecutable: steam) }
    }

    @Test func rejectsFilesThatAreNotTheShim() throws {
        let (dir, steam, helper, _) = setUp()
        let impostor = dir.file("other.exe", contents: "MZ something else")
        #expect(throws: LauncherError.self) { try WebHelperShim().install(impostor, steamExecutable: steam) }
        #expect(try String(contentsOf: helper, encoding: .utf8) == "VALVE ORIGINAL v1")
    }

    @Test func uninstallRestoresOriginal() throws {
        let (dir, steam, helper, shim) = setUp(); _ = dir
        try WebHelperShim().install(shim, steamExecutable: steam)
        try WebHelperShim().uninstall(steamExecutable: steam)
        #expect(try String(contentsOf: helper, encoding: .utf8) == "VALVE ORIGINAL v1")
        #expect(!FileManager.default.fileExists(atPath: helper.deletingLastPathComponent().appendingPathComponent(WebHelperShim.originalName).path))
    }
}

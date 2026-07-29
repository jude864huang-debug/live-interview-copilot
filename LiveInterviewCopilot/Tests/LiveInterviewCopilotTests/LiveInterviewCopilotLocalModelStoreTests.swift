import XCTest
import FluidAudio
@testable import LiveInterviewCopilotKit

final class LiveInterviewCopilotLocalModelStoreTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveInterviewCopilotLocalModelStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testParakeetDirectoryMigratesExistingFluidAudioCacheIntoStableStore() throws {
        let baseDirectory = tempDirectory.appendingPathComponent("Base", isDirectory: true)
        let fluidAudioRoot = tempDirectory.appendingPathComponent("FluidAudio", isDirectory: true)
        let sourceDirectory = fluidAudioRoot.appendingPathComponent(Repo.parakeet.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let marker = sourceDirectory.appendingPathComponent("marker.txt")
        try Data("parakeet".utf8).write(to: marker)

        let wrapper = LiveInterviewCopilotLocalModelStore.parakeetDirectory(
            for: .v3,
            baseDirectory: baseDirectory,
            fluidAudioModelsRoot: fluidAudioRoot
        )

        let migratedDirectory = wrapper
            .deletingLastPathComponent()
            .appendingPathComponent(Repo.parakeet.folderName, isDirectory: true)

        XCTAssertTrue(FileManager.default.fileExists(atPath: migratedDirectory.appendingPathComponent("marker.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceDirectory.path))
        XCTAssertEqual(
            wrapper,
            baseDirectory
                .appendingPathComponent("parakeet", isDirectory: true)
                .appendingPathComponent("parakeet-v3", isDirectory: true)
                .appendingPathComponent("current", isDirectory: true)
        )
    }

    func testQwen3DirectoryMigratesExistingFluidAudioCacheIntoStableStore() throws {
        let baseDirectory = tempDirectory.appendingPathComponent("Base", isDirectory: true)
        let fluidAudioRoot = tempDirectory.appendingPathComponent("FluidAudio", isDirectory: true)
        let sourceDirectory = fluidAudioRoot.appendingPathComponent(Repo.qwen3Asr.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try Data("qwen".utf8).write(to: sourceDirectory.appendingPathComponent("marker.txt"))

        let target = LiveInterviewCopilotLocalModelStore.qwen3Directory(
            variant: .f32,
            baseDirectory: baseDirectory,
            fluidAudioModelsRoot: fluidAudioRoot
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("marker.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceDirectory.path))
        XCTAssertEqual(
            target,
            baseDirectory
                .appendingPathComponent("qwen3-asr", isDirectory: true)
                .appendingPathComponent("f32", isDirectory: true)
        )
    }

    func testMigrateDownloadedQwen3ModelsMovesDownloadedDirectoryIntoStableStore() throws {
        let baseDirectory = tempDirectory.appendingPathComponent("Base", isDirectory: true)
        let fluidAudioRoot = tempDirectory.appendingPathComponent("FluidAudio", isDirectory: true)
        let downloadedDirectory = tempDirectory.appendingPathComponent("downloaded-qwen", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadedDirectory, withIntermediateDirectories: true)
        try Data("qwen".utf8).write(to: downloadedDirectory.appendingPathComponent("marker.txt"))

        let migrated = LiveInterviewCopilotLocalModelStore.migrateDownloadedQwen3Models(
            from: downloadedDirectory,
            variant: .f32,
            baseDirectory: baseDirectory,
            fluidAudioModelsRoot: fluidAudioRoot
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: migrated.appendingPathComponent("marker.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloadedDirectory.path))
    }

    func testClearModelCacheRemovesStableAndLegacyLocations() throws {
        let baseDirectory = tempDirectory.appendingPathComponent("Base", isDirectory: true)
        let fluidAudioRoot = tempDirectory.appendingPathComponent("FluidAudio", isDirectory: true)

        let stableParakeet = LiveInterviewCopilotLocalModelStore.parakeetDirectory(
            for: .v3,
            baseDirectory: baseDirectory,
            fluidAudioModelsRoot: fluidAudioRoot
        ).deletingLastPathComponent()
        let legacyParakeet = fluidAudioRoot.appendingPathComponent(Repo.parakeet.name, isDirectory: true)
        try FileManager.default.createDirectory(at: stableParakeet, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacyParakeet, withIntermediateDirectories: true)

        let stableQwen = LiveInterviewCopilotLocalModelStore.qwen3Directory(
            variant: .f32,
            baseDirectory: baseDirectory,
            fluidAudioModelsRoot: fluidAudioRoot
        )
        let legacyQwen = fluidAudioRoot.appendingPathComponent(Repo.qwen3Asr.name, isDirectory: true)
        try FileManager.default.createDirectory(at: stableQwen, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: legacyQwen, withIntermediateDirectories: true)

        LiveInterviewCopilotLocalModelStore.clearParakeetCache(
            for: .v3,
            baseDirectory: baseDirectory,
            fluidAudioModelsRoot: fluidAudioRoot
        )
        LiveInterviewCopilotLocalModelStore.clearQwen3Cache(
            variant: .f32,
            baseDirectory: baseDirectory,
            fluidAudioModelsRoot: fluidAudioRoot
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: stableParakeet.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyParakeet.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stableQwen.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyQwen.path))
    }
}

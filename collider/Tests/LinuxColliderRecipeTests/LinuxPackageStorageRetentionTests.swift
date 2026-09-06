import ColliderCore
import ColliderPersistence
import ColliderRuntime
import ColliderTesting
import Foundation
import LinuxColliderRecipe
import LinuxPackageAssembly
import LinuxPackageContracts
import SystemPackage
import Testing

@Test func retentionCollectsAGenerationTheStoreCannotServe() async throws {
    let fixture = try RetentionFixture()
    defer { fixture.remove() }
    let stored = try fixture.publishProduct()
    let active = try fixture.writeGeneration(
        products: [stored.identity.rawValue.description],
        archiveDigests: [stored.manifest.archiveDigest.description],
        seed: "a")
    let abandoned = try fixture.writeGeneration(
        products: [ArtifactDigest.sha256(Array("never-stored".utf8)).description],
        archiveDigests: [ArtifactDigest.sha256(Array("no-blob".utf8)).description],
        seed: "b")
    try fixture.activate(active)

    try await fixture.retain()

    // The abandoned generation names a product the store never received, so
    // nothing can roll back to it and retention reclaims it. The active one is
    // untouched, and so is the product it still needs.
    #expect(!fixture.exists(generation: abandoned))
    #expect(fixture.exists(generation: active))
    #expect(fixture.store.contains(stored.identity))
}

@Test func retentionRefusesAnActiveGenerationTheStoreCannotServe() async throws {
    let fixture = try RetentionFixture()
    defer { fixture.remove() }
    let stored = try fixture.publishProduct()
    let active = try fixture.writeGeneration(
        products: [ArtifactDigest.sha256(Array("never-stored".utf8)).description],
        archiveDigests: [ArtifactDigest.sha256(Array("no-blob".utf8)).description],
        seed: "a")
    try fixture.activate(active)

    await #expect(throws: (any Error).self) { try await fixture.retain() }

    // A rollback target may be reclaimed; what deployment currently resolves
    // may not, so the generation and the store are both left as they were.
    #expect(fixture.exists(generation: active))
    #expect(fixture.store.contains(stored.identity))
}

private struct RetentionFixture {
    let root: URL
    let packageRoot: FilePath
    let storeRoot: FilePath
    let store: LocalProductArtifactStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "collider-package-retention-\(UUID().uuidString)")
        packageRoot = FilePath(root.appendingPathComponent("packages/linux-arm64").path)
        storeRoot = FilePath(root.appendingPathComponent("product-store").path)
        store = LocalProductArtifactStore(root: storeRoot)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: packageRoot.appending("generations").string),
            withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func publishProduct() throws -> ProductArtifactEnvelope {
        let payload = root.appendingPathComponent("payload")
        let binary = payload.appendingPathComponent("bin/nucleus")
        try FileManager.default.createDirectory(
            at: binary.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("portable-binary".utf8).write(to: binary)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: binary.path)
        try Data("portable-library".utf8).write(
            to: payload.appendingPathComponent("libnucleus.so"))
        let archive = root.appendingPathComponent("nucleus.tar.zst")
        try Data("portable-archive".utf8).write(to: archive)
        let envelope = try ProductArtifactBuilder.createEnvelope(
            payloadRoot: FilePath(payload.path),
            archive: FilePath(archive.path),
            sourceClosure: ArtifactHasher.digest(bytes: Data("source".utf8)),
            submoduleClosures: [],
            producingTask: TaskID(rawValue: "fixture.product"),
            runnerPlatform: RunnerPlatform(
                operatingSystem: .macOS,
                architecture: .arm64),
            executionPlatform: .linuxARM64OCI,
            artifactTarget: .linuxARM64,
            toolchainIdentity: ArtifactHasher.digest(bytes: Data("toolchain".utf8)),
            swiftSDKIdentity: ArtifactHasher.digest(bytes: Data("swift-sdk".utf8)),
            nativeSDKIdentities: [],
            builderImageIdentity: ArtifactHasher.digest(bytes: Data("image".utf8)),
            buildConfiguration: .release,
            semanticBuildArguments: ["family=deb", "package=nucleus"],
            targetFilesystemRoots: [],
            executables: [
                ProductArtifactExecutableDeclaration(
                    relativePath: "bin/nucleus",
                    format: "ELF",
                    architecture: .arm64,
                    dynamicLibraries: ["libc.so.6", "libnucleus.so"])
            ],
            producerTrustDomain: .nucleusBuilder,
            requiredQualificationRoles: [.bundleIntegrity],
            provenance: try ProductArtifactProvenance(
                baseCommit: String(repeating: "b", count: 40),
                branch: "refs/heads/local-work",
                dirtyPaths: [],
                sourceAuthority: .localDevelopment))
        _ = try store.publish(
            envelope,
            payloadRoot: FilePath(payload.path),
            archive: FilePath(archive.path))
        return envelope
    }

    /// A cohort generation written the way the assembler leaves one on disk.
    ///
    /// Retention reads the published JSON rather than a value handed to it, so
    /// the fixture writes the file the assembler writes and lets the action
    /// decode it.
    func writeGeneration(
        products: [String],
        archiveDigests: [String],
        seed: String
    ) throws -> String {
        let name = "sha256-\(ArtifactHasher.digest(bytes: Data(seed.utf8)).hexadecimal)"
        let generation = packageRoot.appending("generations").appending(name)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: generation.string),
            withIntermediateDirectories: true)
        let entries = zip(products, archiveDigests).map { product, archive in
            """
            {"family":"debian","package":"nucleus","archive":"nucleus.deb",\
            "archiveDigest":"\(archive)","productArtifact":{"rawValue":"\(product)"}}
            """
        }
        try Data(
            """
            {"architecture":"arm64","products":[\(entries.joined(separator: ","))]}
            """.utf8
        ).write(
            to: URL(
                fileURLWithPath: generation.appending(
                    "linux-native-package-cohort.json"
                ).string))
        return name
    }

    func activate(_ generation: String) throws {
        try FileManager.default.createSymbolicLink(
            atPath: packageRoot.appending("current").string,
            withDestinationPath: "generations/\(generation)")
    }

    func exists(generation: String) -> Bool {
        FileManager.default.fileExists(
            atPath: packageRoot.appending("generations").appending(generation).string)
    }

    func retain() async throws {
        _ = try await recordActionExecution(
            try AnyColliderAction(
                LinuxPackageStorageRetentionAction(
                    lanes: [
                        LinuxPackageStorageRetentionLane(
                            architecture: .arm64,
                            packageRoot: packageRoot)
                    ],
                    productStoreRoot: storeRoot,
                    rollbackGenerationCount: 1)),
            files: ColliderRuntime().actionFileSystem())
    }
}

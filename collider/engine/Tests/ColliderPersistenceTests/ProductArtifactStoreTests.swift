import ColliderCore
import Foundation
import SystemPackage
import Testing

@testable import ColliderPersistence

@Test func productArtifactIdentityIsPortableAcrossPayloadAndArchiveLocations() throws {
    let directory = temporaryDirectory(named: "collider-product-portability")
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = try productFixture(in: directory.appendingPathComponent("first"))
    let second = try productFixture(in: directory.appendingPathComponent("second"))
    let provenance = try localProvenance()

    let firstEnvelope = try productEnvelope(
        fixture: first,
        provenance: provenance)
    let secondEnvelope = try productEnvelope(
        fixture: second,
        provenance: provenance)

    #expect(firstEnvelope.identity == secondEnvelope.identity)
    #expect(firstEnvelope.manifest == secondEnvelope.manifest)
    #expect(
        firstEnvelope.manifest.semanticBuildArguments == [
            "family=deb",
            "package=nucleus",
            "version=2026.09.05.1",
        ])
}

@Test func productArtifactIdentityTracksEverySemanticInputClass() throws {
    let directory = temporaryDirectory(named: "collider-product-inputs")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = try productFixture(in: directory)
    let provenance = try localProvenance()
    let baseline = try productEnvelope(
        fixture: fixture,
        provenance: provenance)
    let changedSource = try productEnvelope(
        fixture: fixture,
        provenance: provenance,
        sourceSeed: "changed-source")
    let changedToolchain = try productEnvelope(
        fixture: fixture,
        provenance: provenance,
        toolchainSeed: "changed-toolchain")
    let changedConfiguration = try productEnvelope(
        fixture: fixture,
        provenance: provenance,
        configuration: .debug)
    let changedTarget = try productEnvelope(
        fixture: fixture,
        provenance: provenance,
        artifactTarget: .linuxX86_64)
    let changedArgument = try productEnvelope(
        fixture: fixture,
        provenance: provenance,
        additionalArgument: "--lto=thin")
    let changedTargetRoot = try productEnvelope(
        fixture: fixture,
        provenance: provenance,
        targetFilesystemRoots: [FilePath("/opt/nucleus")])

    #expect(
        Set([
            baseline.identity,
            changedSource.identity,
            changedToolchain.identity,
            changedConfiguration.identity,
            changedTarget.identity,
            changedArgument.identity,
            changedTargetRoot.identity,
        ]).count == 7)
}

@Test(arguments: [
    "--source=/srv/someone/other-checkout",
    "--cache=/Library/Nucleus/Collider/cache",
    "--checkout=/Users/builder/nucleus",
    "--home=/home/builder",
    "--output=/tmp/product",
    "-I/opt/build/include",
    "file:///Users/builder/nucleus",
])
func productArtifactIdentityRejectsAbsoluteHostPaths(argument: String) throws {
    let directory = temporaryDirectory(named: "collider-product-host-path")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = try productFixture(in: directory)

    #expect(throws: PortableIdentityPathFailure.self) {
        _ = try productEnvelope(
            fixture: fixture,
            provenance: localProvenance(),
            additionalArgument: argument)
    }
}

@Test func productArtifactAllowsDeclaredTargetFilesystemSymlinkRoots() throws {
    let directory = temporaryDirectory(named: "collider-product-target-symlink")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = try productFixture(in: directory)
    let link = URL(fileURLWithPath: fixture.payload.appending("current").string)
    try FileManager.default.createSymbolicLink(
        atPath: link.path,
        withDestinationPath: "/opt/nucleus/generations/fixture")

    #expect(throws: PortableIdentityPathFailure.self) {
        _ = try productEnvelope(
            fixture: fixture,
            provenance: localProvenance())
    }
    let envelope = try productEnvelope(
        fixture: fixture,
        provenance: localProvenance(),
        targetFilesystemRoots: [FilePath("/opt/nucleus")])
    #expect(envelope.manifest.targetFilesystemRoots == ["/opt/nucleus"])
    #expect(
        envelope.manifest.files.first { $0.relativePath == "current" }?
            .symbolicLinkTarget == "/opt/nucleus/generations/fixture")
}

@Test func cleanQualifierConsumesOnlyStoredBundleAndEvidence() throws {
    let directory = temporaryDirectory(named: "collider-product-qualifier")
    defer { try? FileManager.default.removeItem(at: directory) }
    let producer = directory.appendingPathComponent("producer")
    let fixture = try productFixture(in: producer)
    let envelope = try productEnvelope(
        fixture: fixture,
        provenance: localProvenance(),
        requiredRoles: [.bundleIntegrity])
    let store = LocalProductArtifactStore(
        root: FilePath(directory.appendingPathComponent("artifact-store").path))
    let stored = try store.publish(
        envelope,
        payloadRoot: fixture.payload,
        archive: fixture.archive)

    try FileManager.default.removeItem(at: producer)
    #expect(
        try store.validatedArtifact(
            envelope.identity,
            provenance: envelope.provenanceIdentity
        ).envelope == envelope)

    let evidence = directory.appendingPathComponent("qualifier-evidence.json")
    try Data("{\"validated\":true}\n".utf8).write(to: evidence)
    let record = try store.qualify(
        envelope,
        role: .bundleIntegrity,
        capability: ProductArtifactQualificationCapability(
            runnerPlatform: .current,
            executionPlatform: .macOSARM64Native,
            physicalHardware: true,
            binaryTranslation: false),
        evidence: FilePath(evidence.path),
        qualifierTrustDomain: "fixture-integrity-qualifier")
    try store.validateRequiredQualifications(
        for: envelope,
        records: [record.identity])

    try Data("corrupted".utf8).write(
        to: URL(fileURLWithPath: stored.payloadRoot.appending("bin/nucleus").string))
    #expect(throws: ProductArtifactStoreFailure.self) {
        _ = try store.validatedArtifact(
            envelope.identity,
            provenance: envelope.provenanceIdentity)
    }
}

@Test func productArtifactEnvelopeValidationDoesNotRequireStorePublication() throws {
    let directory = temporaryDirectory(named: "collider-product-validation")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = try productFixture(in: directory)
    let envelope = try productEnvelope(
        fixture: fixture,
        provenance: localProvenance())

    try ProductArtifactBuilder.validateEnvelope(
        envelope,
        payloadRoot: fixture.payload,
        archive: fixture.archive)
    try Data("substituted".utf8).write(
        to: URL(
            fileURLWithPath: fixture.payload.appending("libnucleus.so").string))
    #expect(throws: ProductArtifactStoreFailure.self) {
        try ProductArtifactBuilder.validateEnvelope(
            envelope,
            payloadRoot: fixture.payload,
            archive: fixture.archive)
    }
}

@Test func productArtifactStoreRejectsArchiveSubstitution() throws {
    let directory = temporaryDirectory(named: "collider-product-substitution")
    defer { try? FileManager.default.removeItem(at: directory) }
    let firstFixture = try productFixture(
        in: directory.appendingPathComponent("first"),
        archiveContents: "first-archive")
    let secondFixture = try productFixture(
        in: directory.appendingPathComponent("second"),
        archiveContents: "second-archive")
    let provenance = try localProvenance()
    let first = try productEnvelope(
        fixture: firstFixture,
        provenance: provenance)
    let second = try productEnvelope(
        fixture: secondFixture,
        provenance: provenance)
    let store = LocalProductArtifactStore(
        root: FilePath(directory.appendingPathComponent("store").path))
    let firstStored = try store.publish(
        first,
        payloadRoot: firstFixture.payload,
        archive: firstFixture.archive)
    let secondStored = try store.publish(
        second,
        payloadRoot: secondFixture.payload,
        archive: secondFixture.archive)

    try FileManager.default.removeItem(atPath: firstStored.archive.string)
    try FileManager.default.copyItem(
        atPath: secondStored.archive.string,
        toPath: firstStored.archive.string)
    #expect(throws: ProductArtifactStoreFailure.self) {
        _ = try store.validatedArtifact(
            first.identity,
            provenance: first.provenanceIdentity)
    }
}

@Test func productArtifactStoreReusesValidEnvelopeWithoutWriting() throws {
    let directory = temporaryDirectory(named: "collider-product-reuse")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = try productFixture(in: directory.appendingPathComponent("producer"))
    let envelope = try productEnvelope(
        fixture: fixture,
        provenance: localProvenance())
    let storeRoot = directory.appendingPathComponent("store")
    let store = LocalProductArtifactStore(root: FilePath(storeRoot.path))

    let first = try store.publishIfNeeded(
        envelope,
        payloadRoot: fixture.payload,
        archive: fixture.archive)
    #expect(first.disposition == .publishedArtifact)
    let firstSnapshot = try filesystemSnapshot(at: storeRoot)

    try Data("mutated-producer-binary".utf8).write(
        to: URL(fileURLWithPath: fixture.payload.appending("bin/nucleus").string))
    try Data("mutated-producer-archive".utf8).write(
        to: URL(fileURLWithPath: fixture.archive.string))
    let second = try store.publishIfNeeded(
        envelope,
        payloadRoot: fixture.payload,
        archive: fixture.archive)

    #expect(second.disposition == .reused)
    #expect(try filesystemSnapshot(at: storeRoot) == firstSnapshot)
    #expect(
        try store.validatedArtifact(
            envelope.identity,
            provenance: envelope.provenanceIdentity
        ).envelope == envelope)
}

@Test func productArtifactStoreInterruptedCandidatePreservesPriorProducts() throws {
    let directory = temporaryDirectory(named: "collider-product-interruption")
    defer { try? FileManager.default.removeItem(at: directory) }
    let firstFixture = try productFixture(
        in: directory.appendingPathComponent("first"),
        archiveContents: "first-archive")
    let secondFixture = try productFixture(
        in: directory.appendingPathComponent("second"),
        archiveContents: "second-archive")
    let provenance = try localProvenance()
    let first = try productEnvelope(
        fixture: firstFixture,
        provenance: provenance)
    let second = try productEnvelope(
        fixture: secondFixture,
        provenance: provenance)
    let storeRoot = FilePath(directory.appendingPathComponent("store").path)
    _ = try LocalProductArtifactStore(root: storeRoot).publish(
        first,
        payloadRoot: firstFixture.payload,
        archive: firstFixture.archive)
    let interruptedStore = LocalProductArtifactStore(
        root: storeRoot,
        publicationCheckpoint: { checkpoint in
            guard checkpoint == .productCandidateValidated else { return }
            throw ProductPublicationFixtureInterruption()
        })

    #expect(throws: ProductPublicationFixtureInterruption.self) {
        _ = try interruptedStore.publish(
            second,
            payloadRoot: secondFixture.payload,
            archive: secondFixture.archive)
    }

    #expect(
        try interruptedStore.validatedArtifact(
            first.identity,
            provenance: first.provenanceIdentity
        ).envelope == first)
    #expect(
        !FileManager.default.fileExists(
            atPath: storeRoot.appending("products").appending(
                second.identity.rawValue.hexadecimal
            ).string))
    let productEntries = try FileManager.default.contentsOfDirectory(
        atPath: storeRoot.appending("products").string)
    #expect(!productEntries.contains { $0.hasPrefix(".candidate-") })
}

@Test func productArtifactStoreDeduplicatesArchiveBlobsWithoutHardLinks() throws {
    let directory = temporaryDirectory(named: "collider-product-archive-blobs")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = try productFixture(in: directory.appendingPathComponent("producer"))
    let provenance = try localProvenance()
    let first = try productEnvelope(
        fixture: fixture,
        provenance: provenance)
    let second = try productEnvelope(
        fixture: fixture,
        provenance: provenance,
        additionalArgument: "--cohort=second")
    let storeRoot = directory.appendingPathComponent("store")
    let store = LocalProductArtifactStore(root: FilePath(storeRoot.path))
    let firstStored = try store.publish(
        first,
        payloadRoot: fixture.payload,
        archive: fixture.archive)
    let secondStored = try store.publish(
        second,
        payloadRoot: fixture.payload,
        archive: fixture.archive)

    let blobs = try FileManager.default.contentsOfDirectory(
        atPath: storeRoot.appendingPathComponent("archives").path)
    #expect(blobs == [first.manifest.archiveDigest.hexadecimal])
    let firstInode = try #require(
        FileManager.default.attributesOfItem(
            atPath: firstStored.archive.string)[.systemFileNumber] as? NSNumber)
    let secondInode = try #require(
        FileManager.default.attributesOfItem(
            atPath: secondStored.archive.string)[.systemFileNumber] as? NSNumber)
    #expect(firstInode != secondInode)
    #expect(
        try Data(contentsOf: URL(fileURLWithPath: firstStored.archive.string))
            == Data(contentsOf: URL(fileURLWithPath: secondStored.archive.string)))
}

@Test func productArtifactStorePrunesOnlyUnreferencedKnownObjects() throws {
    let directory = temporaryDirectory(named: "collider-product-pruning")
    defer { try? FileManager.default.removeItem(at: directory) }
    let firstFixture = try productFixture(
        in: directory.appendingPathComponent("first"),
        archiveContents: "first-archive")
    let secondFixture = try productFixture(
        in: directory.appendingPathComponent("second"),
        archiveContents: "second-archive")
    let provenance = try localProvenance()
    let first = try productEnvelope(
        fixture: firstFixture,
        provenance: provenance)
    let second = try productEnvelope(
        fixture: secondFixture,
        provenance: provenance)
    let storeRoot = directory.appendingPathComponent("store")
    let store = LocalProductArtifactStore(root: FilePath(storeRoot.path))
    _ = try store.publish(
        first,
        payloadRoot: firstFixture.payload,
        archive: firstFixture.archive)
    _ = try store.publish(
        second,
        payloadRoot: secondFixture.payload,
        archive: secondFixture.archive)
    let unknownProduct = storeRoot.appendingPathComponent("products/user-data")
    let unknownArchive = storeRoot.appendingPathComponent("archives/user-data")
    try FileManager.default.createDirectory(
        at: unknownProduct, withIntermediateDirectories: true)
    try Data("unknown".utf8).write(to: unknownArchive)

    let result = try store.prune(retaining: [first.identity])

    #expect(result.retainedProducts == 1)
    #expect(result.retainedArchives == 1)
    #expect(result.removedProducts == 1)
    #expect(result.removedArchives == 1)
    #expect(
        FileManager.default.fileExists(
            atPath: storeRoot.appendingPathComponent(
                "products/\(first.identity.rawValue.hexadecimal)"
            ).path))
    #expect(
        !FileManager.default.fileExists(
            atPath: storeRoot.appendingPathComponent(
                "products/\(second.identity.rawValue.hexadecimal)"
            ).path))
    #expect(FileManager.default.fileExists(atPath: unknownProduct.path))
    #expect(FileManager.default.fileExists(atPath: unknownArchive.path))
}

@Test func productArtifactStoreNamesARetainedArtifactItNoLongerHolds() throws {
    let directory = temporaryDirectory(named: "collider-product-missing-retained")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = try productFixture(
        in: directory.appendingPathComponent("product"),
        archiveContents: "retained-archive")
    let provenance = try localProvenance()
    let envelope = try productEnvelope(fixture: fixture, provenance: provenance)
    let storeRoot = directory.appendingPathComponent("store")
    let store = LocalProductArtifactStore(root: FilePath(storeRoot.path))
    _ = try store.publish(
        envelope,
        payloadRoot: fixture.payload,
        archive: fixture.archive)
    let name = envelope.identity.rawValue.hexadecimal
    #expect(store.contains(envelope.identity))

    try FileManager.default.removeItem(
        at: storeRoot.appendingPathComponent("products/\(name)"))

    #expect(!store.contains(envelope.identity))
    do {
        _ = try store.prune(retaining: [envelope.identity])
        Issue.record("pruning accepted a retained artifact the store lost")
    } catch let error as ProductArtifactStoreFailure {
        #expect(error.description.contains("retained artifact is missing"))
        #expect(error.description.contains(name))
    }
}

@Test func productArtifactStoreNamesARetainedArchiveBlobItNoLongerHolds() throws {
    let directory = temporaryDirectory(named: "collider-product-missing-blob")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = try productFixture(
        in: directory.appendingPathComponent("product"),
        archiveContents: "retained-archive")
    let provenance = try localProvenance()
    let envelope = try productEnvelope(fixture: fixture, provenance: provenance)
    let storeRoot = directory.appendingPathComponent("store")
    let store = LocalProductArtifactStore(root: FilePath(storeRoot.path))
    _ = try store.publish(
        envelope,
        payloadRoot: fixture.payload,
        archive: fixture.archive)
    let blob = envelope.manifest.archiveDigest.hexadecimal

    try FileManager.default.removeItem(
        at: storeRoot.appendingPathComponent("archives/\(blob)"))

    do {
        _ = try store.prune(retaining: [envelope.identity])
        Issue.record("pruning accepted a retained blob the store lost")
    } catch let error as ProductArtifactStoreFailure {
        #expect(error.description.contains("retained archive blob is missing"))
    }
}

@Test func nativeQualificationRejectsCrossTranslatedAndVirtualCapabilities() throws {
    let crossBuild = ProductArtifactQualificationCapability(
        runnerPlatform: .current,
        executionPlatform: .linuxARM64OCI,
        physicalHardware: false,
        binaryTranslation: false)
    #expect(throws: ProductArtifactContractFailure.self) {
        try crossBuild.validate(for: .nativeLinuxKernel)
    }

    let translated = ProductArtifactQualificationCapability(
        runnerPlatform: RunnerPlatform(
            operatingSystem: .linux,
            architecture: .arm64),
        executionPlatform: .linuxARM64Native,
        physicalHardware: true,
        binaryTranslation: true)
    #expect(throws: ProductArtifactContractFailure.self) {
        try translated.validate(for: .nativeLinuxPerformance)
    }

    let virtual = ProductArtifactQualificationCapability(
        runnerPlatform: RunnerPlatform(
            operatingSystem: .linux,
            architecture: .arm64),
        executionPlatform: .linuxARM64Native,
        physicalHardware: false,
        binaryTranslation: false)
    #expect(throws: ProductArtifactContractFailure.self) {
        try virtual.validate(for: .physicalGPU)
    }
    try virtual.validate(for: .nativeLinuxKernel)
    #expect(throws: ProductArtifactContractFailure.self) {
        try virtual.validate(
            for: .nativeLinuxKernel,
            artifactTarget: .linuxX86_64)
    }
}

@Test func protectedMainAndLocalProvenanceRemainDistinctAuthorities() throws {
    let directory = temporaryDirectory(named: "collider-product-authority")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = try productFixture(in: directory.appendingPathComponent("producer"))
    let local = try productEnvelope(
        fixture: fixture,
        provenance: localProvenance(),
        requiredRoles: [.release])
    let protectedMain = try productEnvelope(
        fixture: fixture,
        provenance: ProductArtifactProvenance(
            baseCommit: String(repeating: "a", count: 40),
            branch: "refs/heads/main",
            dirtyPaths: [],
            sourceAuthority: .protectedMain),
        requiredRoles: [.release])
    let locallyProducedProtectedMain = try productEnvelope(
        fixture: fixture,
        provenance: protectedMain.provenance,
        requiredRoles: [.release],
        producerTrustDomain: .localDeveloper)
    #expect(local.identity == protectedMain.identity)
    #expect(local.provenanceIdentity != protectedMain.provenanceIdentity)

    let store = LocalProductArtifactStore(
        root: FilePath(directory.appendingPathComponent("store").path))
    _ = try store.publish(
        local,
        payloadRoot: fixture.payload,
        archive: fixture.archive)
    _ = try store.publish(
        protectedMain,
        payloadRoot: fixture.payload,
        archive: fixture.archive)
    _ = try store.publish(
        locallyProducedProtectedMain,
        payloadRoot: fixture.payload,
        archive: fixture.archive)
    _ = try store.validatedArtifact(
        local.identity,
        provenance: local.provenanceIdentity)
    _ = try store.validatedArtifact(
        protectedMain.identity,
        provenance: protectedMain.provenanceIdentity)

    let evidence = directory.appendingPathComponent("native-evidence.json")
    try Data("{\"native\":true}\n".utf8).write(to: evidence)
    let capability = ProductArtifactQualificationCapability(
        runnerPlatform: RunnerPlatform(
            operatingSystem: .linux,
            architecture: .arm64),
        executionPlatform: .linuxARM64Native,
        physicalHardware: true,
        binaryTranslation: false)
    #expect(throws: ProductArtifactStoreFailure.self) {
        _ = try store.qualify(
            local,
            role: .release,
            capability: capability,
            evidence: FilePath(evidence.path),
            qualifierTrustDomain: "fixture-native-qualifier")
    }
    #expect(throws: ProductArtifactStoreFailure.self) {
        _ = try store.qualify(
            locallyProducedProtectedMain,
            role: .release,
            capability: capability,
            evidence: FilePath(evidence.path),
            qualifierTrustDomain: "fixture-native-qualifier")
    }
    let record = try store.qualify(
        protectedMain,
        role: .release,
        capability: capability,
        evidence: FilePath(evidence.path),
        qualifierTrustDomain: "fixture-native-qualifier")
    try store.validateRequiredQualifications(
        for: protectedMain,
        records: [record.identity])
}

@Test func protectedMainProvenanceRequiresAFullLowercaseCommit() {
    for commit in ["main", String(repeating: "A", count: 40)] {
        #expect(throws: ProductArtifactContractFailure.self) {
            try ProductArtifactProvenance(
                baseCommit: commit,
                branch: "refs/heads/main",
                dirtyPaths: [],
                sourceAuthority: .protectedMain)
        }
    }
}

private struct ProductFixture {
    let root: URL
    let payload: FilePath
    let archive: FilePath
}

private struct ProductPublicationFixtureInterruption: Error {}

private struct FilesystemEntrySnapshot: Equatable {
    let relativePath: String
    let fileNumber: NSNumber?
    let modificationDate: Date?
    let size: NSNumber?
}

private func filesystemSnapshot(at root: URL) throws -> [FilesystemEntrySnapshot] {
    let fileManager = FileManager.default
    let entries = try #require(
        fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: nil))
    var snapshot: [FilesystemEntrySnapshot] = []
    for case let entry as URL in entries {
        let attributes = try fileManager.attributesOfItem(atPath: entry.path)
        snapshot.append(
            FilesystemEntrySnapshot(
                relativePath: String(entry.path.dropFirst(root.path.count + 1)),
                fileNumber: attributes[.systemFileNumber] as? NSNumber,
                modificationDate: attributes[.modificationDate] as? Date,
                size: attributes[.size] as? NSNumber))
    }
    return snapshot.sorted { $0.relativePath < $1.relativePath }
}

private func temporaryDirectory(named name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
        "\(name)-\(UUID().uuidString)")
}

private func productFixture(
    in root: URL,
    archiveContents: String = "portable-archive"
) throws -> ProductFixture {
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
    try Data(archiveContents.utf8).write(to: archive)
    return ProductFixture(
        root: root,
        payload: FilePath(payload.path),
        archive: FilePath(archive.path))
}

private func localProvenance() throws -> ProductArtifactProvenance {
    try ProductArtifactProvenance(
        baseCommit: String(repeating: "b", count: 40),
        branch: "refs/heads/local-work",
        dirtyPaths: ["Sources/Changed.swift"],
        sourceAuthority: .localDevelopment)
}

private func productEnvelope(
    fixture: ProductFixture,
    provenance: ProductArtifactProvenance,
    sourceSeed: String = "source",
    toolchainSeed: String = "toolchain",
    configuration: SwiftBuildConfiguration = .release,
    artifactTarget: ArtifactTarget = .linuxARM64,
    additionalArgument: String? = nil,
    targetFilesystemRoots: [FilePath] = [],
    requiredRoles: [ProductArtifactQualificationRole] = [.bundleIntegrity],
    producerTrustDomain: ProductArtifactProducerTrustDomain = .nucleusBuilder
) throws -> ProductArtifactEnvelope {
    var arguments = [
        "family=deb",
        "package=nucleus",
        "version=2026.09.05.1",
    ]
    if let additionalArgument {
        arguments.append(additionalArgument)
    }
    return try ProductArtifactBuilder.createEnvelope(
        payloadRoot: fixture.payload,
        archive: fixture.archive,
        sourceClosure: digest(sourceSeed),
        submoduleClosures: [
            ProductArtifactSourceClosure(
                relativePath: "third-party/example",
                digest: digest("submodule"))
        ],
        producingTask: TaskID(rawValue: "fixture.product"),
        runnerPlatform: RunnerPlatform(
            operatingSystem: .macOS,
            architecture: .arm64),
        executionPlatform: .linuxARM64OCI,
        artifactTarget: artifactTarget,
        toolchainIdentity: digest(toolchainSeed),
        swiftSDKIdentity: digest("swift-sdk"),
        nativeSDKIdentities: [
            ProductArtifactNamedIdentity(
                name: "render",
                digest: digest("render-sdk"))
        ],
        builderImageIdentity: digest("builder-image"),
        buildConfiguration: configuration,
        semanticBuildArguments: arguments,
        targetFilesystemRoots: targetFilesystemRoots,
        executables: [
            ProductArtifactExecutableDeclaration(
                relativePath: "bin/nucleus",
                format: "ELF",
                architecture: artifactTarget.architecture,
                dynamicLibraries: ["libc.so.6", "libnucleus.so"])
        ],
        producerTrustDomain: producerTrustDomain,
        requiredQualificationRoles: requiredRoles,
        provenance: provenance)
}

private func digest(_ value: String) -> ArtifactDigest {
    ArtifactHasher.digest(bytes: Data(value.utf8))
}

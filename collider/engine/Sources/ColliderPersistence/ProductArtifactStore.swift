import ColliderCore
import ColliderPlatformC
import Foundation
import SystemPackage

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum ProductArtifactBuilder {
    public static func createEnvelope(
        payloadRoot: FilePath,
        archive: FilePath,
        sourceClosure: ArtifactDigest,
        submoduleClosures: [ProductArtifactSourceClosure],
        producingTask: TaskID,
        runnerPlatform: RunnerPlatform,
        executionPlatform: ExecutionPlatform,
        artifactTarget: ArtifactTarget,
        toolchainIdentity: ArtifactDigest,
        swiftSDKIdentity: ArtifactDigest? = nil,
        nativeSDKIdentities: [ProductArtifactNamedIdentity] = [],
        builderImageIdentity: ArtifactDigest? = nil,
        buildConfiguration: SwiftBuildConfiguration,
        semanticBuildArguments: [String],
        targetFilesystemRoots: [FilePath] = [],
        executables: [ProductArtifactExecutableDeclaration],
        producerTrustDomain: ProductArtifactProducerTrustDomain,
        requiredQualificationRoles: [ProductArtifactQualificationRole],
        provenance: ProductArtifactProvenance
    ) throws -> ProductArtifactEnvelope {
        let inspection = try inspectPayload(payloadRoot)
        let filesByPath = Dictionary(
            uniqueKeysWithValues: inspection.files.map { ($0.relativePath, $0) })
        let executableRecords = try executables.map { declaration in
            guard
                let file = filesByPath[declaration.relativePath],
                file.kind == .regular,
                file.ownerExecutable,
                let digest = file.digest
            else {
                throw ProductArtifactStoreFailure(
                    "declared executable is not an executable regular file: "
                        + declaration.relativePath)
            }
            return ProductArtifactExecutable(
                relativePath: declaration.relativePath,
                digest: digest,
                format: declaration.format,
                architecture: declaration.architecture,
                dynamicLibraries: declaration.dynamicLibraries)
        }
        let manifest = try ProductArtifactManifest(
            sourceClosure: sourceClosure,
            submoduleClosures: submoduleClosures,
            producingTask: producingTask,
            runnerPlatform: runnerPlatform,
            executionPlatform: executionPlatform,
            artifactTarget: artifactTarget,
            toolchainIdentity: toolchainIdentity,
            swiftSDKIdentity: swiftSDKIdentity,
            nativeSDKIdentities: nativeSDKIdentities,
            builderImageIdentity: builderImageIdentity,
            buildConfiguration: buildConfiguration,
            semanticBuildArguments: semanticBuildArguments,
            targetFilesystemRoots: targetFilesystemRoots.map(\.string),
            archiveDigest: try ArtifactHasher.digest(file: archive),
            treeDigest: inspection.treeDigest,
            files: inspection.files,
            executables: executableRecords,
            producerTrustDomain: producerTrustDomain,
            requiredQualificationRoles: requiredQualificationRoles)
        return try ProductArtifactEnvelope(
            manifest: manifest,
            provenance: provenance)
    }

    public static func validateEnvelope(
        _ envelope: ProductArtifactEnvelope,
        payloadRoot: FilePath,
        archive: FilePath
    ) throws {
        try validateProductArtifact(
            envelope: envelope,
            payloadRoot: payloadRoot,
            archive: archive)
    }
}

public struct StoredProductArtifact: Sendable {
    public let envelope: ProductArtifactEnvelope
    public let payloadRoot: FilePath
    public let archive: FilePath

    public init(
        envelope: ProductArtifactEnvelope,
        payloadRoot: FilePath,
        archive: FilePath
    ) {
        self.envelope = envelope
        self.payloadRoot = payloadRoot
        self.archive = archive
    }
}

public struct ProductArtifactPublication: Sendable {
    public enum Disposition: Equatable, Sendable {
        case reused
        case publishedProvenance
        case publishedArtifact
    }

    public let artifact: StoredProductArtifact
    public let disposition: Disposition

    public init(
        artifact: StoredProductArtifact,
        disposition: Disposition
    ) {
        self.artifact = artifact
        self.disposition = disposition
    }
}

enum ProductArtifactPublicationCheckpoint: Sendable {
    case productCandidateValidated
}

public struct LocalProductArtifactStore: Sendable {
    public let root: FilePath
    private let publicationCheckpoint:
        @Sendable (ProductArtifactPublicationCheckpoint) throws -> Void

    public init(root: FilePath) {
        precondition(root.isAbsolute && root.isLexicallyNormal)
        self.root = root
        publicationCheckpoint = { _ in }
    }

    init(
        root: FilePath,
        publicationCheckpoint:
            @escaping @Sendable (ProductArtifactPublicationCheckpoint) throws -> Void
    ) {
        precondition(root.isAbsolute && root.isLexicallyNormal)
        self.root = root
        self.publicationCheckpoint = publicationCheckpoint
    }

    public func publish(
        _ envelope: ProductArtifactEnvelope,
        payloadRoot: FilePath,
        archive: FilePath
    ) throws -> StoredProductArtifact {
        try publishIfNeeded(
            envelope,
            payloadRoot: payloadRoot,
            archive: archive
        ).artifact
    }

    public func publishIfNeeded(
        _ envelope: ProductArtifactEnvelope,
        payloadRoot: FilePath,
        archive: FilePath
    ) throws -> ProductArtifactPublication {
        let destination = artifactDirectory(envelope.identity)
        if FileManager.default.fileExists(atPath: destination.string) {
            try validateStoredManifest(
                envelope.manifest,
                identity: envelope.identity,
                directory: destination)
            let existingProvenance = provenancePath(
                envelope.provenanceIdentity,
                in: destination)
            if FileManager.default.fileExists(atPath: existingProvenance.string) {
                let stored = try validatedArtifact(
                    envelope.identity,
                    provenance: envelope.provenanceIdentity)
                guard stored.envelope == envelope else {
                    throw ProductArtifactStoreFailure(
                        "artifact identity already exists with a different envelope")
                }
                return ProductArtifactPublication(
                    artifact: stored,
                    disposition: .reused)
            }
            try publishProvenance(envelope.provenance, in: destination)
            let stored = try validatedArtifact(
                envelope.identity,
                provenance: envelope.provenanceIdentity)
            guard stored.envelope == envelope else {
                throw ProductArtifactStoreFailure(
                    "published artifact provenance does not match its envelope")
            }
            return ProductArtifactPublication(
                artifact: stored,
                disposition: .publishedProvenance)
        }

        try validate(
            envelope: envelope,
            payloadRoot: payloadRoot,
            archive: archive)
        try FileManager.default.createDirectory(
            atPath: root.appending("products").string,
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: root.appending("archives").string,
            withIntermediateDirectories: true)
        let candidate = root.appending("products").appending(
            ".candidate-\(envelope.identity.rawValue.hexadecimal)-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: candidate.string) }
        try FileManager.default.createDirectory(
            atPath: candidate.string,
            withIntermediateDirectories: false)
        let candidatePayload = candidate.appending("payload")
        let candidateArchive = candidate.appending("product.archive")
        try cloneTree(from: payloadRoot, to: candidatePayload)
        let archiveBlob = try publishArchiveBlob(
            archive,
            digest: envelope.manifest.archiveDigest)
        try cloneRegularFile(from: archiveBlob, to: candidateArchive)
        try DurableFile.writeJSON(
            envelope.manifest,
            to: candidate.appending("manifest.json"))
        try publishProvenance(envelope.provenance, in: candidate)
        try validate(
            envelope: envelope,
            payloadRoot: candidatePayload,
            archive: candidateArchive)
        try publicationCheckpoint(.productCandidateValidated)
        try FileManager.default.moveItem(
            atPath: candidate.string,
            toPath: destination.string)
        try DurableFile.synchronizeDirectory(root.appending("products"))
        return ProductArtifactPublication(
            artifact: StoredProductArtifact(
                envelope: envelope,
                payloadRoot: destination.appending("payload"),
                archive: destination.appending("product.archive")),
            disposition: .publishedArtifact)
    }

    public func validatedArtifact(
        _ identity: ProductArtifactID,
        provenance provenanceIdentity: ProductArtifactProvenanceID
    ) throws -> StoredProductArtifact {
        let directory = artifactDirectory(identity)
        let manifest: ProductArtifactManifest
        do {
            manifest = try JSONDecoder().decode(
                ProductArtifactManifest.self,
                from: Data(
                    contentsOf: URL(
                        fileURLWithPath: directory.appending("manifest.json").string)))
        } catch {
            throw ProductArtifactStoreFailure(
                "could not decode artifact manifest \(identity): \(error)")
        }
        guard manifest.identity == identity else {
            throw ProductArtifactStoreFailure(
                "stored artifact was substituted for \(identity)")
        }
        let provenance: ProductArtifactProvenance
        do {
            provenance = try JSONDecoder().decode(
                ProductArtifactProvenance.self,
                from: Data(
                    contentsOf: URL(
                        fileURLWithPath: provenancePath(
                            provenanceIdentity,
                            in: directory
                        ).string)))
        } catch {
            throw ProductArtifactStoreFailure(
                "could not decode artifact provenance \(provenanceIdentity): \(error)")
        }
        guard provenance.identity == provenanceIdentity else {
            throw ProductArtifactStoreFailure(
                "stored provenance was substituted for \(provenanceIdentity)")
        }
        let envelope = try ProductArtifactEnvelope(
            manifest: manifest,
            provenance: provenance)
        let stored = StoredProductArtifact(
            envelope: envelope,
            payloadRoot: directory.appending("payload"),
            archive: directory.appending("product.archive"))
        try validate(
            envelope: envelope,
            payloadRoot: stored.payloadRoot,
            archive: stored.archive)
        return stored
    }

    /// Whether the store holds an artifact at all, without reading it.
    ///
    /// A publication writes the generation naming its products before it
    /// writes the products themselves, so a run interrupted between the two
    /// leaves a generation the store cannot serve. Deciding whether that
    /// generation is still a rollback target is a question about presence, and
    /// answering it with `validatedArtifact` would conflate the artifact never
    /// having been written with its having been corrupted after it was.
    public func contains(_ identity: ProductArtifactID) -> Bool {
        (try? artifactDirectory(identity).stat(followTargetSymlink: false))?
            .type == .directory
    }

    public func qualify(
        _ envelope: ProductArtifactEnvelope,
        role: ProductArtifactQualificationRole,
        capability: ProductArtifactQualificationCapability,
        evidence: FilePath,
        qualifierTrustDomain: String
    ) throws -> ProductArtifactQualificationRecord {
        let stored = try validatedArtifact(
            envelope.identity,
            provenance: envelope.provenanceIdentity)
        guard stored.envelope == envelope else {
            throw ProductArtifactStoreFailure(
                "qualification requested with a substituted artifact envelope")
        }
        guard
            role == .bundleIntegrity
                || stored.envelope.manifest.requiredQualificationRoles.contains(role)
        else {
            throw ProductArtifactStoreFailure(
                "artifact does not declare qualification role \(role.rawValue)")
        }
        if role == .release {
            guard stored.envelope.provenance.sourceAuthority == .protectedMain else {
                throw ProductArtifactStoreFailure(
                    "release qualification requires protected-main provenance")
            }
            guard
                stored.envelope.manifest.producerTrustDomain == .nucleusBuilder
            else {
                throw ProductArtifactStoreFailure(
                    "release qualification requires nucleus-builder production")
            }
        }
        let record = try ProductArtifactQualificationRecord(
            envelope: envelope,
            role: role,
            capability: capability,
            evidenceDigest: ArtifactHasher.digest(file: evidence),
            qualifierTrustDomain: qualifierTrustDomain)
        let directory = qualificationDirectory(
            record.identity,
            artifact: envelope.identity,
            provenance: envelope.provenanceIdentity)
        if FileManager.default.fileExists(atPath: directory.string) {
            try validateQualification(
                record.identity,
                envelope: envelope)
            return record
        }
        let parent = directory.removingLastComponent()
        try FileManager.default.createDirectory(
            atPath: parent.string,
            withIntermediateDirectories: true)
        let candidate = parent.appending(
            ".candidate-\(record.identity.rawValue.hexadecimal)-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: candidate.string) }
        try FileManager.default.createDirectory(
            atPath: candidate.string,
            withIntermediateDirectories: false)
        try FileManager.default.copyItem(
            atPath: evidence.string,
            toPath: candidate.appending("evidence").string)
        try DurableFile.writeJSON(
            record,
            to: candidate.appending("record.json"))
        try validateQualification(
            record,
            evidence: candidate.appending("evidence"),
            expectedEnvelope: envelope)
        try FileManager.default.moveItem(
            atPath: candidate.string,
            toPath: directory.string)
        try DurableFile.synchronizeDirectory(parent)
        return record
    }

    public func validateQualification(
        _ recordID: ProductArtifactQualificationRecordID,
        envelope: ProductArtifactEnvelope
    ) throws {
        _ = try validatedArtifact(
            envelope.identity,
            provenance: envelope.provenanceIdentity)
        let directory = qualificationDirectory(
            recordID,
            artifact: envelope.identity,
            provenance: envelope.provenanceIdentity)
        let record: ProductArtifactQualificationRecord
        do {
            record = try JSONDecoder().decode(
                ProductArtifactQualificationRecord.self,
                from: Data(
                    contentsOf: URL(
                        fileURLWithPath: directory.appending("record.json").string)))
        } catch {
            throw ProductArtifactStoreFailure(
                "could not decode qualification record \(recordID): \(error)")
        }
        guard record.identity == recordID else {
            throw ProductArtifactStoreFailure(
                "stored qualification record was substituted for \(recordID)")
        }
        try validateQualification(
            record,
            evidence: directory.appending("evidence"),
            expectedEnvelope: envelope)
    }

    public func validateRequiredQualifications(
        for envelope: ProductArtifactEnvelope,
        records: [ProductArtifactQualificationRecordID]
    ) throws {
        let artifact = try validatedArtifact(
            envelope.identity,
            provenance: envelope.provenanceIdentity)
        var roles: Set<ProductArtifactQualificationRole> = []
        for recordID in records {
            try validateQualification(recordID, envelope: envelope)
            let directory = qualificationDirectory(
                recordID,
                artifact: envelope.identity,
                provenance: envelope.provenanceIdentity)
            let record = try JSONDecoder().decode(
                ProductArtifactQualificationRecord.self,
                from: Data(
                    contentsOf: URL(
                        fileURLWithPath: directory.appending("record.json").string)))
            roles.insert(record.role)
        }
        let missing = Set(artifact.envelope.manifest.requiredQualificationRoles)
            .subtracting(roles)
        guard missing.isEmpty else {
            throw ProductArtifactStoreFailure(
                "artifact is missing qualification roles: "
                    + missing.map(\.rawValue).sorted().joined(separator: ", "))
        }
    }

    @discardableResult
    public func prune(
        retaining retainedArtifacts: Set<ProductArtifactID>
    ) throws -> ProductArtifactStorePruneResult {
        let products = root.appending("products")
        let archives = root.appending("archives")
        let qualifications = root.appending("qualifications")
        let retainedNames = Set(
            retainedArtifacts.map { $0.rawValue.hexadecimal })
        var retainedArchiveNames: Set<String> = []

        // An absent entry is the case these guards exist to report, so neither
        // may reach it through a throwing `stat`. A caller naming an artifact
        // the store does not hold otherwise gets a bare `No such file or
        // directory`, which says neither which artifact was wanted nor that a
        // retained one was what went missing.
        for name in retainedNames.sorted() {
            let directory = products.appending(name)
            guard
                (try? directory.stat(followTargetSymlink: false))?.type
                    == .directory
            else {
                throw ProductArtifactStoreFailure(
                    "retained artifact is missing: \(name)")
            }
            let manifest = try decodeManifest(in: directory, identity: name)
            retainedArchiveNames.insert(manifest.archiveDigest.hexadecimal)
            let archive = archives.appending(manifest.archiveDigest.hexadecimal)
            guard
                (try? archive.stat(followTargetSymlink: false))?.type == .regular
            else {
                throw ProductArtifactStoreFailure(
                    "retained archive blob is missing: \(manifest.archiveDigest)")
            }
        }

        var removedProducts = 0
        var removedArchives = 0
        var removedCandidates = 0
        for entry in try directoryEntries(products) {
            let name = entry.lastComponent?.string ?? ""
            if isStoreCandidate(name) {
                try FileManager.default.removeItem(atPath: entry.string)
                removedCandidates += 1
            } else if isLowercaseSHA256(name), !retainedNames.contains(name) {
                let metadata = try entry.stat(followTargetSymlink: false)
                guard metadata.type == .directory else { continue }
                try FileManager.default.removeItem(atPath: entry.string)
                let qualification = qualifications.appending(name)
                if let qualificationMetadata = try? qualification.stat(
                    followTargetSymlink: false),
                    qualificationMetadata.type == .directory
                {
                    try FileManager.default.removeItem(atPath: qualification.string)
                }
                removedProducts += 1
            }
        }
        for entry in try directoryEntries(archives) {
            let name = entry.lastComponent?.string ?? ""
            if isStoreCandidate(name) {
                try FileManager.default.removeItem(atPath: entry.string)
                removedCandidates += 1
            } else if isLowercaseSHA256(name),
                !retainedArchiveNames.contains(name)
            {
                let metadata = try entry.stat(followTargetSymlink: false)
                guard metadata.type == .regular else { continue }
                try FileManager.default.removeItem(atPath: entry.string)
                removedArchives += 1
            }
        }
        for directory in [products, archives, qualifications] {
            if (try? directory.stat(followTargetSymlink: false).type) == .directory {
                try DurableFile.synchronizeDirectory(directory)
            }
        }
        return ProductArtifactStorePruneResult(
            retainedProducts: retainedNames.count,
            retainedArchives: retainedArchiveNames.count,
            removedProducts: removedProducts,
            removedArchives: removedArchives,
            removedCandidates: removedCandidates)
    }

    private func validate(
        envelope: ProductArtifactEnvelope,
        payloadRoot: FilePath,
        archive: FilePath
    ) throws {
        try validateProductArtifact(
            envelope: envelope,
            payloadRoot: payloadRoot,
            archive: archive)
    }

    private func decodeManifest(
        in directory: FilePath,
        identity: String
    ) throws -> ProductArtifactManifest {
        let manifest: ProductArtifactManifest
        do {
            manifest = try JSONDecoder().decode(
                ProductArtifactManifest.self,
                from: Data(
                    contentsOf: URL(
                        fileURLWithPath: directory.appending("manifest.json").string)))
        } catch {
            throw ProductArtifactStoreFailure(
                "could not decode retained artifact manifest \(identity): \(error)")
        }
        guard manifest.identity.rawValue.hexadecimal == identity else {
            throw ProductArtifactStoreFailure(
                "retained artifact manifest was substituted: \(identity)")
        }
        return manifest
    }

    private func validateQualification(
        _ record: ProductArtifactQualificationRecord,
        evidence: FilePath,
        expectedEnvelope: ProductArtifactEnvelope
    ) throws {
        try record.validate()
        try record.capability.validate(
            for: record.role,
            artifactTarget: expectedEnvelope.manifest.artifactTarget)
        guard record.artifact == expectedEnvelope.identity,
            record.provenance == expectedEnvelope.provenanceIdentity
        else {
            throw ProductArtifactStoreFailure(
                "qualification record refers to a substituted artifact envelope")
        }
        guard try ArtifactHasher.digest(file: evidence) == record.evidenceDigest else {
            throw ProductArtifactStoreFailure("qualification evidence digest changed")
        }
    }

    private func artifactDirectory(_ identity: ProductArtifactID) -> FilePath {
        root.appending("products").appending(identity.rawValue.hexadecimal)
    }

    private func publishArchiveBlob(
        _ archive: FilePath,
        digest: ArtifactDigest
    ) throws -> FilePath {
        let archives = root.appending("archives")
        let destination = archives.appending(digest.hexadecimal)
        if FileManager.default.fileExists(atPath: destination.string) {
            guard try ArtifactHasher.digest(file: destination) == digest else {
                throw ProductArtifactStoreFailure(
                    "stored archive blob was substituted: \(digest)")
            }
            return destination
        }
        let candidate = archives.appending(
            ".candidate-\(digest.hexadecimal)-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: candidate.string) }
        try cloneRegularFile(from: archive, to: candidate)
        guard try ArtifactHasher.digest(file: candidate) == digest else {
            throw ProductArtifactStoreFailure(
                "archive blob digest changed while publishing: \(digest)")
        }
        do {
            try FileManager.default.moveItem(
                atPath: candidate.string,
                toPath: destination.string)
        } catch {
            guard FileManager.default.fileExists(atPath: destination.string),
                try ArtifactHasher.digest(file: destination) == digest
            else {
                throw error
            }
        }
        try DurableFile.synchronizeDirectory(archives)
        return destination
    }

    private func cloneTree(from source: FilePath, to destination: FilePath) throws {
        let metadata = try source.stat(followTargetSymlink: false)
        switch metadata.type {
        case .directory:
            try FileManager.default.createDirectory(
                atPath: destination.string,
                withIntermediateDirectories: false)
            for name in try FileManager.default.contentsOfDirectory(
                atPath: source.string)
            {
                try cloneTree(
                    from: source.appending(name),
                    to: destination.appending(name))
            }
            let attributes = try FileManager.default.attributesOfItem(
                atPath: source.string)
            if let permissions = attributes[.posixPermissions] {
                try FileManager.default.setAttributes(
                    [.posixPermissions: permissions],
                    ofItemAtPath: destination.string)
            }
        case .regular:
            try cloneRegularFile(from: source, to: destination)
        case .symbolicLink:
            let target = try FileManager.default.destinationOfSymbolicLink(
                atPath: source.string)
            try FileManager.default.createSymbolicLink(
                atPath: destination.string,
                withDestinationPath: target)
        default:
            throw ProductArtifactStoreFailure(
                "product payload contains an unsupported file type: \(source)")
        }
    }

    private func cloneRegularFile(
        from source: FilePath,
        to destination: FilePath
    ) throws {
        #if os(macOS)
        guard
            unsafe collider_clone_file(source.string, destination.string) == 0
        else {
            throw Errno(rawValue: errno)
        }
        #else
        try FileManager.default.copyItem(
            atPath: source.string,
            toPath: destination.string)
        #endif
    }

    private func qualificationDirectory(
        _ record: ProductArtifactQualificationRecordID,
        artifact: ProductArtifactID,
        provenance: ProductArtifactProvenanceID
    ) -> FilePath {
        root.appending("qualifications")
            .appending(artifact.rawValue.hexadecimal)
            .appending(provenance.rawValue.hexadecimal)
            .appending(record.rawValue.hexadecimal)
    }

    private func validateStoredManifest(
        _ expectedManifest: ProductArtifactManifest,
        identity: ProductArtifactID,
        directory: FilePath
    ) throws {
        let stored: ProductArtifactManifest
        do {
            stored = try JSONDecoder().decode(
                ProductArtifactManifest.self,
                from: Data(
                    contentsOf: URL(
                        fileURLWithPath: directory.appending("manifest.json").string)))
        } catch {
            throw ProductArtifactStoreFailure(
                "could not decode artifact manifest \(identity): \(error)")
        }
        guard stored == expectedManifest, stored.identity == identity else {
            throw ProductArtifactStoreFailure(
                "artifact identity already exists with a different manifest")
        }
        try validate(
            envelope: ProductArtifactEnvelope(
                manifest: stored,
                provenance: ProductArtifactProvenance(
                    baseCommit: nil,
                    branch: nil,
                    dirtyPaths: [],
                    sourceAuthority: .localDevelopment)),
            payloadRoot: directory.appending("payload"),
            archive: directory.appending("product.archive"))
    }

    private func publishProvenance(
        _ provenance: ProductArtifactProvenance,
        in artifactDirectory: FilePath
    ) throws {
        try provenance.validate()
        let path = provenancePath(provenance.identity, in: artifactDirectory)
        if FileManager.default.fileExists(atPath: path.string) {
            let existing = try JSONDecoder().decode(
                ProductArtifactProvenance.self,
                from: Data(contentsOf: URL(fileURLWithPath: path.string)))
            guard existing == provenance else {
                throw ProductArtifactStoreFailure(
                    "provenance identity already exists with different contents")
            }
            return
        }
        try DurableFile.writeJSON(provenance, to: path)
    }

    private func provenancePath(
        _ identity: ProductArtifactProvenanceID,
        in artifactDirectory: FilePath
    ) -> FilePath {
        artifactDirectory.appending("provenances")
            .appending(identity.rawValue.hexadecimal + ".json")
    }
}

private func validateProductArtifact(
    envelope: ProductArtifactEnvelope,
    payloadRoot: FilePath,
    archive: FilePath
) throws {
    try envelope.validate()
    let inspection = try inspectPayload(payloadRoot)
    guard inspection.treeDigest == envelope.manifest.treeDigest else {
        throw ProductArtifactStoreFailure("artifact payload tree digest changed")
    }
    guard inspection.files == envelope.manifest.files else {
        throw ProductArtifactStoreFailure("artifact payload file manifest changed")
    }
    guard try ArtifactHasher.digest(file: archive) == envelope.manifest.archiveDigest
    else {
        throw ProductArtifactStoreFailure("artifact archive digest changed")
    }
}

public struct ProductArtifactStorePruneResult: Equatable, Sendable {
    public let retainedProducts: Int
    public let retainedArchives: Int
    public let removedProducts: Int
    public let removedArchives: Int
    public let removedCandidates: Int

    public init(
        retainedProducts: Int,
        retainedArchives: Int,
        removedProducts: Int,
        removedArchives: Int,
        removedCandidates: Int
    ) {
        self.retainedProducts = retainedProducts
        self.retainedArchives = retainedArchives
        self.removedProducts = removedProducts
        self.removedArchives = removedArchives
        self.removedCandidates = removedCandidates
    }
}

public struct ProductArtifactStoreFailure: Error, CustomStringConvertible, Sendable {
    public let description: String

    public init(_ description: String) {
        self.description = "product artifact store failed: \(description)"
    }
}

private struct PayloadInspection {
    let treeDigest: ArtifactDigest
    let files: [ProductArtifactFile]
}

private func directoryEntries(_ root: FilePath) throws -> [FilePath] {
    guard (try? root.stat(followTargetSymlink: false).type) == .directory else {
        return []
    }
    return try FileManager.default.contentsOfDirectory(atPath: root.string)
        .sorted()
        .map { root.appending($0) }
}

private func isLowercaseSHA256(_ name: String) -> Bool {
    name.utf8.count == 64
        && name.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
}

private func isStoreCandidate(_ name: String) -> Bool {
    let prefix = ".candidate-"
    guard name.hasPrefix(prefix) else { return false }
    let suffix = name.dropFirst(prefix.count)
    guard let separator = suffix.firstIndex(of: "-") else { return false }
    let digest = String(suffix[..<separator])
    let identifier = suffix[suffix.index(after: separator)...]
    return isLowercaseSHA256(digest)
        && UUID(uuidString: String(identifier)) != nil
}

private func inspectPayload(_ root: FilePath) throws -> PayloadInspection {
    let metadata = try root.stat(followTargetSymlink: false)
    guard metadata.type == .directory else {
        throw ProductArtifactStoreFailure("artifact payload is not a directory: \(root)")
    }
    guard let enumerator = FileManager.default.enumerator(atPath: root.string) else {
        throw ProductArtifactStoreFailure("could not enumerate artifact payload: \(root)")
    }
    let relativePaths = enumerator.compactMap { $0 as? String }.sorted {
        $0.utf8.lexicographicallyPrecedes($1.utf8)
    }
    let files = try relativePaths.map { relative -> ProductArtifactFile in
        let path = root.appending(relative)
        let metadata = try path.stat(followTargetSymlink: false)
        let executable = metadata.permissions.contains(.ownerExecute)
        switch metadata.type {
        case .regular:
            return ProductArtifactFile(
                relativePath: relative,
                kind: .regular,
                digest: try ArtifactHasher.digest(file: path),
                ownerExecutable: executable)
        case .directory:
            return ProductArtifactFile(
                relativePath: relative,
                kind: .directory,
                ownerExecutable: executable)
        case .symbolicLink:
            return ProductArtifactFile(
                relativePath: relative,
                kind: .symbolicLink,
                ownerExecutable: executable,
                symbolicLinkTarget: try FileManager.default.destinationOfSymbolicLink(
                    atPath: path.string))
        default:
            throw ProductArtifactStoreFailure(
                "artifact payload contains unsupported file type: \(path)")
        }
    }
    return try PayloadInspection(
        treeDigest: ArtifactHasher.digest(tree: root),
        files: files)
}

import ColliderCore
import ColliderPersistence
import ColliderPlanning
import Foundation
import Synchronization
import SystemPackage
import Testing

@Test func coldConsumersDeferWithoutReadingUnproducedArtifacts() async throws {
    var producer = TaskBuilder(
        id: TaskID(rawValue: "fixture.producer"),
        component: ComponentID(rawValue: "fixture"))
    let artifact = try producer.output(
        "value", path: FilePath("/not-produced"), validation: .regularFile)
    var consumer = TaskBuilder(
        id: TaskID(rawValue: "fixture.consumer"),
        component: ComponentID(rawValue: "fixture"))
    consumer.consume(artifact)
    let digest = ArtifactDigest.sha256([UInt8]())
    let services = TaskPlanningServices(
        digestBytes: { ArtifactDigest.sha256($0) },
        digestFile: { _ in
            Issue.record("unproduced artifact was read")
            return digest
        },
        digestTree: { _ in
            Issue.record("unproduced artifact was read")
            return digest
        },
        digestSourceCheckout: { _ in digest },
        semanticToolIdentity: { _, _ in
            ToolIdentitySnapshot(path: FilePath("/tool"), digest: digest)
        },
        taskState: { _ in .missing }, validateOutputs: { _ in })
    let plan = try await ColliderPlanner().plan(
        graph: TaskGraph([producer.build(), consumer.build()]), selected: [consumer.id],
        rebuildSelected: false, lowerings: [], services: services)
    let entry = try #require(plan.declaredEntries.first { $0.task == consumer.id })
    #expect(entry.isDeferred)
    #expect(!entry.isClean)
}

@Test func identicalDeclarationsAndSnapshotsProduceIdenticalPlanBytes() async throws {
    let input = FilePath("/fixture/selected-input")
    let selected = TaskDeclaration(
        id: TaskID(rawValue: "fixture.selected"),
        component: ComponentID(rawValue: "fixture"),
        inputs: [.file(input)])
    let graph = try TaskGraph([selected])
    let digest = ArtifactDigest(bytes: Array(repeating: 11, count: 32))
    let services = deterministicServices(digest: digest)

    let first = try await ColliderPlanner().plan(
        graph: graph,
        selected: [selected.id],
        rebuildSelected: false,
        lowerings: [],
        services: services)
    let second = try await ColliderPlanner().plan(
        graph: graph,
        selected: [selected.id],
        rebuildSelected: false,
        lowerings: [],
        services: services)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    #expect(try encoder.encode(first.reportedEntries) == encoder.encode(second.reportedEntries))
}

@Test func plannerFreezesStableDurationWorkloadAndSelectedEstimate() async throws {
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.release"),
        component: ComponentID(rawValue: "fixture"),
        durationEstimationMode: "release")
    let digest = ArtifactDigest(bytes: Array(repeating: 12, count: 32))
    let services = TaskPlanningServices(
        digestBytes: { _ in digest },
        digestFile: { _ in digest },
        digestTree: { _ in digest },
        digestSourceCheckout: { _ in digest },
        semanticToolIdentity: { _, _ in
            ToolIdentitySnapshot(path: FilePath("/fixture/tool"), digest: digest)
        },
        taskState: { _ in .missing },
        durationEstimate: { workload in
            #expect(workload.task == task.id)
            #expect(workload.lane == .lightweight)
            #expect(workload.coordinates == nil)
            #expect(workload.mode == "release")
            return 42_000
        },
        validateOutputs: { _ in })

    let plan = try await ColliderPlanner().plan(
        graph: TaskGraph([task]),
        selected: [task.id],
        rebuildSelected: false,
        lowerings: [],
        services: services)
    let entry = try #require(plan.declaredEntries.first)

    #expect(entry.durationWorkload?.task == task.id)
    #expect(entry.durationEstimate?.workload == entry.durationWorkload)
    #expect(entry.durationEstimate?.durationNanoseconds == 42_000)
}

@Test func planningDoesNotReadUnselectedInputsOrValidateUnselectedOutputs() async throws {
    let selected = TaskDeclaration(
        id: TaskID(rawValue: "fixture.selected"),
        component: ComponentID(rawValue: "fixture"),
        inputs: [.file(FilePath("/fixture/selected"))])
    let unselected = TaskDeclaration(
        id: TaskID(rawValue: "fixture.unselected"),
        component: ComponentID(rawValue: "fixture"),
        inputs: [.tree(FilePath("/fixture/unselected"))])
    let fileReads = Mutex(0)
    let treeReads = Mutex(0)
    let validations = Mutex(0)
    let digest = ArtifactDigest(bytes: Array(repeating: 13, count: 32))
    let services = TaskPlanningServices(
        digestBytes: { _ in digest },
        digestFile: { _ in
            fileReads.withLock { $0 += 1 }
            return digest
        },
        digestTree: { _ in
            treeReads.withLock { $0 += 1 }
            return digest
        },
        digestSourceCheckout: { _ in digest },
        semanticToolIdentity: { _, _ in
            ToolIdentitySnapshot(path: FilePath("/fixture/tool"), digest: digest)
        },
        taskState: { _ in .missing },
        validateOutputs: { _ in validations.withLock { $0 += 1 } })

    _ = try await ColliderPlanner().plan(
        graph: TaskGraph([selected, unselected]),
        selected: [selected.id],
        rebuildSelected: false,
        lowerings: [],
        services: services)

    #expect(fileReads.withLock { $0 } == 1)
    #expect(treeReads.withLock { $0 } == 0)
    #expect(validations.withLock { $0 } == 0)
}

@Test func executionAndArtifactCoordinatesAffectTaskIdentity() async throws {
    func identity(
        execution: ExecutionPlatform,
        artifact: ArtifactTarget
    ) async throws -> ArtifactDigest {
        let action = try AnyColliderAction(
            PlacementIdentityAction(
                executionPlatform: execution,
                artifactTarget: artifact))
        let task = TaskDeclaration(
            id: TaskID(rawValue: "fixture.placement"),
            component: ComponentID(rawValue: "fixture"),
            action: action)
        let services = deterministicHashingServices()
        let plan = try await ColliderPlanner().plan(
            graph: TaskGraph([task]),
            selected: [task.id],
            rebuildSelected: false,
            lowerings: [],
            services: services)
        return try #require(plan.declaredEntries.first).identity
    }

    let armExecution = try await identity(
        execution: .linuxARM64OCI,
        artifact: .linuxX86_64)
    let amdExecution = try await identity(
        execution: .linuxAMD64OCI,
        artifact: .linuxX86_64)
    let armArtifact = try await identity(
        execution: .linuxARM64OCI,
        artifact: .linuxARM64)

    #expect(armExecution != amdExecution)
    #expect(armExecution != armArtifact)
}

@Test func taskIdentityIsStableAcrossWorkspaceAndCacheRelocation() async throws {
    func plannedIdentity(
        workspace: FilePath,
        cache: FilePath
    ) async throws -> ArtifactDigest {
        let input = workspace.appending("Sources/input.txt")
        let output = cache.appending("generated/result.json")
        var builder = TaskBuilder(
            id: TaskID(rawValue: "fixture.relocatable"),
            component: ComponentID(rawValue: "fixture"))
        let _: ArtifactReference = try builder.output(
            "result",
            path: output,
            validation: .json)
        let task = builder.build(
            inputs: [
                .file(input),
                .string(
                    name: "FIXTURE_LINK_TARGET",
                    value: workspace.appending("Sources/include").string),
                .environment(
                    name: "FIXTURE_PATH",
                    value: workspace.appending("toolchain/bin").string),
            ],
            action: try AnyColliderAction(
                RelocatableIdentityAction(
                    input: input,
                    output: output,
                    environment: [
                        "CCACHE_BASEDIR": workspace.string,
                        "FIXTURE_MODE": "release",
                    ])))
        let services = deterministicHashingServices(
            identityPathMap: IdentityPathMap(roots: [
                IdentityPathRoot(name: "workspace", path: workspace),
                IdentityPathRoot(name: "cache", path: cache),
            ]))
        let plan = try await ColliderPlanner().plan(
            graph: TaskGraph([task]),
            selected: [task.id],
            rebuildSelected: false,
            lowerings: [],
            services: services)
        return try #require(plan.declaredEntries.first).identity
    }

    let first = try await plannedIdentity(
        workspace: FilePath("/first/checkout"),
        cache: FilePath("/first/cache"))
    let second = try await plannedIdentity(
        workspace: FilePath("/second/nucleus"),
        cache: FilePath("/second/cache"))

    #expect(first == second)
}

@Test func taskIdentityIgnoresTheAccountThatPlansTheBuild() async throws {
    let workspace = FilePath("/nucleus/checkout")
    let cache = FilePath("/nucleus/cache")

    func plannedIdentity(account: String) async throws -> ArtifactDigest {
        let input = workspace.appending("Sources/input.txt")
        let output = cache.appending("generated/result.json")
        var builder = TaskBuilder(
            id: TaskID(rawValue: "fixture.account-independent"),
            component: ComponentID(rawValue: "fixture"))
        let _: ArtifactReference = try builder.output(
            "result",
            path: output,
            validation: .json)
        let task = builder.build(
            inputs: [.file(input)],
            action: try AnyColliderAction(
                RelocatableIdentityAction(
                    input: input,
                    output: output,
                    environment: [
                        "FIXTURE_MODE": "release",
                        "HOME": "/Users/\(account)",
                        "LOGNAME": account,
                        "USER": account,
                    ])))
        let services = deterministicHashingServices(
            identityPathMap: IdentityPathMap(roots: [
                IdentityPathRoot(name: "workspace", path: workspace),
                IdentityPathRoot(name: "cache", path: cache),
            ]))
        let plan = try await ColliderPlanner().plan(
            graph: TaskGraph([task]),
            selected: [task.id],
            rebuildSelected: false,
            lowerings: [],
            services: services)
        return try #require(plan.declaredEntries.first).identity
    }

    let developer = try await plannedIdentity(account: "maddy")
    let builder = try await plannedIdentity(account: "nucleus-builder")

    #expect(developer == builder)
}

@Test func taskIdentityMatchesBeforeAndAfterCommittingTheEffectiveSourceTree() async throws {
    let repository = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-task-source-commit-independent-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: repository) }
    try initializeGitRepository(repository)
    let sources = repository.appendingPathComponent("Sources")
    try FileManager.default.createDirectory(
        at: sources,
        withIntermediateDirectories: true)
    let tracked = sources.appendingPathComponent("Value.swift")
    try Data("let value = 1\n".utf8).write(to: tracked)
    try commitAll(repository)

    let sourcePath = FilePath(sources.path)
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.source-checkout"),
        component: ComponentID(rawValue: "fixture"),
        inputs: [.sourceCheckout(sourcePath)])
    func plannedIdentity() async throws -> ArtifactDigest {
        let digests = PlanningArtifactDigestCache()
        let services = TaskPlanningServices(
            digestBytes: { ArtifactHasher.digest(bytes: Data($0)) },
            digestFile: { try digests.digest(file: $0) },
            digestTree: { try digests.digest(tree: $0) },
            digestSourceCheckout: { try await digests.digest(sourceCheckout: $0) },
            semanticToolIdentity: { _, _ in
                ToolIdentitySnapshot(
                    path: FilePath("/fixture/tool"),
                    digest: ArtifactDigest(bytes: Array(repeating: 7, count: 32)))
            },
            taskState: { _ in .missing },
            validateOutputs: { _ in })
        let plan = try await ColliderPlanner().plan(
            graph: TaskGraph([task]),
            selected: [task.id],
            rebuildSelected: false,
            lowerings: [],
            services: services)
        return try #require(plan.declaredEntries.first).identity
    }

    try Data("let value = 2\n".utf8).write(to: tracked)
    try Data("let added = true\n".utf8).write(
        to: sources.appendingPathComponent("Added.swift"))
    let dirty = try await plannedIdentity()
    try commitAll(repository)

    #expect(try await plannedIdentity() == dirty)
}

@Test func semanticDependencyOrderDoesNotAffectTaskIdentity() async throws {
    let first = TaskDeclaration(
        id: TaskID(rawValue: "fixture.first"),
        component: ComponentID(rawValue: "fixture"),
        inputs: [.string(name: "value", value: "first")])
    let second = TaskDeclaration(
        id: TaskID(rawValue: "fixture.second"),
        component: ComponentID(rawValue: "fixture"),
        inputs: [.string(name: "value", value: "second")])
    let consumerID = TaskID(rawValue: "fixture.consumer")

    func identity(dependencies: [TaskID]) async throws -> ArtifactDigest {
        let consumer = TaskDeclaration(
            id: consumerID,
            component: ComponentID(rawValue: "fixture"),
            dependencies: dependencies)
        let plan = try await ColliderPlanner().plan(
            graph: TaskGraph([first, second, consumer]),
            selected: [consumerID],
            rebuildSelected: false,
            lowerings: [],
            services: deterministicHashingServices())
        return try #require(
            plan.declaredEntries.first { $0.task == consumerID }
        ).identity
    }

    #expect(
        try await identity(dependencies: [first.id, second.id])
            == identity(dependencies: [second.id, first.id]))
}

private struct PlacementIdentityAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        func encode(into encoder: inout IdentityEncoder) {
            encoder.append("stable-action")
        }
    }

    static let kind: ActionKind = "fixture.placement"

    let executionPlatform: ExecutionPlatform
    let artifactTarget: ArtifactTarget

    var identity: Identity { Identity() }

    var requirements: ActionRequirements {
        ActionRequirements(
            executionPlatform: executionPlatform,
            artifactTarget: artifactTarget)
    }

    func execute(in _: ActionContext) async throws {}
}

private struct RelocatableIdentityAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let input: FilePath
        let output: FilePath

        func encode(into encoder: inout IdentityEncoder) {
            encoder.append(path: input)
            encoder.append(path: output)
        }
    }

    static let kind: ActionKind = "fixture.relocatable"

    let input: FilePath
    let output: FilePath
    let environment: [String: String]

    var identity: Identity { Identity(input: input, output: output) }

    var requirements: ActionRequirements {
        ActionRequirements(
            effects: [
                ActionEffect(.read, scope: .input(input)),
                ActionEffect(.write, scope: .output(output)),
            ],
            executionPlatform: .macOSARM64Native)
    }

    func execute(in _: ActionContext) async throws {}
}

private func deterministicServices(digest: ArtifactDigest) -> TaskPlanningServices {
    TaskPlanningServices(
        digestBytes: { _ in digest },
        digestFile: { _ in digest },
        digestTree: { _ in digest },
        digestSourceCheckout: { _ in digest },
        semanticToolIdentity: { _, _ in
            ToolIdentitySnapshot(path: FilePath("/fixture/tool"), digest: digest)
        },
        taskState: { _ in .missing },
        validateOutputs: { _ in })
}

private func deterministicHashingServices(
    identityPathMap: IdentityPathMap = .empty
) -> TaskPlanningServices {
    let digest = ArtifactDigest(bytes: Array(repeating: 17, count: 32))
    return TaskPlanningServices(
        identityPathMap: identityPathMap,
        digestBytes: { ArtifactDigest.sha256(Data($0)) },
        digestFile: { _ in digest },
        digestTree: { _ in digest },
        digestSourceCheckout: { _ in digest },
        semanticToolIdentity: { _, _ in
            ToolIdentitySnapshot(path: FilePath("/fixture/tool"), digest: digest)
        },
        taskState: { _ in .missing },
        validateOutputs: { _ in })
}

private func initializeGitRepository(_ repository: URL) throws {
    try FileManager.default.createDirectory(
        at: repository,
        withIntermediateDirectories: true)
    try runGit(at: repository, arguments: ["init", "--quiet"])
    try runGit(
        at: repository,
        arguments: ["config", "user.name", "Collider Tests"])
    try runGit(
        at: repository,
        arguments: ["config", "user.email", "collider@example.invalid"])
}

private func commitAll(_ repository: URL) throws {
    try runGit(at: repository, arguments: ["add", "--all"])
    try runGit(
        at: repository,
        arguments: ["commit", "--quiet", "--message", "fixture"])
}

private func runGit(at repository: URL, arguments: [String]) throws {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.currentDirectoryURL = repository
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = output
    try process.run()
    _ = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CocoaError(.fileWriteUnknown)
    }
}

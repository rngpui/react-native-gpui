import ColliderCore
import ColliderEngine
import Foundation
import SystemPackage
import Testing

@testable import ColliderPersistence
@testable import ColliderRuntime

private struct ParallelismProbeIdentity: ColliderActionIdentity {
    let name: String

    func encode(into encoder: inout IdentityEncoder) {
        encoder.append(name)
    }
}

private actor ParallelismProbe {
    private var active = 0
    private var maximumActive = 0
    private var started: [String] = []

    func exercise(
        name: String,
        duration: Duration = .milliseconds(100),
        rendezvousParticipants: Int? = nil
    ) async {
        started.append(name)
        active += 1
        maximumActive = max(maximumActive, active)
        if let rendezvousParticipants {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while maximumActive < rendezvousParticipants,
                ContinuousClock.now < deadline
            {
                try? await Task.sleep(for: .milliseconds(10))
            }
        } else {
            try? await Task.sleep(for: duration)
        }
        active -= 1
    }

    func maximum() -> Int { maximumActive }
    func startOrder() -> [String] { started }
}

private struct ParallelismProbeAction: ColliderAction {
    static let kind: ActionKind = "fixture.parallelism-probe"

    let identity: ParallelismProbeIdentity
    let probe: ParallelismProbe
    let output: FilePath
    let publicationClaim: FilePath?
    let persistentWorkspaceEffects: [ActionPersistentWorkspaceEffect]
    let lane: TaskExecutionLane
    let duration: Duration
    let rendezvousParticipants: Int?

    init(
        identity: ParallelismProbeIdentity,
        probe: ParallelismProbe,
        output: FilePath,
        publicationClaim: FilePath? = nil,
        persistentWorkspaceEffects: [ActionPersistentWorkspaceEffect] = [],
        lane: TaskExecutionLane = .lightweight,
        duration: Duration = .milliseconds(100),
        rendezvousParticipants: Int? = nil
    ) {
        self.identity = identity
        self.probe = probe
        self.output = output
        self.publicationClaim = publicationClaim
        self.persistentWorkspaceEffects = persistentWorkspaceEffects
        self.lane = lane
        self.duration = duration
        self.rendezvousParticipants = rendezvousParticipants
    }

    var requirements: ActionRequirements {
        var effects = [ActionEffect(.write, scope: .output(output))]
        if let publicationClaim {
            effects.append(
                ActionEffect(.readWrite, scope: .publication(publicationClaim)))
        }
        return ActionRequirements(
            effects: effects,
            persistentWorkspaceEffects: persistentWorkspaceEffects,
            lane: lane,
            executionPlatform: persistentWorkspaceEffects.isEmpty
                ? .macOSARM64Native : .linuxARM64OCI,
            artifactTarget: persistentWorkspaceEffects.first?.workspace.identity.artifactTarget)
    }

    func execute(in context: ActionContext) async throws {
        await probe.exercise(
            name: identity.name,
            duration: duration,
            rendezvousParticipants: rendezvousParticipants)
        try context.files.write(Array(identity.name.utf8), to: output)
    }
}

private func schedulerWorkspace(
    key: String,
    target: ArtifactTarget = .linuxARM64,
    access: OCIPersistentWorkspaceMount.Access = .readWrite
) -> ActionPersistentWorkspaceEffect {
    ActionPersistentWorkspaceEffect(
        workspace: PersistentWorkspaceDeclaration(
            identity: PersistentWorkspaceIdentity(
                key: key,
                artifactTarget: target,
                role: "build"),
            capacityBytes: 1_024 * 1_024,
            filesystem: .ext4,
            journal: PersistentWorkspaceJournal(
                mode: .writeback,
                sizeBytes: 64 * 1_024)),
        target: "/build",
        access: access)
}

private struct FailAfterWriteAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        func encode(into _: inout IdentityEncoder) {}
    }

    static let kind: ActionKind = "fixture.fail-after-write"
    let identity = Identity()
    let output: FilePath

    var requirements: ActionRequirements {
        ActionRequirements(
            effects: [
                ActionEffect(.write, scope: .output(output))
            ],
            executionPlatform: .macOSARM64Native)
    }

    func execute(in context: ActionContext) async throws {
        try context.files.write(Array("partial".utf8), to: output)
        throw RuntimeFailure.invalidOutput("injected failure")
    }
}

private actor TeardownRendezvous {
    private var peerStarted = false

    func markStarted() { peerStarted = true }

    func waitForPeer() async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !peerStarted, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// Fails only once the task it has to outlive is running.
private struct FailsAfterPeerStartsAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        func encode(into _: inout IdentityEncoder) {}
    }

    static let kind: ActionKind = "fixture.fails-after-peer-starts"
    let identity = Identity()
    let rendezvous: TeardownRendezvous

    var requirements: ActionRequirements {
        ActionRequirements(effects: [], executionPlatform: .macOSARM64Native)
    }

    func execute(in _: ActionContext) async throws {
        await rendezvous.waitForPeer()
        throw RuntimeFailure.invalidOutput("injected failure")
    }
}

/// Reports a resource-level error once the run stops it, the way a container
/// operation reports the container teardown has already removed.
private struct ReportsATornDownResourceAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        func encode(into _: inout IdentityEncoder) {}
    }

    static let kind: ActionKind = "fixture.torn-down-resource"
    let identity = Identity()
    let rendezvous: TeardownRendezvous

    var requirements: ActionRequirements {
        ActionRequirements(effects: [], executionPlatform: .macOSARM64Native)
    }

    func execute(in _: ActionContext) async throws {
        await rendezvous.markStarted()
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(5))
        }
        throw TornDownResourceFailure()
    }
}

private struct TornDownResourceFailure: Error, CustomStringConvertible {
    var description: String {
        "notFound: \"container with ID fixture-a351c408 not found\""
    }
}

@Test func aTaskTheRunStoppedIsRecordedCancelledRatherThanFailed() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-engine-teardown-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = FilePath(directory.path)
    let rendezvous = TeardownRendezvous()
    let failing = TaskDeclaration(
        id: TaskID(rawValue: "fixture.fails"),
        component: ComponentID(rawValue: "fixture"),
        action: try AnyColliderAction(
            FailsAfterPeerStartsAction(rendezvous: rendezvous)))
    let stopped = TaskDeclaration(
        id: TaskID(rawValue: "fixture.stopped"),
        component: ComponentID(rawValue: "fixture"),
        action: try AnyColliderAction(
            ReportsATornDownResourceAction(rendezvous: rendezvous)))
    let registry = RunRegistry(root: root.appending("runs"))
    let run = try await registry.begin(command: ["collider", "verify", "fixture"])

    await #expect(throws: (any Error).self) {
        _ = try await ColliderEngine(runtime: ColliderRuntime()).execute(
            graph: TaskGraph([failing, stopped]),
            selected: [failing.id, stopped.id],
            stateRoot: root.appending("state"),
            run: run,
            registry: registry)
    }
    try await registry.finish(run, status: .failed)
    let state = try await registry.reducedEvents(
        in: registry.recordedRun(run.id))

    // The stopped task's own error is what tearing its resource down produced,
    // never a verdict on the work. Reading it as one reports a single failing
    // task as several and can mark work that had already finished as failed.
    #expect(state.tasks[stopped.id] == .cancelled)
    guard case .failed = try #require(state.tasks[failing.id]) else {
        Issue.record("the causal failure was not recorded as a failure")
        return
    }
    #expect(state.failedTask == failing.id)
}

private struct CyclicOwnerCompletionLowering: TaskPlanLowering {
    func lower(_ tasks: [AssessedTaskDeclaration]) throws -> [LoweredExecutionTask] {
        guard let owner = tasks.first?.task else { return [] }
        return [
            LoweredExecutionTask(
                task: TaskDeclaration(
                    id: TaskID(rawValue: "fixture.lowered"),
                    component: ComponentID(rawValue: "fixture"),
                    dependencies: [owner.id]),
                attribution: "fixture", logicalOwners: [owner.id], prerequisites: [owner.id])
        ]
    }
}

@Test func executionGraphRejectsCyclesIntroducedByOwnerCompletionEdges() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let owner = TaskDeclaration(
        id: TaskID(rawValue: "fixture.owner"),
        component: ComponentID(rawValue: "fixture"))
    do {
        _ = try await ColliderEngine(runtime: ColliderRuntime()).execute(
            graph: TaskGraph([owner]), selected: [owner.id], stateRoot: FilePath(directory.path),
            lowerings: [CyclicOwnerCompletionLowering()])
        Issue.record("cyclic execution graph was accepted")
    } catch let error as TaskGraphFailure {
        guard case .cycle(let path) = error else { throw error }
        #expect(Set(path) == Set([owner.id, TaskID(rawValue: "fixture.lowered")]))
        #expect(path.first == path.last)
    }
}

@Test func artifactConsumptionStopsAtUnchangedBytesAndPropagatesChangedBytes() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = FilePath(directory.path)
    let state = root.appending("state")
    var producer = TaskBuilder(
        id: TaskID(rawValue: "fixture.producer"),
        component: ComponentID(rawValue: "fixture"))
    let artifact = try producer.output(
        "value", path: root.appending("value"), validation: .regularFile)
    var consumer = TaskBuilder(
        id: TaskID(rawValue: "fixture.consumer"),
        component: ComponentID(rawValue: "fixture"))
    consumer.consume(artifact)
    let result = try consumer.output(
        "result", path: root.appending("result"), validation: .regularFile)
    let consumerTask = consumer.build(action: try fixtureWriteAction(result.path, bytes: [42]))
    // An untyped edge must transitively carry the consumer's final identity.
    let downstream = TaskDeclaration(
        id: TaskID(rawValue: "fixture.downstream"),
        component: ComponentID(rawValue: "fixture"),
        dependencies: [consumer.id],
        outputs: [OutputDeclaration(path: root.appending("downstream"), validation: .regularFile)],
        action: try fixtureWriteAction(root.appending("downstream"), bytes: [43]))
    func run(recipe: String, bytes: [UInt8], force: Bool = false) async throws
        -> TaskExecutionReport
    {
        let task = producer.build(
            inputs: [.string(name: "recipe", value: recipe)],
            action: try fixtureWriteAction(artifact.path, bytes: bytes))
        return try await ColliderEngine(runtime: ColliderRuntime()).execute(
            graph: TaskGraph([task, consumerTask, downstream]), selected: [downstream.id],
            stateRoot: state, options: TaskExecutionOptions(rebuildSelected: force))
    }
    let cold = try await run(recipe: "one", bytes: [1])
    #expect(cold.executed == [producer.id, consumer.id, downstream.id])
    let unchanged = try await run(recipe: "two", bytes: [1])
    #expect(unchanged.executed == [producer.id])
    #expect(unchanged.plan.first { $0.task == consumer.id }?.isClean == true)
    let changed = try await run(recipe: "three", bytes: [2])
    #expect(changed.executed == [producer.id, consumer.id, downstream.id])
    try FileManager.default.removeItem(atPath: artifact.path.string)
    let restored = try await run(recipe: "three", bytes: [2])
    #expect(restored.executed == [producer.id])
    let forced = try await run(recipe: "three", bytes: [2], force: true)
    #expect(forced.executed == [downstream.id])
}

@Test func taskSchedulerRunsIndependentTasksConcurrently() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-engine-concurrency-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = FilePath(directory.path)
    let probe = ParallelismProbe()
    let tasks = try ["first", "second"].map { name in
        let output = root.appending(name)
        return TaskDeclaration(
            id: TaskID(rawValue: "fixture.concurrent.\(name)"),
            component: ComponentID(rawValue: "fixture"),
            outputs: [
                OutputDeclaration(path: output, validation: .regularFile)
            ],
            action:
                try AnyColliderAction(
                    ParallelismProbeAction(
                        identity: ParallelismProbeIdentity(name: name),
                        probe: probe,
                        output: output)))
    }

    let report = try await ColliderEngine(runtime: ColliderRuntime()).execute(
        graph: TaskGraph(tasks),
        selected: tasks.map(\.id),
        stateRoot: root.appending("state"),
        options: TaskExecutionOptions(
            laneLimits: TaskLaneLimits(lightweight: 2, oci: 2)))
    let maximumActive = await probe.maximum()

    #expect(report.executed == tasks.map(\.id))
    #expect(Set(report.taskTimings.map(\.task)) == Set(tasks.map(\.id)))
    #expect(report.taskTimings.allSatisfy { $0.durationNanoseconds > 0 })
    #expect(maximumActive == 2)
}

@Test func capacityOneAndConcurrentExecutionProduceTheSamePlanAndOutputs() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-engine-capacity-equivalence-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = FilePath(directory.path)
    let stateRoot = root.appending("state")
    let tasks = try ["first", "second"].map { name in
        let output = root.appending(name)
        return TaskDeclaration(
            id: TaskID(rawValue: "fixture.capacity.\(name)"),
            component: ComponentID(rawValue: "fixture"),
            outputs: [OutputDeclaration(path: output, validation: .regularFile)],
            action: try AnyColliderAction(
                ParallelismProbeAction(
                    identity: ParallelismProbeIdentity(name: name),
                    probe: ParallelismProbe(),
                    output: output)))
    }
    let graph = try TaskGraph(tasks)

    let serial = try await ColliderEngine(runtime: ColliderRuntime()).execute(
        graph: graph,
        selected: tasks.map(\.id),
        stateRoot: stateRoot,
        options: TaskExecutionOptions(
            laneLimits: TaskLaneLimits(lightweight: 1, oci: 1)))
    let serialOutputs = try tasks.map { task in
        try Data(contentsOf: URL(fileURLWithPath: task.outputs[0].path.string))
    }
    for task in tasks {
        try FileManager.default.removeItem(atPath: task.outputs[0].path.string)
    }
    try FileManager.default.removeItem(atPath: stateRoot.string)

    let concurrent = try await ColliderEngine(runtime: ColliderRuntime()).execute(
        graph: graph,
        selected: tasks.map(\.id),
        stateRoot: stateRoot,
        options: TaskExecutionOptions(
            laneLimits: TaskLaneLimits(lightweight: 2, oci: 2)))
    let concurrentOutputs = try tasks.map { task in
        try Data(contentsOf: URL(fileURLWithPath: task.outputs[0].path.string))
    }

    #expect(serial.plan.map(\.task) == concurrent.plan.map(\.task))
    #expect(serial.plan.map(\.identity) == concurrent.plan.map(\.identity))
    #expect(serial.executed == concurrent.executed)
    #expect(serialOutputs == concurrentOutputs)
}

@Test func taskSchedulerSerializesTasksWithTheSameLock() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-engine-lock-concurrency-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = FilePath(directory.path)
    let probe = ParallelismProbe()
    let lock = TaskLock.checkout("fixture-shared-checkout")
    let tasks = try ["first", "second"].map { name in
        let output = root.appending(name)
        return TaskDeclaration(
            id: TaskID(rawValue: "fixture.locked.\(name)"),
            component: ComponentID(rawValue: "fixture"),
            outputs: [
                OutputDeclaration(path: output, validation: .regularFile)
            ],
            locks: [lock],
            action:
                try AnyColliderAction(
                    ParallelismProbeAction(
                        identity: ParallelismProbeIdentity(name: name),
                        probe: probe,
                        output: output)))
    }

    _ = try await ColliderEngine(runtime: ColliderRuntime()).execute(
        graph: TaskGraph(tasks),
        selected: tasks.map(\.id),
        stateRoot: root.appending("state"),
        options: TaskExecutionOptions(
            laneLimits: TaskLaneLimits(lightweight: 2, oci: 2)))
    let maximumActive = await probe.maximum()

    #expect(maximumActive == 1)
}

@Test func taskSchedulerSerializesTheSamePersistentWorkspace() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-engine-workspace-concurrency-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = FilePath(directory.path)
    let probe = ParallelismProbe()
    let workspace = schedulerWorkspace(key: "shared-build")
    let tasks = try ["first", "second"].enumerated().map { index, name in
        let output = root.appending(name)
        return TaskDeclaration(
            id: TaskID(rawValue: "fixture.workspace.\(name)"),
            component: ComponentID(rawValue: "fixture"),
            outputs: [OutputDeclaration(path: output, validation: .regularFile)],
            action: try AnyColliderAction(
                ParallelismProbeAction(
                    identity: ParallelismProbeIdentity(name: name),
                    probe: probe,
                    output: output,
                    persistentWorkspaceEffects: [
                        schedulerWorkspace(
                            key: workspace.workspace.identity.key,
                            access: index == 0 ? .readOnly : .readWrite)
                    ],
                    lane: .oci)))
    }

    _ = try await ColliderEngine(runtime: ColliderRuntime()).execute(
        graph: TaskGraph(tasks),
        selected: tasks.map(\.id),
        stateRoot: root.appending("state"),
        options: TaskExecutionOptions(
            laneLimits: TaskLaneLimits(lightweight: 2, oci: 2)))

    #expect(await probe.maximum() == 1)
}

@Test func taskSchedulerRunsDistinctPersistentWorkspacesConcurrently() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-engine-independent-workspaces-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = FilePath(directory.path)
    let probe = ParallelismProbe()
    let tasks = try ["first", "second"].map { name in
        let output = root.appending(name)
        return TaskDeclaration(
            id: TaskID(rawValue: "fixture.workspace-independent.\(name)"),
            component: ComponentID(rawValue: "fixture"),
            outputs: [OutputDeclaration(path: output, validation: .regularFile)],
            action: try AnyColliderAction(
                ParallelismProbeAction(
                    identity: ParallelismProbeIdentity(name: name),
                    probe: probe,
                    output: output,
                    persistentWorkspaceEffects: [schedulerWorkspace(key: name)],
                    lane: .oci,
                    rendezvousParticipants: 2)))
    }

    _ = try await ColliderEngine(runtime: ColliderRuntime()).execute(
        graph: TaskGraph(tasks),
        selected: tasks.map(\.id),
        stateRoot: root.appending("state"),
        options: TaskExecutionOptions(
            laneLimits: TaskLaneLimits(lightweight: 2, oci: 2)))

    #expect(await probe.maximum() == 2)
}

@Test func taskSchedulerTreatsTheSameWorkspaceKeyForDifferentTargetsAsIndependent()
    async throws
{
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-engine-cross-target-workspaces-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = FilePath(directory.path)
    let probe = ParallelismProbe()
    let targets: [(String, ArtifactTarget)] = [
        ("arm64", .linuxARM64),
        ("x86_64", .linuxX86_64),
    ]
    let tasks = try targets.map { name, target in
        let output = root.appending(name)
        return TaskDeclaration(
            id: TaskID(rawValue: "fixture.workspace-target.\(name)"),
            component: ComponentID(rawValue: "fixture"),
            outputs: [OutputDeclaration(path: output, validation: .regularFile)],
            action: try AnyColliderAction(
                ParallelismProbeAction(
                    identity: ParallelismProbeIdentity(name: name),
                    probe: probe,
                    output: output,
                    persistentWorkspaceEffects: [
                        schedulerWorkspace(key: "build", target: target)
                    ],
                    lane: .oci,
                    // Wait for the overlap rather than sampling for it. The
                    // default probe sleeps a fixed 100 ms and asks afterwards
                    // whether both happened to be active, which a loaded
                    // machine answers no to -- a cold build ahead of this suite
                    // was enough. Rendezvous still fails if the scheduler
                    // serializes them, which is what the test is for; it just
                    // stops the answer depending on the machine.
                    rendezvousParticipants: 2)))
    }

    _ = try await ColliderEngine(runtime: ColliderRuntime()).execute(
        graph: TaskGraph(tasks),
        selected: tasks.map(\.id),
        stateRoot: root.appending("state"),
        options: TaskExecutionOptions(
            laneLimits: TaskLaneLimits(lightweight: 2, oci: 2)))

    #expect(await probe.maximum() == 2)
}

@Test func taskSchedulerAtomicallyReservesOverlappingPublicationClaims() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-engine-claim-concurrency-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = FilePath(directory.path)
    let probe = ParallelismProbe()
    let publication = root.appending("published")
    let tasks = try ["first", "second"].enumerated().map { index, name in
        let output = root.appending(name)
        return TaskDeclaration(
            id: TaskID(rawValue: "fixture.claimed.\(name)"),
            component: ComponentID(rawValue: "fixture"),
            outputs: [OutputDeclaration(path: output, validation: .regularFile)],
            action: try AnyColliderAction(
                ParallelismProbeAction(
                    identity: ParallelismProbeIdentity(name: name),
                    probe: probe,
                    output: output,
                    publicationClaim: publication,
                    lane: index == 0 ? .lightweight : .oci)))
    }

    let report = try await ColliderEngine(runtime: ColliderRuntime()).execute(
        graph: TaskGraph(tasks),
        selected: tasks.map(\.id),
        stateRoot: root.appending("state"),
        options: TaskExecutionOptions(
            laneLimits: TaskLaneLimits(lightweight: 2, oci: 2)))

    let maximumActive = await probe.maximum()
    #expect(maximumActive == 1)
    #expect(report.schedulingWaitDurationNanoseconds > 0)
    #expect(report.criticalPathDurationNanoseconds > 0)
}

@Test func taskSchedulerSerializesHostExclusiveWork() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-engine-io-concurrency-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = FilePath(directory.path)
    let probe = ParallelismProbe()
    let tasks = try ["first", "second"].map { name in
        let output = root.appending(name)
        return TaskDeclaration(
            id: TaskID(rawValue: "fixture.io.\(name)"),
            component: ComponentID(rawValue: "fixture"),
            outputs: [OutputDeclaration(path: output, validation: .regularFile)],
            action: try AnyColliderAction(
                ParallelismProbeAction(
                    identity: ParallelismProbeIdentity(name: name),
                    probe: probe,
                    output: output,
                    lane: .hostExclusive)))
    }

    _ = try await ColliderEngine(runtime: ColliderRuntime()).execute(
        graph: TaskGraph(tasks),
        selected: tasks.map(\.id),
        stateRoot: root.appending("state"),
        options: TaskExecutionOptions(
            laneLimits: TaskLaneLimits(lightweight: 2, oci: 2)))

    let maximumActive = await probe.maximum()
    #expect(maximumActive == 1)
}

@Test func hostExclusiveWorkDoesNotOverlapOtherLanes() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-engine-host-exclusive-barrier-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = FilePath(directory.path)
    let probe = ParallelismProbe()
    let lanes: [(String, TaskExecutionLane)] = [
        ("exclusive", .hostExclusive),
        ("lightweight", .lightweight),
        ("oci", .oci),
    ]
    let tasks = try lanes.map { name, lane in
        let output = root.appending(name)
        return TaskDeclaration(
            id: TaskID(rawValue: "fixture.host-exclusive-barrier.\(name)"),
            component: ComponentID(rawValue: "fixture"),
            outputs: [OutputDeclaration(path: output, validation: .regularFile)],
            action: try AnyColliderAction(
                ParallelismProbeAction(
                    identity: ParallelismProbeIdentity(name: name),
                    probe: probe,
                    output: output,
                    lane: lane)))
    }

    _ = try await ColliderEngine(runtime: ColliderRuntime()).execute(
        graph: TaskGraph(tasks),
        selected: tasks.map(\.id),
        stateRoot: root.appending("state"),
        options: TaskExecutionOptions(
            laneLimits: TaskLaneLimits(lightweight: 2, oci: 2)))

    #expect(await probe.maximum() == 2)
}

@Test func schedulerDrainsForTheHighestPriorityHostExclusiveCriticalPath() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-engine-exclusive-critical-path-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = FilePath(directory.path)
    let stateRoot = root.appending("state")
    let probe = ParallelismProbe()

    func task(
        _ name: String,
        lane: TaskExecutionLane,
        dependencies: [TaskID] = [],
        duration: Duration
    ) throws -> TaskDeclaration {
        TaskDeclaration(
            id: TaskID(rawValue: "fixture.critical-path.\(name)"),
            component: ComponentID(rawValue: "fixture"),
            dependencies: dependencies,
            outputs: [
                OutputDeclaration(
                    path: root.appending(name),
                    validation: .regularFile)
            ],
            assessmentPolicy: .always,
            action: try AnyColliderAction(
                ParallelismProbeAction(
                    identity: ParallelismProbeIdentity(name: name),
                    probe: probe,
                    output: root.appending(name),
                    lane: lane,
                    duration: duration)))
    }

    let prerequisite = try task(
        "prerequisite",
        lane: .lightweight,
        duration: .milliseconds(30))
    let exclusive = try task(
        "exclusive",
        lane: .hostExclusive,
        dependencies: [prerequisite.id],
        duration: .milliseconds(30))
    let long = try task(
        "long",
        lane: .lightweight,
        duration: .milliseconds(120))
    let queued = try task(
        "queued",
        lane: .lightweight,
        duration: .milliseconds(30))
    let tasks = [prerequisite, exclusive, long, queued]
    let coordinates = TaskExecutionCoordinates(
        runner: .current,
        execution: .macOSARM64Native,
        backend: .native,
        artifact: nil)
    let estimates: [TaskID: UInt64] = [
        prerequisite.id: 50,
        exclusive.id: 1_000,
        long.id: 900,
        queued.id: 10,
    ]
    let estimatePlan = tasks.map { task in
        let lane = task.action?.requirements.lane ?? .lightweight
        let workload = TaskDurationWorkload(
            task: task.id,
            lane: lane,
            coordinates: coordinates,
            mode: nil)
        return TaskPlanEntry(
            task: task.id,
            identity: ArtifactDigest(bytes: Array(repeating: 1, count: 32)),
            isClean: false,
            explanation: "fixture",
            coordinates: coordinates,
            lane: lane,
            durationWorkload: workload)
    }
    try TaskDurationEstimateStore(
        root: stateRoot.appending("duration-estimates")
    ).record(estimates, plan: estimatePlan)

    _ = try await ColliderEngine(runtime: ColliderRuntime()).execute(
        graph: TaskGraph(tasks),
        selected: tasks.map(\.id),
        stateRoot: stateRoot,
        options: TaskExecutionOptions(
            laneLimits: TaskLaneLimits(lightweight: 2, oci: 2)))

    let order = await probe.startOrder()
    let exclusiveIndex = try #require(order.firstIndex(of: "exclusive"))
    let queuedIndex = try #require(order.firstIndex(of: "queued"))
    #expect(exclusiveIndex < queuedIndex)
}

@Test func taskSchedulerRunsIndependentOCIWorkConcurrently() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-engine-oci-concurrency-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = FilePath(directory.path)
    let probe = ParallelismProbe()
    let tasks = try ["arm64", "x86_64"].map { name in
        let output = root.appending(name)
        return TaskDeclaration(
            id: TaskID(rawValue: "fixture.oci.\(name)"),
            component: ComponentID(rawValue: "fixture"),
            outputs: [OutputDeclaration(path: output, validation: .regularFile)],
            action: try AnyColliderAction(
                ParallelismProbeAction(
                    identity: ParallelismProbeIdentity(name: name),
                    probe: probe,
                    output: output,
                    lane: .oci)))
    }

    _ = try await ColliderEngine(runtime: ColliderRuntime()).execute(
        graph: TaskGraph(tasks),
        selected: tasks.map(\.id),
        stateRoot: root.appending("state"),
        options: TaskExecutionOptions(
            laneLimits: TaskLaneLimits(lightweight: 1, oci: 2)))

    #expect(await probe.maximum() == 2)
}

@Test func crossProcessLockAdmissionIsCancellationAware() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-engine-lock-cancellation-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = FilePath(directory.path)
    let lockPath = root.appending("shared.lock")
    let blocker = try ColliderFileLock(
        path: lockPath,
        purpose: "fixture blocker")
    defer { withExtendedLifetime(blocker) {} }
    let output = root.appending("output")
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.lock-cancellation"),
        component: ComponentID(rawValue: "fixture"),
        outputs: [OutputDeclaration(path: output, validation: .regularFile)],
        locks: [.shared(lockPath)],
        action: try AnyColliderAction(
            ParallelismProbeAction(
                identity: ParallelismProbeIdentity(name: "cancelled"),
                probe: ParallelismProbe(),
                output: output)))
    let cancellation = RuntimeCancellation()
    let runtime = ColliderRuntime(cancellation: cancellation)
    let execution = Task {
        try await ColliderEngine(runtime: runtime).execute(
            graph: TaskGraph([task]),
            selected: [task.id],
            stateRoot: root.appending("state"))
    }
    try await ContinuousClock().sleep(for: .milliseconds(50))
    await cancellation.interruptAll()

    await #expect(throws: CancellationError.self) {
        _ = try await execution.value
    }
    #expect(!FileManager.default.fileExists(atPath: output.string))
}

@Test func cancellingALockOwningTaskReleasesItsKernelLock() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-engine-held-lock-cancellation-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = FilePath(directory.path)
    let lockPath = root.appending("shared.lock")
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.held-lock-cancellation"),
        component: ComponentID(rawValue: "fixture"),
        locks: [.shared(lockPath)],
        assessmentPolicy: .always,
        action: try fixtureCommandAction(
            CommandSpec(
                executable: .named("sh"),
                arguments: ["-c", "sleep 30"],
                workingDirectory: root,
                environment: ["PATH": "/usr/bin:/bin"],
                output: .captured(limit: 1_024))))
    let cancellation = RuntimeCancellation()
    let execution = Task {
        try await ColliderEngine(
            runtime: ColliderRuntime(cancellation: cancellation)
        ).execute(
            graph: TaskGraph([task]),
            selected: [task.id],
            stateRoot: root.appending("state"))
    }
    for _ in 0..<100 where ColliderFileLock.holder(at: lockPath) == nil {
        try await ContinuousClock().sleep(for: .milliseconds(10))
    }
    #expect(ColliderFileLock.holder(at: lockPath) != nil)
    await cancellation.interruptAll()

    await #expect(throws: (any Error).self) {
        _ = try await execution.value
    }
    let replacement = try ColliderFileLock(
        path: lockPath,
        purpose: "replacement after cancellation",
        waitForExistingOwner: false)
    withExtendedLifetime(replacement) {}
}

@Test func failedTaskNeverPublishesSuccessfulTaskState() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-engine-failed-state-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = FilePath(directory.path)
    let output = root.appending("output")
    let stateRoot = root.appending("state")
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.fail-after-write"),
        component: ComponentID(rawValue: "fixture"),
        outputs: [OutputDeclaration(path: output, validation: .regularFile)],
        action: try AnyColliderAction(FailAfterWriteAction(output: output)))

    await #expect(throws: ExecutionFailure.self) {
        _ = try await ColliderEngine(runtime: ColliderRuntime()).execute(
            graph: TaskGraph([task]),
            selected: [task.id],
            stateRoot: stateRoot)
    }
    #expect(FileManager.default.fileExists(atPath: output.string))
    #expect(
        !FileManager.default.fileExists(
            atPath: TaskStateStore(root: stateRoot).path(for: task.id).string))
}

@Test func unselectedToolsAreNotResolvedAndPlanOrderIsDeterministic() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-selected-closure-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = FilePath(directory.path)
    let selected = TaskDeclaration(
        id: TaskID(rawValue: "fixture.selected"),
        component: ComponentID(rawValue: "fixture"),
        action: try fixtureCreateDirectoryAction(root.appending("selected")))
    let unselected = TaskDeclaration(
        id: TaskID(rawValue: "fixture.unselected"),
        component: ComponentID(rawValue: "fixture"),
        inputs: [.tool(.named("collider-intentionally-missing-tool"))],
        action: try fixtureCommandAction(
            CommandSpec(
                executable: .named("collider-intentionally-missing-tool"),
                arguments: [],
                workingDirectory: root,
                environment: [:])))
    let unselectedContainer = TaskDeclaration(
        id: TaskID(rawValue: "fixture.unselected-container"),
        component: ComponentID(rawValue: "fixture"),
        action: try fixturePrepareOCIImageAction(
            OCIImagePreparation(
                executionPlatform: ExecutionPlatform(
                    environment: .native,
                    operatingSystem: .android,
                    architecture: .arm64),
                context: root,
                containerFile: root.appending("missing-Containerfile"),
                imageID: root.appending("missing-image"),
                imageName: "unselected-fixture",
                environment: [:])))

    let first = try await ColliderEngine(runtime: ColliderRuntime()).execute(
        graph: TaskGraph([selected, unselected, unselectedContainer]),
        selected: [selected.id],
        stateRoot: root.appending("state"),
        options: TaskExecutionOptions(dryRun: true))
    let second = try await ColliderEngine(runtime: ColliderRuntime()).execute(
        graph: TaskGraph([unselectedContainer, unselected, selected]),
        selected: [selected.id],
        stateRoot: root.appending("state"),
        options: TaskExecutionOptions(dryRun: true))

    #expect(first.plan.map(\.task) == [selected.id])
    #expect(second.plan.map(\.task) == [selected.id])
    #expect(first.plan.map(\.identity) == second.plan.map(\.identity))
}

@Test func dryRunPlanningDoesNotWriteItsStateRoot() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-read-only-dry-run-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }
    let input = directory.appendingPathComponent("input")
    try Data("fixture\n".utf8).write(to: input)
    let stateRoot = directory.appendingPathComponent("state")
    try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o500], ofItemAtPath: stateRoot.path)
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.read-only-dry-run"),
        component: ComponentID(rawValue: "fixture"),
        inputs: [.file(FilePath(input.path))])

    let report = try await ColliderEngine(runtime: ColliderRuntime()).execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(stateRoot.path),
        options: TaskExecutionOptions(dryRun: true))

    #expect(report.plan.map(\.task) == [task.id])
    #expect(
        !FileManager.default.fileExists(
            atPath: stateRoot.appendingPathComponent("artifact-digests.json").path))
}

@Test func completedExecutionFeedsTheNextStableWorkloadEstimate() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-duration-history-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = FilePath(directory.path)
    let stateRoot = root.appending("state")
    let output = root.appending("output")
    let taskID = TaskID(rawValue: "fixture.duration-history")
    func task(identity: String) throws -> TaskDeclaration {
        TaskDeclaration(
            id: taskID,
            component: ComponentID(rawValue: "fixture"),
            assessmentPolicy: .always,
            durationEstimationMode: "release",
            action: try AnyColliderAction(
                ParallelismProbeAction(
                    identity: ParallelismProbeIdentity(name: identity),
                    probe: ParallelismProbe(),
                    output: output)))
    }

    let first = try await ColliderEngine(runtime: ColliderRuntime()).execute(
        graph: TaskGraph([try task(identity: "source-a")]),
        selected: [taskID],
        stateRoot: stateRoot)
    #expect(first.plan.first?.durationEstimate == nil)
    let firstDuration = try #require(first.taskTimings.first?.durationNanoseconds)

    let second = try await ColliderEngine(runtime: ColliderRuntime()).execute(
        graph: TaskGraph([try task(identity: "source-b")]),
        selected: [taskID],
        stateRoot: stateRoot)
    #expect(second.plan.first?.identity != first.plan.first?.identity)
    #expect(second.plan.first?.durationEstimate?.durationNanoseconds == firstDuration)
}

@Test func taskOutputPresentationMapsDefaultVerboseQuietAndRawOutput() {
    #expect(
        TaskOutputPresentation.default.output(for: .inherited)
            == CommandSpec.Output.logged)
    #expect(
        TaskOutputPresentation.verbose.output(for: .logged)
            == CommandSpec.Output.inherited)
    #expect(
        TaskOutputPresentation.quiet.output(for: .inherited)
            == CommandSpec.Output.logged)
    #expect(
        TaskOutputPresentation.default.output(for: .captured(limit: 4096))
            == CommandSpec.Output.captured(limit: 4096))
    #expect(
        TaskOutputPresentation.quiet.output(for: .file(FilePath("/tmp/output")))
            == CommandSpec.Output.file(FilePath("/tmp/output")))
    #expect(
        TaskOutputPresentation.raw.output(for: .terminal)
            == CommandSpec.Output.terminal)
    #expect(
        TaskOutputPresentation.raw.output(for: .captured(limit: 4096))
            == CommandSpec.Output.terminal)
}

@Test func taskIdentitySurvivesAShellSearchPathThatChangesEveryInvocation()
    async throws
{
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-engine-path-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let tool = FilePath("/usr/bin/env")
    func task(searchPath: String, language: String) throws -> TaskDeclaration {
        TaskDeclaration(
            id: TaskID(rawValue: "fixture.search-path"),
            component: ComponentID(rawValue: "fixture"),
            inputs: [.tool(.path(tool))],
            action: try fixtureCommandAction(
                CommandSpec(
                    executable: .path(tool),
                    arguments: ["true"],
                    workingDirectory: FilePath(directory.path),
                    environment: ["PATH": searchPath, "LANG": language])))
    }
    func identity(of task: TaskDeclaration) async throws -> ArtifactDigest {
        try await ColliderEngine(runtime: ColliderRuntime()).execute(
            graph: TaskGraph([task]),
            selected: [task.id],
            stateRoot: FilePath(directory.appendingPathComponent("state").path),
            options: TaskExecutionOptions(dryRun: true)
        ).plan[0].identity
    }

    let first = try await identity(
        of: try task(
            searchPath: "/run/shim/98431_1785277689021:/usr/bin", language: "C"))
    let relaunched = try await identity(
        of: try task(
            searchPath: "/run/shim/98452_1785277711088:/usr/bin", language: "C"))
    let reconfigured = try await identity(
        of: try task(
            searchPath: "/run/shim/98431_1785277689021:/usr/bin", language: "en_US"))

    #expect(first == relaunched)
    #expect(first != reconfigured)
}

@Test func namedToolIdentityUsesTheCanonicalExecutableBehindTransientShims()
    async throws
{
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-engine-tool-shim-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let installation = directory.appendingPathComponent("installation/bin")
    let firstShim = directory.appendingPathComponent("shim-1")
    let secondShim = directory.appendingPathComponent("shim-2")
    for path in [installation, firstShim, secondShim] {
        try FileManager.default.createDirectory(
            at: path, withIntermediateDirectories: true)
    }
    let tool = installation.appendingPathComponent("fixture-tool")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: tool)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: tool.path)
    for shim in [firstShim, secondShim] {
        try FileManager.default.createSymbolicLink(
            atPath: shim.appendingPathComponent("fixture-tool").path,
            withDestinationPath: tool.path)
    }
    func identity(searchRoot: URL) async throws -> ArtifactDigest {
        let task = TaskDeclaration(
            id: TaskID(rawValue: "fixture.named-tool"),
            component: ComponentID(rawValue: "fixture"),
            inputs: [.tool(.named("fixture-tool"))],
            action: try fixtureCommandAction(
                CommandSpec(
                    executable: .named("fixture-tool"),
                    arguments: [],
                    workingDirectory: FilePath(directory.path),
                    environment: ["PATH": searchRoot.path])))
        return try await ColliderEngine(runtime: ColliderRuntime()).execute(
            graph: TaskGraph([task]),
            selected: [task.id],
            stateRoot: FilePath(directory.appendingPathComponent("state").path),
            options: TaskExecutionOptions(dryRun: true)
        ).plan[0].identity
    }

    let first = try await identity(searchRoot: firstShim)
    let second = try await identity(searchRoot: secondShim)

    #expect(first == second)
}

@Test func operationalCommandIdentityDoesNotContainTheAmbientExecutable() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-operational-tool-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    func identity(path: String) async throws -> ArtifactDigest {
        let task = TaskDeclaration(
            id: TaskID(rawValue: "fixture.operational-tool"),
            component: ComponentID(rawValue: "fixture"),
            action: try fixtureCommandAction(
                CommandSpec(
                    executable: .operationalNamed("materializer"),
                    arguments: ["--verify-exact-revision"],
                    workingDirectory: FilePath(directory.path),
                    environment: ["PATH": path, "LANG": "C"])))
        return try await ColliderEngine(runtime: ColliderRuntime()).execute(
            graph: TaskGraph([task]),
            selected: [task.id],
            stateRoot: FilePath(directory.appendingPathComponent("state").path),
            options: TaskExecutionOptions(dryRun: true)
        ).plan[0].identity
    }

    let first = try await identity(path: "/first/host/bin")
    let second = try await identity(path: "/second/host/bin")
    #expect(first == second)
}

@Test func taskIdentityEncodingRemainsByteStableAcrossWorkflowMoves() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-engine-identity-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = FilePath("/nucleus/identity-fixture/output")
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.identity"),
        component: ComponentID(rawValue: "fixture"),
        inputs: [
            .value(name: "configuration", bytes: Array("stable-v1".utf8)),
            .environment(name: "MODE", value: "release"),
        ],
        outputs: [
            OutputDeclaration(path: output, validation: .regularFile)
        ],
        action: try fixtureWriteAction(output, bytes: Array("payload\n".utf8)))
    let report = try await ColliderEngine(runtime: ColliderRuntime()).execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(directory.appendingPathComponent("state").path),
        options: TaskExecutionOptions(dryRun: true))

    // Every cached task in every build store is keyed by this encoding, so a
    // digest that moves without an intended change to what identity covers
    // silently discards all of them. Update the constant only alongside such a
    // change, never to make the test agree with what the encoder now emits.
    #expect(
        report.plan[0].identity.description
            == "sha256:3493e04dc9b66f3f85bb84119533c5c3a2f9e791ca23d176a1574cf4df2289a5")
}

@Test func taskEngineExplainsInvalidationAndThenSkipsCleanWork() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-engine-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appendingPathComponent("output")
    let command = CommandSpec(
        executable: .named("sh"),
        arguments: ["-c", "printf result > \"$1\"", "sh", output.path],
        workingDirectory: FilePath(directory.path),
        environment: ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"])
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.write"),
        component: ComponentID(rawValue: "fixture"),
        inputs: [.value(name: "content", bytes: Array("result".utf8))],
        outputs: [OutputDeclaration(path: FilePath(output.path), validation: .regularFile)],
        action: try fixtureCommandAction(command))
    let graph = try TaskGraph([task])
    let runtime = ColliderRuntime()
    let state = FilePath(directory.appendingPathComponent("state").path)
    let first = try await ColliderEngine(runtime: runtime).execute(
        graph: graph, selected: [task.id], stateRoot: state)
    #expect(first.executed == [task.id])
    #expect(first.plan[0].explanation == "no prior task state")
    let second = try await ColliderEngine(runtime: runtime).execute(
        graph: graph, selected: [task.id], stateRoot: state)
    #expect(second.executed.isEmpty)
    #expect(second.plan[0].isClean)
    let rebuilt = try await ColliderEngine(runtime: runtime).execute(
        graph: graph,
        selected: [task.id],
        stateRoot: state,
        options: TaskExecutionOptions(rebuildSelected: true))
    #expect(rebuilt.executed == [task.id])
    #expect(!rebuilt.plan[0].isClean)
    #expect(rebuilt.plan[0].explanation == "rebuild requested for selected task")
}

@Test func executableOutputValidationFollowsTheDeclaredSymlink() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-engine-executable-symlink-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("swift-driver")
    let link = directory.appendingPathComponent("swift")
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.executable-symlink"),
        component: ComponentID(rawValue: "fixture"),
        outputs: [
            OutputDeclaration(
                path: FilePath(link.path),
                validation: .executableFile)
        ],
        action: try fixtureCommandAction(
            CommandSpec(
                executable: .named("sh"),
                arguments: [
                    "-c",
                    "printf '#!/bin/sh\\n' > \"$1\" && chmod 755 \"$1\" && "
                        + "ln -s swift-driver \"$2\"",
                    "sh",
                    executable.path,
                    link.path,
                ],
                workingDirectory: FilePath(directory.path),
                environment: [
                    "PATH": ProcessInfo.processInfo.environment["PATH"]
                        ?? "/usr/bin:/bin"
                ])))
    _ = try await ColliderEngine(runtime: ColliderRuntime()).execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(directory.appendingPathComponent("state").path))
    _ = try await ColliderEngine(runtime: ColliderRuntime()).execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(directory.appendingPathComponent("state").path))

    #expect(
        try FileManager.default.destinationOfSymbolicLink(
            atPath: link.path) == "swift-driver")
}

@Test func taskIdentityIncludesActionEnvironment() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-engine-run-environment-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appendingPathComponent("output")
    let state = FilePath(directory.appendingPathComponent("state").path)
    let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"

    func task(runDirectory: String) throws -> TaskDeclaration {
        TaskDeclaration(
            id: TaskID(rawValue: "fixture.run-environment"),
            component: ComponentID(rawValue: "fixture"),
            outputs: [
                OutputDeclaration(
                    path: FilePath(output.path),
                    validation: .regularFile)
            ],
            action: try fixtureCommandAction(
                CommandSpec(
                    executable: .named("sh"),
                    arguments: ["-c", "printf result > \"$1\"", "sh", output.path],
                    workingDirectory: FilePath(directory.path),
                    environment: [
                        "PATH": path,
                        "NUCLEUS_RUN_DIR": runDirectory,
                        "NUCLEUS_RUN_LOG": runDirectory + "/run.log",
                    ])))
    }

    let runtime = ColliderRuntime()
    let first = try task(runDirectory: "/runs/first")
    _ = try await ColliderEngine(runtime: runtime).execute(
        graph: TaskGraph([first]), selected: [first.id], stateRoot: state)
    let second = try task(runDirectory: "/runs/second")
    let report = try await ColliderEngine(runtime: runtime).execute(
        graph: TaskGraph([second]), selected: [second.id], stateRoot: state)
    #expect(report.executed == [second.id])
    #expect(!report.plan[0].isClean)
}

@Test func outputContractChangesInvalidatePriorTaskState() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-engine-output-contract-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appendingPathComponent("output")
    let state = FilePath(directory.appendingPathComponent("state").path)
    let command = CommandSpec(
        executable: .named("sh"),
        arguments: ["-c", "printf result > \"$1\"", "sh", output.path],
        workingDirectory: FilePath(directory.path),
        environment: [
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        ])

    func task(validation: OutputDeclaration.Validation) throws -> TaskDeclaration {
        TaskDeclaration(
            id: TaskID(rawValue: "fixture.output-contract"),
            component: ComponentID(rawValue: "fixture"),
            outputs: [
                OutputDeclaration(
                    path: FilePath(output.path),
                    validation: validation)
            ],
            action: try fixtureCommandAction(command))
    }

    let runtime = ColliderRuntime()
    let first = try task(validation: .exists)
    _ = try await ColliderEngine(runtime: runtime).execute(
        graph: TaskGraph([first]), selected: [first.id], stateRoot: state)
    let changed = try task(validation: .regularFile)
    let report = try await ColliderEngine(runtime: runtime).execute(
        graph: TaskGraph([changed]), selected: [changed.id], stateRoot: state)
    #expect(report.executed == [changed.id])
    #expect(report.plan[0].explanation.hasPrefix("input identity changed "))
}

@Test func uncommittedSourceContentsInvalidatePriorTaskState() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-engine-source-content-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source")
    let output = directory.appendingPathComponent("output")
    try Data("first".utf8).write(to: source)
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.source-content"),
        component: ComponentID(rawValue: "fixture"),
        inputs: [.file(FilePath(source.path))],
        outputs: [
            OutputDeclaration(
                path: FilePath(output.path), validation: .regularFile)
        ],
        action: try fixtureCommandAction(
            CommandSpec(
                executable: .named("sh"),
                arguments: [
                    "-c", "cp \"$1\" \"$2\"", "sh", source.path, output.path,
                ],
                workingDirectory: FilePath(directory.path),
                environment: [
                    "PATH": ProcessInfo.processInfo.environment["PATH"]
                        ?? "/usr/bin:/bin"
                ])))
    let runtime = ColliderRuntime()
    let graph = try TaskGraph([task])
    let state = FilePath(directory.appendingPathComponent("state").path)
    _ = try await ColliderEngine(runtime: runtime).execute(
        graph: graph, selected: [task.id], stateRoot: state)
    try Data("second".utf8).write(to: source)

    let report = try await ColliderEngine(runtime: runtime).execute(
        graph: graph, selected: [task.id], stateRoot: state)
    #expect(report.executed == [task.id])
    #expect(report.plan[0].explanation.hasPrefix("input identity changed "))
    #expect(try String(contentsOf: output, encoding: .utf8) == "second")
}

@Test func oneActionOwnsOrderedFilesystemMutation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-engine-sequence-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let candidate = FilePath(directory.appendingPathComponent("candidate").path)
    try FileManager.default.createDirectory(
        atPath: candidate.string, withIntermediateDirectories: true)
    try Data("stale".utf8).write(
        to: URL(fileURLWithPath: candidate.appending("stale").string))
    let payload = candidate.appending("payload")
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.sequence"),
        component: ComponentID(rawValue: "fixture"),
        outputs: [
            OutputDeclaration(path: payload, validation: .regularFile)
        ],
        action: try fixturePrepareAndWriteAction(
            root: candidate,
            file: payload,
            bytes: Array("fresh".utf8),
            reset: true))

    let report = try await ColliderEngine(runtime: ColliderRuntime()).execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(directory.appendingPathComponent("state").path))
    #expect(report.executed == [task.id])
    #expect(
        !FileManager.default.fileExists(
            atPath: candidate.appending("stale").string))
    #expect(
        try String(
            contentsOf: URL(fileURLWithPath: payload.string),
            encoding: .utf8) == "fresh")
}

@Test func invalidGenerationCandidateNeverReplacesTheActivePointer() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-generation-rollback-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let previous = directory.appendingPathComponent("generation-previous")
    let candidate = directory.appendingPathComponent("candidate")
    let generation = directory.appendingPathComponent("generation-invalid")
    let active = directory.appendingPathComponent("active")
    try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        atPath: active.path,
        withDestinationPath: "generation-previous")
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.publish-invalid"),
        component: ComponentID(rawValue: "fixture"),
        outputs: [
            OutputDeclaration(
                path: FilePath(generation.path),
                validation: .nonEmptyDirectory),
            OutputDeclaration(path: FilePath(active.path), validation: .exists),
        ],
        action: try fixtureActivateGenerationAction(
            candidate: FilePath(candidate.path),
            generation: FilePath(generation.path),
            active: FilePath(active.path)))

    await #expect(throws: (any Error).self) {
        try await ColliderEngine(runtime: ColliderRuntime()).execute(
            graph: TaskGraph([task]),
            selected: [task.id],
            stateRoot: FilePath(directory.appendingPathComponent("state").path))
    }
    #expect(FileManager.default.fileExists(atPath: candidate.path))
    #expect(!FileManager.default.fileExists(atPath: generation.path))
    #expect(
        try FileManager.default.destinationOfSymbolicLink(atPath: active.path)
            == "generation-previous")
}

@Test func taskEnginePublishesAndAtomicallyActivatesImmutableGeneration() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-generation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let candidate = directory.appendingPathComponent("candidate")
    let generation = directory.appendingPathComponent("generation-1")
    let active = directory.appendingPathComponent("active")
    try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
    try Data("artifact".utf8).write(to: candidate.appendingPathComponent("payload"))
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.publish"),
        component: ComponentID(rawValue: "fixture"),
        outputs: [
            OutputDeclaration(
                path: FilePath(generation.path),
                validation: .nonEmptyDirectory),
            OutputDeclaration(path: FilePath(active.path), validation: .exists),
        ],
        action: try fixtureActivateGenerationAction(
            candidate: FilePath(candidate.path),
            generation: FilePath(generation.path),
            active: FilePath(active.path)))

    let report = try await ColliderEngine(runtime: ColliderRuntime()).execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(directory.appendingPathComponent("state").path))
    #expect(report.executed == [task.id])
    #expect(!FileManager.default.fileExists(atPath: candidate.path))
    #expect(
        try FileManager.default.destinationOfSymbolicLink(atPath: active.path)
            == "generation-1")
    #expect(
        try String(
            contentsOf: generation.appendingPathComponent("payload"),
            encoding: .utf8) == "artifact")
}

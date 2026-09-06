import ColliderCore
import Foundation
import SystemPackage
import Testing

@testable import ColliderPersistence

private enum ObservationFixtureFailure: Error {
    case stopped
}

@Test func historicalRunPlansAreMigratedOnceWithoutLosingEvidence() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = RunRegistry(root: FilePath(directory.path))
    let run = try await registry.begin(command: ["collider", "verify", "fixture"])
    let identity = ArtifactDigest.sha256([UInt8]("historical".utf8))
    try await registry.recordPlan(
        [
            TaskPlanEntry(
                task: TaskID(rawValue: "fixture.task"), identity: identity,
                isClean: false,
                explanation: "historical assessment", coordinates: nil)
        ], in: run)
    try await registry.recordTaskOutcome(
        .executed,
        task: TaskID(rawValue: "fixture.task"),
        in: run)
    try await registry.finish(run, status: .succeeded)
    let path = directory.appendingPathComponent("runs/\(run.id.rawValue)/manifest.json")
    var object = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
    var tasks = try #require(object["tasks"] as? [String: [String: Any]])
    var task = try #require(tasks["fixture.task"])
    var plan = try #require(task["plan"] as? [String: Any])
    for field in ["recipeIdentity", "isDeferred", "isForced"] { plan.removeValue(forKey: field) }
    task["plan"] = plan
    tasks["fixture.task"] = task
    object["tasks"] = tasks
    try JSONSerialization.data(withJSONObject: object).write(to: path)
    let records = try await registry.recordedRuns()
    let restored = try #require(records.first?.manifest.tasks?["fixture.task"])
    #expect(restored.plan.identity == identity)
    #expect(restored.outcome == .executed)
    #expect(restored.plan.explanation == "historical assessment")
    let migrated = try Data(contentsOf: path)
    _ = try JSONDecoder().decode(RunManifest.self, from: migrated)
    _ = try await registry.recordedRuns()
    #expect(try Data(contentsOf: path) == migrated)
}

@Test func hostPhaseRecorderPersistsStartedProgressAndTerminalEvents() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-host-phase-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = RunRegistry(root: FilePath(directory.path))
    let run = try await registry.begin(command: ["collider", "cache", "status"])
    let recorder = HostPhaseRecorder(registry: registry, run: run)
    let phase = try await recorder.begin("measuring storage", totalItems: 3)
    try await recorder.advance(phase, completedItems: 2, totalItems: 3)
    try await recorder.finish(phase)
    try await registry.finish(run, status: .succeeded)

    let eventsURL = directory.appendingPathComponent(
        "runs/\(run.id.rawValue)/events.jsonl")
    let events = try String(decoding: Data(contentsOf: eventsURL), as: UTF8.self)
        .split(separator: "\n")
        .map { try JSONDecoder().decode(RunEvent.self, from: Data($0.utf8)) }
    #expect(events.count == 5)
    #expect(
        events[1].payload
            == .hostPhase(
                .started(id: phase, name: "measuring storage", totalItems: 3)))
    #expect(
        events[2].payload
            == .hostPhase(.advanced(id: phase, completedItems: 2, totalItems: 3)))
    #expect(events[3].payload == .hostPhase(.finished(phase)))
}

@Test func independentProgressReplayIsReadOnlyForActiveAndFinishedRuns() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-progress-replay-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let writer = RunRegistry(root: FilePath(directory.path))
    let run = try await writer.begin(command: ["collider", "build", "fixture"])
    let task = TaskID(rawValue: "fixture.build")
    try await writer.recordPlan(
        [
            TaskPlanEntry(
                task: task,
                identity: ArtifactDigest(bytes: [1]),
                isClean: false,
                explanation: "fixture",
                coordinates: nil,
                lane: .hostExclusive)
        ],
        in: run)
    try await writer.record(.task(.started(task)), in: run)
    let manifestURL = directory.appendingPathComponent(
        "runs/\(run.id.rawValue)/manifest.json")
    let eventsURL = directory.appendingPathComponent(
        "runs/\(run.id.rawValue)/events.jsonl")
    let manifestBefore = try Data(contentsOf: manifestURL)
    let eventsBefore = try Data(contentsOf: eventsURL)

    let reader = RunRegistry(root: FilePath(directory.path))
    let activeRecord = try await reader.recordedRun(run.id)
    let active = try await reader.progressSnapshot(
        in: activeRecord,
        at: Date(timeIntervalSinceNow: 60))

    #expect(active.phase == .executing)
    #expect(active.activeRows.map(\.task) == [task])
    #expect(active.activeRows.first?.lane == .hostExclusive)
    #expect(try Data(contentsOf: manifestURL) == manifestBefore)
    #expect(try Data(contentsOf: eventsURL) == eventsBefore)

    try await writer.record(.task(.succeeded(task)), in: run)
    try await writer.finish(run, status: .succeeded)
    let finishedRecord = try await reader.recordedRun(run.id)
    let first = try await reader.progressSnapshot(
        in: finishedRecord,
        at: Date(timeIntervalSinceNow: 120))
    let later = try await reader.progressSnapshot(
        in: finishedRecord,
        at: Date(timeIntervalSinceNow: 1_200))
    #expect(first.phase == .succeeded)
    #expect(first.completionFraction == 1)
    #expect(first.elapsedNanoseconds == later.elapsedNanoseconds)
}

@Test func runRegistryPublishesPersistedPlanAndEventsInOrder() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-observation-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = RunRegistry(root: FilePath(directory.path))
    let stream = try await registry.observations()
    let collector = Task {
        var observed: [RunObservation] = []
        for await observation in stream { observed.append(observation) }
        return observed
    }

    let run = try await registry.begin(command: ["collider", "build", "fixture"])
    let task = TaskID(rawValue: "fixture.build")
    let plan = TaskPlanEntry(
        task: task,
        identity: ArtifactDigest(bytes: [UInt8](repeating: 7, count: 32)),
        isClean: false,
        explanation: "fixture",
        coordinates: nil)
    try await registry.recordPlan([plan], in: run)
    try await registry.record(.task(.started(task)), in: run)
    try await registry.finish(run, status: .succeeded)

    let observed = await collector.value
    #expect(observed.count == 4)
    guard case .event(let started) = observed[0],
        case .runStarted(resumed: false) = started.payload
    else {
        Issue.record("the persisted run-start event was not observed first")
        return
    }
    guard case .plan(let frozenPlan) = observed[1] else {
        Issue.record("the frozen plan was not observed after persistence")
        return
    }
    #expect(frozenPlan.runID == run.id)
    #expect(frozenPlan.entries.count == 1)
    #expect(frozenPlan.entries[0].task == task)
    guard case .event(let taskStarted) = observed[2],
        case .task(.started(let observedTask)) = taskStarted.payload
    else {
        Issue.record("the task event was not observed")
        return
    }
    #expect(observedTask == task)
    guard case .event(let terminal) = observed[3],
        case .terminal(let terminalEvent) = terminal.payload
    else {
        Issue.record("the terminal event was not observed last")
        return
    }
    #expect(terminalEvent.status == .succeeded)

    let eventsURL = directory.appendingPathComponent(
        "runs/\(run.id.rawValue)/events.jsonl")
    let durableData = try Data(contentsOf: eventsURL)
    let durableEvents = try String(decoding: durableData, as: UTF8.self)
        .split(separator: "\n")
        .map { try JSONDecoder().decode(RunEvent.self, from: Data($0.utf8)) }
    let observedEvents = observed.compactMap { observation -> RunEvent? in
        guard case .event(let event) = observation else { return nil }
        return event
    }
    #expect(observedEvents == durableEvents)
    #expect(try Data(contentsOf: eventsURL) == durableData)
}

@Test func slowAndFailingRunObserversCannotAffectPersistence() async throws {
    let slowDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-slow-observation-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: slowDirectory) }
    let slowRegistry = RunRegistry(root: FilePath(slowDirectory.path))
    let slowStream = try await slowRegistry.observations()
    let slowRun = try await slowRegistry.begin(command: ["collider", "doctor"])
    for index in 0..<64 {
        try await slowRegistry.record(
            .operation(
                .started(
                    OperationContext(
                        task: nil,
                        operation: "fixture-\(index)",
                        command: ["true"],
                        invocation: "true",
                        workingDirectory: "/tmp",
                        logPath: nil))),
            in: slowRun)
    }
    try await slowRegistry.finish(slowRun, status: .succeeded)
    var slowObservations: [RunObservation] = []
    for await observation in slowStream { slowObservations.append(observation) }
    #expect(slowObservations.count == 66)
    #expect(try await slowRegistry.recordedRun(slowRun.id).manifest.status == .succeeded)

    let failingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-failing-observation-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: failingDirectory) }
    let failingRegistry = RunRegistry(root: FilePath(failingDirectory.path))
    let failingStream = try await failingRegistry.observations()
    let failingConsumer = Task<Void, any Error> {
        for await _ in failingStream { throw ObservationFixtureFailure.stopped }
    }
    let failingRun = try await failingRegistry.begin(command: ["collider", "doctor"])
    await #expect(throws: ObservationFixtureFailure.self) {
        try await failingConsumer.value
    }
    try await failingRegistry.record(
        .task(.started(TaskID(rawValue: "doctor.host"))),
        in: failingRun)
    try await failingRegistry.finish(failingRun, status: .succeeded)
    let recordedRun = try await failingRegistry.recordedRun(failingRun.id)
    #expect(recordedRun.manifest.status == .succeeded)
    let eventsData = try Data(
        contentsOf: failingDirectory.appendingPathComponent(
            "runs/\(failingRun.id.rawValue)/events.jsonl"))
    let events = try String(decoding: eventsData, as: UTF8.self)
        .split(separator: "\n")
        .map { try JSONDecoder().decode(RunEvent.self, from: Data($0.utf8)) }
    #expect(events.count == 3)
}

@Test func runRegistryPublishesManifestEventsAndLatest() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-registry-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = RunRegistry(root: FilePath(directory.path))
    let run = try await registry.begin(command: ["collider", "doctor"])
    try await registry.record(
        .task(.started(TaskID(rawValue: "doctor.host"))),
        in: run)
    try await registry.appendLog(Array("diagnostic\n".utf8), in: run)
    try await registry.recordExecutionMetrics(
        criticalPathDurationNanoseconds: 123,
        schedulingWaitDurationNanoseconds: 45,
        in: run)
    try await registry.finish(run, status: .succeeded)

    let manifest = try JSONDecoder().decode(
        RunManifest.self,
        from: Data(
            contentsOf:
                directory
                .appendingPathComponent("runs/\(run.id.rawValue)/manifest.json")))
    #expect(manifest.status == .succeeded)
    #expect(manifest.criticalPathDurationNanoseconds == 123)
    #expect(manifest.schedulingWaitDurationNanoseconds == 45)
    #expect(
        try FileManager.default.destinationOfSymbolicLink(
            atPath: directory.appendingPathComponent("latest").path)
            == "runs/\(run.id.rawValue)")
    let events = try String(
        contentsOf:
            directory
            .appendingPathComponent("runs/\(run.id.rawValue)/events.jsonl"), encoding: .utf8)
    #expect(events.split(separator: "\n").count == 3)
    let decoded = try events.split(separator: "\n").map {
        try JSONDecoder().decode(RunEvent.self, from: Data($0.utf8))
    }
    let reduced = try RunEventReducer.reduce(decoded)
    #expect(reduced.status == .succeeded)
    #expect(reduced.tasks[TaskID(rawValue: "doctor.host")] == .running)
}

@Test func runRegistryReconcilesRunningRecordsWithoutAnOwnerLease() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-abandoned-run-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let id = RunID(rawValue: "abandoned")
    let runDirectory = directory.appendingPathComponent("runs/abandoned")
    try FileManager.default.createDirectory(
        at: runDirectory.appendingPathComponent("stages"),
        withIntermediateDirectories: true)
    let manifest = RunManifest(
        runID: id,
        command: ["collider", "build"],
        startedAt: "2026-08-11T00:00:00Z")
    try JSONEncoder().encode(manifest).write(
        to: runDirectory.appendingPathComponent("manifest.json"))

    let registry = RunRegistry(root: FilePath(directory.path))
    #expect(try await registry.reconcileAbandonedRuns() == [id])

    let snapshot = try await registry.recordedRun(id)
    #expect(snapshot.manifest.status == .interrupted)
    #expect(snapshot.manifest.finishedAt != nil)
    let observed = try await registry.reducedEvents(in: snapshot)
    #expect(observed.status == .interrupted)
}

@Test func runRegistryPreservesRunningRecordsWithAnOwnerLease() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-active-run-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let owner = RunRegistry(root: FilePath(directory.path))
    let run = try await owner.begin(command: ["collider", "build"])
    let observer = RunRegistry(root: FilePath(directory.path))

    #expect(try await observer.reconcileAbandonedRuns().isEmpty)
    #expect(try await observer.recordedRun(run.id).manifest.status == .running)

    try await owner.finish(run, status: .succeeded)
}

@Test func runRegistryPersistsOneUnifiedRecordPerPlannedTask() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-task-record-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = RunRegistry(root: FilePath(directory.path))
    let run = try await registry.begin(command: ["collider", "build", "fixture"])
    let task = TaskID(rawValue: "fixture.build")
    let identity = ArtifactDigest(bytes: [UInt8](repeating: 19, count: 32))
    let plan = TaskPlanEntry(
        task: task,
        identity: identity,
        isClean: false,
        explanation: "no prior task state",
        coordinates: TaskExecutionCoordinates(
            runner: .current,
            execution: .linuxARM64OCI,
            backend: .appleContainer,
            artifact: .linuxARM64))
    try await registry.recordPlan([plan], in: run)
    try await registry.recordTaskDuration(88, task: task, in: run)
    try await registry.recordTaskOutcome(.executed, task: task, in: run)

    let manifest = try JSONDecoder().decode(
        RunManifest.self,
        from: Data(
            contentsOf: directory.appendingPathComponent(
                "runs/\(run.id.rawValue)/manifest.json")))
    let record = try #require(manifest.tasks?[task.rawValue])
    #expect(record.plan.identity == identity)
    #expect(record.outcome == .executed)
    #expect(record.durationNanoseconds == 88)
    #expect(record.observations == nil)
}

@Test func runInspectionReadsCanonicalRecordsLogsAndAnIncompleteEventTail() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-inspection-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = RunRegistry(root: FilePath(directory.path))
    let run = try await registry.begin(command: ["collider", "build", "fixture"])
    let task = TaskID(rawValue: "fixture.build")
    try await registry.recordPlan(
        [
            TaskPlanEntry(
                task: task,
                identity: ArtifactDigest(bytes: [UInt8](repeating: 4, count: 32)),
                isClean: false,
                explanation: "fixture",
                coordinates: nil)
        ],
        in: run)
    try await registry.record(.task(.started(task)), in: run)
    try await registry.appendLog(Array("run output\n".utf8), in: run)
    try await registry.appendLog(Array("stage output\n".utf8), stage: task, in: run)

    let snapshots = try await registry.recordedRuns(limit: 1)
    let snapshot = try #require(snapshots.first)
    #expect(snapshot.manifest.runID == run.id)
    let logs = try await registry.logs(in: snapshot)
    #expect(logs.map(\.relativePath) == ["run.log", "stages/fixture-build.log"])
    #expect(logs.last?.task == task)

    let eventsPath = run.directory.appending("events.jsonl")
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: eventsPath.string))
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(#"{"sequence":2"#.utf8))
    try handle.close()

    let observed = try await registry.reducedEvents(in: snapshot)
    #expect(observed.status == .running)
    #expect(observed.tasks[task] == .running)
}

@Test func runInspectionBoundsIndividualEventMemory() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-inspection-bound-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = RunRegistry(root: FilePath(directory.path))
    _ = try await registry.begin(command: ["collider", "fixture"])
    let snapshot = try await registry.recordedRun()

    await #expect(throws: RunRegistryFailure.self) {
        try await registry.reducedEvents(in: snapshot, maximumEventBytes: 8)
    }
}

@Test func runRetentionPreservesActiveRecentAndNewestFailedRuns() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-retention-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let manager = FileManager.default
    let runs = directory.appendingPathComponent("runs")
    try manager.createDirectory(at: runs, withIntermediateDirectories: true)
    let overflow = 5
    let retained = 100
    let existing = retained + overflow
    func record(_ id: String, startedAt: String, status: RunStatus) throws {
        let run = runs.appendingPathComponent(id)
        try manager.createDirectory(at: run, withIntermediateDirectories: true)
        var manifest = RunManifest(
            runID: RunID(rawValue: id),
            command: ["collider", "doctor"],
            startedAt: startedAt)
        manifest.status = status
        try JSONEncoder().encode(manifest).write(
            to: run.appendingPathComponent("manifest.json"))
    }
    var oldest: [String] = []
    for index in 0..<existing {
        let id = "2026-01-01T00-00-00Z-\(1_000 + index)"
        let milliseconds = String(index)
        let paddedMilliseconds =
            String(repeating: "0", count: max(0, 3 - milliseconds.count))
            + milliseconds
        // The newest failed run is preserved in addition to recent terminal runs.
        try record(
            id,
            startedAt: "2026-01-01T00:00:00.\(paddedMilliseconds)Z",
            status: index == 0 ? .failed : .succeeded)
        oldest.append(id)
    }
    // A run still recording belongs to whoever is writing it.
    try record("2020-01-01T00-00-00Z-7", startedAt: "2020-01-01T00:00:00Z", status: .running)

    let registry = RunRegistry(root: FilePath(directory.path))
    let run = try await registry.begin(command: ["collider", "doctor"])
    let reclaimable = Set(
        await registry.reclaimableRuns(keeping: retained).map(\.id.rawValue))

    let remaining = Set(try manager.contentsOfDirectory(atPath: runs.path))
    #expect(remaining.contains(run.id.rawValue))
    #expect(remaining.contains("2020-01-01T00-00-00Z-7"))
    #expect(remaining.contains(oldest[0]))
    for id in oldest[1..<overflow] {
        #expect(remaining.contains(id))
        #expect(reclaimable.contains(id))
    }
    #expect(!reclaimable.contains(oldest[overflow]))
    #expect(remaining.contains(oldest[oldest.count - 1]))
}

@Test func localRunsCannotReclaimProtectedMainVerificationEvidence() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-verification-retention-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let manager = FileManager.default
    let runs = directory.appendingPathComponent("runs")
    try manager.createDirectory(at: runs, withIntermediateDirectories: true)
    let retained = 3
    func record(
        _ id: String,
        startedAt: String,
        status: RunStatus,
        provenance: RunProvenance
    ) throws {
        let run = runs.appendingPathComponent(id)
        try manager.createDirectory(at: run, withIntermediateDirectories: true)
        var manifest = RunManifest(
            runID: RunID(rawValue: id),
            command: ["collider", "build", "all"],
            startedAt: startedAt,
            provenance: provenance)
        manifest.status = status
        try JSONEncoder().encode(manifest).write(
            to: run.appendingPathComponent("manifest.json"))
    }
    func verification(_ commit: String) -> RunProvenance {
        RunProvenance(
            sourceAuthority: .protectedMain,
            sourceCommit: commit,
            producerTrustDomain: .nucleusBuilder)
    }

    let failedVerification = "2026-01-01T00-00-00Z-100"
    try record(
        failedVerification,
        startedAt: "2026-01-01T00:00:00.000Z",
        status: .failed,
        provenance: verification(String(repeating: "a", count: 40)))
    let succeededVerification = "2026-01-01T00-00-01Z-101"
    try record(
        succeededVerification,
        startedAt: "2026-01-01T00:00:01.000Z",
        status: .succeeded,
        provenance: verification(String(repeating: "b", count: 40)))

    // Far more local work than the retention window, including a local
    // failure, which under one shared window would displace both records
    // above.
    var local: [String] = []
    for index in 0..<(retained * 4) {
        let id = "2026-01-02T00-00-00Z-\(200 + index)"
        let milliseconds = String(index)
        let padded =
            String(repeating: "0", count: max(0, 3 - milliseconds.count)) + milliseconds
        try record(
            id,
            startedAt: "2026-01-02T00:00:00.\(padded)Z",
            status: index == 0 ? .failed : .succeeded,
            provenance: .local)
        local.append(id)
    }

    let registry = RunRegistry(root: FilePath(directory.path))
    let reclaimable = Set(
        await registry.reclaimableRuns(keeping: retained).map(\.id.rawValue))

    #expect(!reclaimable.contains(failedVerification))
    #expect(!reclaimable.contains(succeededVerification))
    #expect(reclaimable.contains(local[1]))
    for id in local.suffix(retained) {
        #expect(!reclaimable.contains(id))
    }
}

@Test func terminalizingARunAppliesRunRetention() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-terminal-retention-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let runs = directory.appendingPathComponent("runs")
    try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
    let oldIDs = ["oldest", "newer"]
    for (index, id) in oldIDs.enumerated() {
        let runDirectory = runs.appendingPathComponent(id)
        try FileManager.default.createDirectory(
            at: runDirectory,
            withIntermediateDirectories: true)
        var manifest = RunManifest(
            runID: RunID(rawValue: id),
            command: ["collider", "fixture"],
            startedAt: "2026-01-01T00:00:0\(index)Z")
        manifest.status = .succeeded
        try JSONEncoder().encode(manifest).write(
            to: runDirectory.appendingPathComponent("manifest.json"))
    }
    let registry = RunRegistry(root: FilePath(directory.path))
    let current = try await registry.begin(command: ["collider", "fixture"])
    try await registry.finish(
        current,
        status: .succeeded,
        retainingRuns: 2)

    #expect(!FileManager.default.fileExists(atPath: runs.appendingPathComponent(oldIDs[0]).path))
    #expect(FileManager.default.fileExists(atPath: runs.appendingPathComponent(oldIDs[1]).path))
    #expect(FileManager.default.fileExists(atPath: current.directory.string))
}

@Test func runManifestRoundTripsAllDurableTaskMetadata() throws {
    let runID = RunID(rawValue: "fixture-run")
    var manifest = RunManifest(
        runID: runID,
        command: ["collider", "build", "runtime"],
        startedAt: "2026-07-22T00:00:00Z")
    manifest.finishedAt = "2026-07-22T00:00:01Z"
    manifest.status = .failed
    manifest.failedTask = TaskID(rawValue: "runtime.build")
    manifest.planningDurationNanoseconds = 42
    manifest.selectedInputHashingDurationNanoseconds = 17
    manifest.swiftPMInvocationCount = 2
    manifest.executionDurationNanoseconds = 99
    let digest = ArtifactDigest(bytes: [UInt8](repeating: 7, count: 32))
    manifest.activeArtifacts = ["runtime": digest]
    let task = TaskID(rawValue: "runtime.build")
    let plan = TaskPlanEntry(
        task: task,
        identity: digest,
        isClean: false,
        explanation: "fixture",
        coordinates: nil,
        logicalOwners: [TaskID(rawValue: "runtime.logical")],
        attribution: "runtime release")
    manifest.tasks = [
        task.rawValue: RunTaskRecord(
            plan: plan,
            outcome: .executed,
            durationNanoseconds: 123,
            observations: TaskExecutionObservations(
                containerExecutions: [
                    OCIExecutionObservation(
                        imageDigest: digest,
                        executionPlatform: .linuxARM64OCI,
                        artifactTarget: .linuxX86_64,
                        userPolicy: .builder,
                        capabilityPolicy: .dropAll,
                        privilegePolicy: .prohibitAcquisition,
                        processFilesystemPolicy: .standard,
                        executableRequirements: [
                            OCIExecutableRequirement(
                                architecture: .x86_64,
                                executable: "/fixture/x86-tool")
                        ],
                        resourceLimits: .parallelBuild,
                        status: 0,
                        timings: OCIExecutionTimings(
                            configurationDurationNanoseconds: 1,
                            creationDurationNanoseconds: 2,
                            bootstrapDurationNanoseconds: 3,
                            processDurationNanoseconds: 4,
                            cleanupDurationNanoseconds: 5,
                            totalDurationNanoseconds: 15))
                ],
                actionStages: [
                    ActionStageObservation(
                        name: "fixture.materialization",
                        durationNanoseconds: 6,
                        inputByteCount: 7,
                        outputByteCount: 8)
                ],
                testCases: [
                    TestCaseObservation(
                        suite: "FixtureTests",
                        name: "fixturePasses",
                        durationNanoseconds: 9,
                        outcome: .passed)
                ]))
    ]
    manifest.resumedAt = ["2026-07-22T00:00:00.5Z"]
    manifest.resumeCount = 1

    let decoded = try JSONDecoder().decode(
        RunManifest.self, from: JSONEncoder().encode(manifest))
    #expect(decoded.runID == runID)
    #expect(decoded.command == manifest.command)
    #expect(decoded.startedAt == manifest.startedAt)
    #expect(decoded.finishedAt == manifest.finishedAt)
    #expect(decoded.status == manifest.status)
    #expect(decoded.failedTask == manifest.failedTask)
    #expect(
        decoded.planningDurationNanoseconds
            == manifest.planningDurationNanoseconds)
    #expect(
        decoded.selectedInputHashingDurationNanoseconds
            == manifest.selectedInputHashingDurationNanoseconds)
    #expect(decoded.swiftPMInvocationCount == manifest.swiftPMInvocationCount)
    #expect(
        decoded.executionDurationNanoseconds
            == manifest.executionDurationNanoseconds)
    #expect(decoded.activeArtifacts == manifest.activeArtifacts)
    let decodedTask = try #require(decoded.tasks?[task.rawValue])
    #expect(decodedTask.plan.identity == digest)
    #expect(decodedTask.plan.logicalOwners == [TaskID(rawValue: "runtime.logical")])
    #expect(decodedTask.plan.attribution == "runtime release")
    #expect(decodedTask.outcome == .executed)
    #expect(decodedTask.durationNanoseconds == 123)
    #expect(decodedTask.observations?.containerExecutions.first?.imageDigest == digest)
    #expect(
        decodedTask.observations?.containerExecutions.first?
            .executableRequirements == [
                OCIExecutableRequirement(
                    architecture: .x86_64,
                    executable: "/fixture/x86-tool")
            ])
    #expect(
        decodedTask.observations?.containerExecutions.first?.timings?
            .totalDurationNanoseconds == 15)
    #expect(
        decodedTask.observations?.actionStages == [
            ActionStageObservation(
                name: "fixture.materialization",
                durationNanoseconds: 6,
                inputByteCount: 7,
                outputByteCount: 8)
        ])
    #expect(
        decodedTask.observations?.testCases == [
            TestCaseObservation(
                suite: "FixtureTests",
                name: "fixturePasses",
                durationNanoseconds: 9,
                outcome: .passed)
        ])
    #expect(decoded.resumedAt == manifest.resumedAt)
    #expect(decoded.resumeCount == manifest.resumeCount)
}

@Test(arguments: [RunStatus.interrupted, .failed])
func unfinishedRunResumptionReusesOnlyMatchingCleanTaskIdentities(
    status: RunStatus
) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-resume-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = RunRegistry(root: FilePath(directory.path))
    let run = try await registry.begin(command: ["collider", "build", "core"])
    let original = [
        TaskPlanEntry(
            task: TaskID(rawValue: "core.build"),
            identity: ArtifactDigest(bytes: [UInt8](repeating: 1, count: 32)),
            isClean: false,
            explanation: "no prior task state",
            coordinates: nil)
    ]
    try await registry.recordPlan(original, in: run)
    try await registry.finish(run, status: status)

    let resumed = try await registry.resume(run.id)
    try await registry.recordPlan(original, in: resumed)
    let changed = [
        TaskPlanEntry(
            task: TaskID(rawValue: "core.build"),
            identity: ArtifactDigest(bytes: [UInt8](repeating: 2, count: 32)),
            isClean: false,
            explanation: "input identity changed",
            coordinates: nil)
    ]
    try await registry.recordPlan(changed, in: resumed)
    let incorrectlyClean = [
        TaskPlanEntry(
            task: TaskID(rawValue: "core.build"),
            identity: ArtifactDigest(bytes: [UInt8](repeating: 3, count: 32)),
            isClean: true,
            explanation: "fixture incorrectly claims reusable state",
            coordinates: nil)
    ]
    await #expect(throws: RunRegistryFailure.self) {
        try await registry.recordPlan(incorrectlyClean, in: resumed)
    }
}

@Test func runRegistryScrubsCredentialsFromDurableRecords() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-redaction-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = RunRegistry(root: FilePath(directory.path))
    let run = try await registry.begin(command: [
        "collider", "build", "--token", "command-secret",
        "https://example.invalid/archive?token=query-secret",
    ])
    let task = TaskID(rawValue: "fixture.redaction")
    try await registry.recordPlan(
        [
            TaskPlanEntry(
                task: task,
                identity: ArtifactDigest(bytes: [UInt8](repeating: 7, count: 32)),
                isClean: false,
                explanation: "credential redaction fixture",
                coordinates: nil)
        ],
        in: run)
    try await registry.record(
        .task(
            .failed(
                task: task,
                failure: ExecutionFailure(
                    reason: "Authorization: Bearer event-secret"))),
        in: run)
    try await registry.appendLog(
        Array("Cookie: session=log-secret\n".utf8),
        in: run)

    let manifest = try String(
        contentsOf: directory.appendingPathComponent(
            "runs/\(run.id.rawValue)/manifest.json"),
        encoding: .utf8)
    let events = try String(
        contentsOf: directory.appendingPathComponent(
            "runs/\(run.id.rawValue)/events.jsonl"),
        encoding: .utf8)
    let log = try String(
        contentsOf: directory.appendingPathComponent(
            "runs/\(run.id.rawValue)/run.log"),
        encoding: .utf8)
    let durableRecords = manifest + events + log
    for secret in [
        "command-secret", "query-secret", "event-secret", "log-secret",
    ] {
        #expect(!durableRecords.contains(secret))
    }
    #expect(durableRecords.contains("<redacted>"))
}

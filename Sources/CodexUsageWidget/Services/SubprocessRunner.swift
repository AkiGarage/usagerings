import Darwin
import Foundation
import os

/// Runs a subprocess with both pipes drained concurrently with the exit
/// wait, and a SIGTERM-then-SIGKILL timeout.
///
/// Drains start before `waitUntilExit` because a child that fills the pipe
/// buffer blocks on write and would never exit for us to wait on. The pid
/// cannot be reused during an escalation: the child is always our direct
/// child and stays unreaped until `waitUntilExit` returns, so the kernel
/// keeps it in the process table and the late SIGKILL can only reach it,
/// never an unrelated process.
struct SubprocessRunner: Sendable {
    let executableURL: URL
    var timeout: TimeInterval = 20
    var killGrace: TimeInterval = 2

    /// Drains block their thread until EOF and the timeout item must fire
    /// while a drain holds another thread, so the queue is concurrent.
    fileprivate static let queue = DispatchQueue(
        label: "local.codex.CodexUsageWidget.subprocess",
        attributes: .concurrent
    )

    func runSync(_ arguments: [String]) throws -> CodexUsageService.CommandResult {
        try perform(arguments, termination: TerminationState(killGrace: killGrace))
    }

    func run(_ arguments: [String]) async throws -> CodexUsageService.CommandResult {
        let termination = TerminationState(killGrace: killGrace)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Self.queue.async {
                    continuation.resume(with: Result {
                        try self.perform(arguments, termination: termination)
                    })
                }
            }
        } onCancel: {
            termination.escalate(markTimedOut: false)
        }
    }

    private func perform(
        _ arguments: [String],
        termination: TerminationState
    ) throws -> CodexUsageService.CommandResult {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw CodexUsageError.cliNotFound(executableURL.path)
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        termination.attach(process)
        do {
            try process.run()
        } catch {
            throw CodexUsageError.commandFailed(-1, "failed to launch")
        }

        let stdoutCell = OSAllocatedUnfairLock(initialState: Data())
        let stderrCell = OSAllocatedUnfairLock(initialState: Data())
        let drains = DispatchGroup()
        for (pipe, cell) in [(stdoutPipe, stdoutCell), (stderrPipe, stderrCell)] {
            drains.enter()
            Self.queue.async {
                cell.withLock { $0 = pipe.fileHandleForReading.readDataToEndOfFile() }
                drains.leave()
            }
        }

        let timeoutItem = DispatchWorkItem {
            termination.escalate(markTimedOut: true)
        }
        Self.queue.asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

        process.waitUntilExit()
        timeoutItem.cancel()
        drains.wait()

        return CodexUsageService.CommandResult(
            terminationStatus: process.terminationStatus,
            stdout: stdoutCell.withLock { $0 },
            stderr: stderrCell.withLock { $0 },
            timedOut: termination.timedOut
        )
    }
}

/// Escalation state shared between the timeout timer, the task-cancellation
/// handler, and the thread waiting on the child. The process reference is
/// written once, before the run goes concurrent; `escalated` and `timedOut`
/// are the only mutable fields.
private final class TerminationState: @unchecked Sendable {
    private struct State {
        var process: Process?
        var escalated = false
        var timedOut = false
    }

    private let killGrace: TimeInterval
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(killGrace: TimeInterval) {
        self.killGrace = killGrace
    }

    var timedOut: Bool {
        state.withLock { $0.timedOut }
    }

    func attach(_ process: Process) {
        state.withLock { $0.process = process }
    }

    /// First fire wins. The running check precedes the claim so a fire that
    /// lands before launch or after exit consumes nothing and leaves the
    /// timeout armed.
    func escalate(markTimedOut: Bool) {
        guard let process = state.withLock({ $0.process }), process.isRunning else { return }
        let first = state.withLock { current -> Bool in
            guard !current.escalated else { return false }
            current.escalated = true
            current.timedOut = current.timedOut || markTimedOut
            return true
        }
        guard first else { return }
        process.terminate()
        SubprocessRunner.queue.asyncAfter(deadline: .now() + killGrace) {
            guard process.isRunning else { return }
            kill(process.processIdentifier, SIGKILL)
        }
    }
}

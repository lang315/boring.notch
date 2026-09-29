//
//  CodeBurnRunner.swift
//  BoringNotchXPCHelper
//
//  Runs the user's `codeburn` CLI for the app's CodeBurn tab. The sandboxed app
//  cannot read ~/.claude and friends, so this unsandboxed helper spawns the CLI.
//  Foundation-only so scripts/codeburn-check.sh can compile it standalone.
//

import Foundation
import os

final class CodeBurnRunner: @unchecked Sendable {
    static let allowedPeriods: Set<String> = ["today", "week", "30days", "month"]
    static let maxOutputBytes = 5 * 1024 * 1024

    private static let log = os.Logger(subsystem: "theboringteam.boringnotch.BoringNotchXPCHelper", category: "CodeBurn")

    private let candidates: [URL]
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var isRunning = false

    init(candidates: [URL] = CodeBurnRunner.defaultCandidates(home: FileManager.default.homeDirectoryForCurrentUser),
         timeout: TimeInterval = 60) {
        self.candidates = candidates
        self.timeout = timeout
    }

    static func defaultCandidates(home: URL) -> [URL] {
        ["/opt/homebrew/bin/codeburn", "/usr/local/bin/codeburn"].map { URL(fileURLWithPath: $0) }
            + [".npm-global/bin", ".local/bin", ".volta/bin"].map {
                home.appendingPathComponent($0).appendingPathComponent("codeburn")
            }
    }

    /// Explicit allowlist: nothing else from the helper's environment reaches the CLI
    /// (drops NODE_OPTIONS, NODE_PATH, DYLD_* and friends). The node directory comes
    /// first so a `#!/usr/bin/env node` shebang can't pick up a planted `node`.
    static func childEnvironment(parent: [String: String], home: URL, candidates: [URL]) -> [String: String] {
        var env = ["HOME": home.path, "NODE_ENV": "production"]
        for key in ["USER", "TMPDIR", "LANG"] {
            env[key] = parent[key]
        }
        var path = ["/opt/homebrew/opt/node/bin"]
        for dir in candidates.map({ $0.deletingLastPathComponent().path }) + ["/usr/bin", "/bin"] where !path.contains(dir) {
            path.append(dir)
        }
        env["PATH"] = path.joined(separator: ":")
        return env
    }

    /// Replies exactly once: `(stdout, nil)` on success, otherwise `(nil, code)` with
    /// code in `not-installed | busy | timeout | failed`. Never blocks the caller, so
    /// other XPC messages on the same connection (brightness) are not held up.
    func run(period: String, reply: @escaping (Data?, String?) -> Void) {
        guard Self.allowedPeriods.contains(period) else { return reply(nil, "failed") }
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            return reply(nil, "not-installed")
        }
        guard claim() else { return reply(nil, "busy") }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = Self.childEnvironment(parent: ProcessInfo.processInfo.environment, home: home, candidates: candidates)
        let arguments = [binary.path, "status", "--format", "menubar-json", "--period", period, "--no-optimize"]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        guard let pid = Self.spawn(arguments: arguments, environment: environment,
                                   stdout: stdoutPipe.fileHandleForWriting.fileDescriptor,
                                   stderr: stderrPipe.fileHandleForWriting.fileDescriptor) else {
            release()
            return reply(nil, "failed")
        }
        // Keep only the read ends so EOF arrives once the child group is gone.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        let job = Job()
        let done = DispatchGroup()
        for (pipe, isStdout) in [(stdoutPipe, true), (stderrPipe, false)] {
            done.enter()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    done.leave()
                } else if !job.append(chunk, toStdout: isStdout) {
                    kill(-pid, SIGKILL)
                }
            }
        }
        done.enter()
        DispatchQueue.global().async {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            job.setStatus(status)
            done.leave()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            guard job.markTimedOut() else { return }
            kill(-pid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if !job.isFinished { kill(-pid, SIGKILL) }
            }
        }
        done.notify(queue: .global()) { [self] in
            // The pipes must outlive run(): dropping them closes the read ends and the
            // child dies of SIGPIPE on its first write.
            withExtendedLifetime((stdoutPipe, stderrPipe)) {}
            let result = job.finish()
            release()
            let exitedCleanly = result.status & 0x7f == 0 && (result.status >> 8) & 0xff == 0
            if result.timedOut {
                Self.log.error("codeburn timed out after \(self.timeout)s")
                reply(nil, "timeout")
            } else if result.overflowed {
                Self.log.error("codeburn stdout exceeded \(Self.maxOutputBytes) bytes")
                reply(nil, "failed")
            } else if exitedCleanly {
                reply(result.stdout, nil)
            } else {
                let stderr = String(decoding: result.stderr, as: UTF8.self)
                Self.log.error("codeburn failed (status \(result.status)): \(stderr, privacy: .public)")
                reply(nil, "failed")
            }
        }
    }

    private func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isRunning { return false }
        isRunning = true
        return true
    }

    private func release() {
        lock.lock()
        isRunning = false
        lock.unlock()
    }

    /// posix_spawn rather than Process: the child leads its own process group, so a
    /// timeout can kill node together with anything it started.
    private static func spawn(arguments: [String], environment: [String: String], stdout: Int32, stderr: Int32) -> pid_t? {
        var attr: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        posix_spawnattr_init(&attr)
        posix_spawn_file_actions_init(&actions)
        defer {
            posix_spawnattr_destroy(&attr)
            posix_spawn_file_actions_destroy(&actions)
        }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attr, 0)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)

        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var pid: pid_t = 0
        return posix_spawn(&pid, arguments[0], &actions, &attr, argv, envp) == 0 ? pid : nil
    }

    /// State shared by the pipe readers, the reaper and the timeout, behind one lock.
    private final class Job: @unchecked Sendable {
        private let lock = NSLock()
        private var stdout = Data()
        private var stderr = Data()
        private var status: Int32 = 0
        private var timedOut = false
        private var overflowed = false
        private var finished = false

        /// Returns false once stdout is over the cap.
        func append(_ chunk: Data, toStdout: Bool) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if overflowed { return false }
            if toStdout {
                stdout.append(chunk)
                overflowed = stdout.count > CodeBurnRunner.maxOutputBytes
            } else if stderr.count < 64 * 1024 {
                stderr.append(chunk)
            }
            return !overflowed
        }

        func setStatus(_ value: Int32) {
            lock.lock()
            status = value
            lock.unlock()
        }

        /// False when the run already finished, so a late timer does nothing.
        func markTimedOut() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if finished { return false }
            timedOut = true
            return true
        }

        var isFinished: Bool {
            lock.lock()
            defer { lock.unlock() }
            return finished
        }

        func finish() -> (stdout: Data, stderr: Data, status: Int32, timedOut: Bool, overflowed: Bool) {
            lock.lock()
            defer { lock.unlock() }
            finished = true
            return (stdout, stderr, status, timedOut, overflowed)
        }
    }
}

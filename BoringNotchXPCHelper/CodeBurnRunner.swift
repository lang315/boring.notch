//
//  CodeBurnRunner.swift
//  BoringNotchXPCHelper
//
//  Runs the user's `codeburn` CLI for the app's CodeBurn tab. The sandboxed app
//  cannot read ~/.claude and friends, so this unsandboxed helper spawns the CLI.
//  Foundation-only (Dispatch/Darwin come with it) so scripts/codeburn-check.sh can compile it standalone.
//

import Foundation
import os

final class CodeBurnRunner: @unchecked Sendable {
    static let allowedPeriods: Set<String> = ["today", "week", "30days", "month"]
    static let maxOutputBytes = 5 * 1024 * 1024

    private static let log = os.Logger(subsystem: "theboringteam.boringnotch.BoringNotchXPCHelper", category: "CodeBurn")

    private let candidates: [URL]?
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var isRunning = false

    /// `nil` candidates are rediscovered on every run, so a CLI installed later is found.
    init(candidates: [URL]? = nil, timeout: TimeInterval = 60) {
        self.candidates = candidates
        self.timeout = timeout
    }

    static func defaultCandidates(home: URL) -> [URL] {
        let fixed = fixedCandidateDirs(home: home).map { URL(fileURLWithPath: $0).appendingPathComponent("codeburn") }
        let direct = [".bun/bin/codeburn", "Library/pnpm/codeburn"].map { home.appendingPathComponent($0) }
        // Version managers keep one install per node version; list those that exist, newest first.
        let managers: [(root: String, suffix: String)] = [
            (".nvm/versions/node", "bin"), (".asdf/installs/nodejs", "bin"),
            (".local/share/mise/installs/node", "bin"), ("Library/Application Support/fnm/node-versions", "installation/bin"),
        ]
        var versioned: [URL] = []
        for manager in managers {
            let root = home.appendingPathComponent(manager.root)
            let versions = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
                .sorted { $0.localizedStandardCompare($1) == .orderedDescending }
            for version in versions {
                versioned.append(root.appendingPathComponent(version).appendingPathComponent(manager.suffix)
                    .appendingPathComponent("codeburn"))
            }
        }
        return fixed + direct + versioned
    }

    private static func fixedCandidateDirs(home: URL) -> [String] {
        ["/opt/homebrew/bin", "/usr/local/bin"] + [".npm-global/bin", ".local/bin", ".volta/bin"].map {
            home.appendingPathComponent($0).path
        }
    }

    /// Explicit allowlist: nothing from the helper's own environment (PATH included) reaches
    /// the CLI (drops NODE_OPTIONS, NODE_PATH, DYLD_* and friends). PATH leads with the
    /// chosen binary's directory, so a `#!/usr/bin/env node` shebang finds the node installed
    /// next to it; trusting that directory is the same trust as executing the binary.
    static func childEnvironment(parent: [String: String], home: URL, binary: URL) -> [String: String] {
        var env = ["HOME": home.path, "NODE_ENV": "production"]
        for key in ["USER", "TMPDIR", "LANG"] {
            env[key] = parent[key]
        }
        var path: [String] = []
        let dirs = [binary.deletingLastPathComponent().path, "/opt/homebrew/opt/node/bin"]
            + fixedCandidateDirs(home: home) + ["/usr/bin", "/bin"]
        for dir in dirs where !path.contains(dir) {
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
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = self.candidates ?? Self.defaultCandidates(home: home)
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            return reply(nil, "not-installed")
        }
        guard claim() else { return reply(nil, "busy") }

        let environment = Self.childEnvironment(parent: ProcessInfo.processInfo.environment, home: home, binary: binary)
        let arguments = [binary.path, "status", "--format", "menubar-json", "--period", period, "--no-optimize"]
        var outFds: [Int32] = [0, 0]
        var errFds: [Int32] = [0, 0]
        guard pipe(&outFds) == 0 else { release(); return reply(nil, "failed") }
        guard pipe(&errFds) == 0 else {
            close(outFds[0]); close(outFds[1])
            release()
            return reply(nil, "failed")
        }
        let pid = Self.spawn(arguments: arguments, environment: environment, stdout: outFds[1], stderr: errFds[1])
        // Keep only the read ends; the child holds the write ends.
        close(outFds[1])
        close(errFds[1])
        guard let pid else {
            close(outFds[0]); close(errFds[0])
            release()
            return reply(nil, "failed")
        }
        for fd in [outFds[0], errFds[0]] {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }

        // All job state lives on this queue, so handlers never race each other or a close.
        let queue = DispatchQueue(label: "codeburn.run")
        var stdout = Data()
        var stderr = Data()
        var timedOut = false
        var overflowed = false
        var finished = false
        var sources: [DispatchSourceRead] = []
        var timers: [DispatchWorkItem] = []

        func append(_ chunk: Data, toStdout: Bool) {
            if toStdout {
                if overflowed { return }
                stdout.append(chunk)
                if stdout.count > Self.maxOutputBytes {
                    overflowed = true
                    stdout = Data()
                    kill(-pid, SIGKILL)
                }
            } else if stderr.count < 64 * 1024 {
                stderr.append(chunk.prefix(64 * 1024 - stderr.count))
            }
        }
        var atEOF = [false, false] // [stdout, stderr]: the fd may be closed after EOF
        /// Reads until the fd is empty (EAGAIN) or at EOF; returns true at EOF.
        @discardableResult
        func drain(_ fd: Int32, toStdout: Bool) -> Bool {
            let index = toStdout ? 0 : 1
            if atEOF[index] { return true }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = read(fd, &buffer, buffer.count)
                if n > 0 {
                    append(Data(buffer[0..<n]), toStdout: toStdout)
                } else if n == 0 {
                    atEOF[index] = true
                    return true
                } else if errno == EINTR {
                    continue
                } else {
                    return false // EAGAIN/EWOULDBLOCK: nothing more buffered
                }
            }
        }
        func finish(status: Int32) {
            if finished { return }
            finished = true
            timers.forEach { $0.cancel() }
            sources.forEach { $0.cancel() } // cancel handlers close the fds
            // Break the timers -> block -> schedule -> timers cycle so the run's state is freed.
            timers.removeAll()
            sources.removeAll()
            release()
            let exitedCleanly = status & 0x7f == 0 && (status >> 8) & 0xff == 0
            if timedOut {
                Self.log.error("codeburn timed out after \(self.timeout)s")
                reply(nil, "timeout")
            } else if overflowed {
                Self.log.error("codeburn stdout exceeded \(Self.maxOutputBytes) bytes")
                reply(nil, "failed")
            } else if exitedCleanly {
                reply(stdout, nil)
            } else {
                Self.log.error("codeburn failed (status \(status)): \(String(decoding: stderr, as: UTF8.self))")
                reply(nil, "failed")
            }
        }

        for (fd, isStdout) in [(outFds[0], true), (errFds[0], false)] {
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [unowned source] in
                // EOF leaves the fd readable forever: stop watching it. The reaper decides completion.
                if drain(fd, toStdout: isStdout) { source.cancel() }
            }
            source.setCancelHandler { close(fd) }
            sources.append(source)
        }
        sources.forEach { $0.resume() }

        func schedule(after seconds: TimeInterval, _ body: @escaping () -> Void) {
            let item = DispatchWorkItem(block: body)
            timers.append(item)
            queue.asyncAfter(deadline: .now() + seconds, execute: item)
        }
        schedule(after: timeout) {
            if finished { return }
            timedOut = true
            kill(-pid, SIGTERM)
            schedule(after: 2) {
                if !finished { kill(-pid, SIGKILL) }
            }
        }

        DispatchQueue.global().async {
            // Wait without reaping: the zombie leader keeps its pgid from being reused, so the
            // group kill below cannot hit an unrelated process.
            var info = siginfo_t()
            while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1 && errno == EINTR {}
            queue.sync {
                // A clean exit leaves the group alone; a failed, timed-out or overflowed run
                // must not leave TERM-ignoring descendants behind.
                let cleanExit = info.si_code == CLD_EXITED && info.si_status == 0
                if timedOut || overflowed || !cleanExit { kill(-pid, SIGKILL) }
            }
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 {
                if errno == EINTR { continue }
                status = 1 << 8 // reaping failed: never report success
                break
            }
            queue.async {
                // The child is gone, so everything it wrote already sits in the pipe buffers.
                drain(outFds[0], toStdout: true)
                drain(errFds[0], toStdout: false)
                finish(status: status)
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
        // The caller's thread may have signals blocked or ignored; the child must start clean.
        var emptyMask = sigset_t()
        var allSignals = sigset_t()
        sigemptyset(&emptyMask)
        sigfillset(&allSignals)
        posix_spawnattr_setsigmask(&attr, &emptyMask)
        posix_spawnattr_setsigdefault(&attr, &allSignals)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
            | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
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
}

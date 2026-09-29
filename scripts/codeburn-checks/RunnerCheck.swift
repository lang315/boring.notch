import Foundation

@main
enum RunnerCheck {
    static func main() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeburn-runner-check-\(getpid())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func fake(_ name: String, _ body: String) throws -> URL {
            let url = dir.appendingPathComponent(name)
            try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }

        func call(_ runner: CodeBurnRunner, _ period: String, wait: TimeInterval = 10) -> (data: Data?, code: String?) {
            let done = DispatchSemaphore(value: 0)
            var result: (Data?, String?) = (nil, nil)
            runner.run(period: period) { data, code in
                result = (data, code)
                done.signal()
            }
            check(done.wait(timeout: .now() + wait) == .success, "no reply for \(period)")
            return result
        }

        // Pure environment allowlist.
        let home = URL(fileURLWithPath: "/Users/tester")
        let candidates = CodeBurnRunner.defaultCandidates(home: home)
        check(candidates.map(\.path) == [
            "/opt/homebrew/bin/codeburn", "/usr/local/bin/codeburn",
            "/Users/tester/.npm-global/bin/codeburn", "/Users/tester/.local/bin/codeburn",
            "/Users/tester/.volta/bin/codeburn",
        ], "default candidates: \(candidates.map(\.path))")
        let env = CodeBurnRunner.childEnvironment(
            parent: ["USER": "tester", "TMPDIR": "/tmp/x", "LANG": "en_US.UTF-8", "HOME": "/elsewhere",
                     "NODE_OPTIONS": "--inspect", "NODE_PATH": "/evil", "DYLD_INSERT_LIBRARIES": "/evil.dylib",
                     "PATH": "/evil/bin"],
            home: home, candidates: candidates)
        check(Set(env.keys) == ["HOME", "USER", "TMPDIR", "LANG", "PATH", "NODE_ENV"], "env keys: \(env.keys.sorted())")
        check(env["HOME"] == "/Users/tester", "HOME comes from the resolved home, not the parent")
        check(env["NODE_ENV"] == "production", "NODE_ENV")
        check(env["PATH"] == "/opt/homebrew/opt/node/bin:/opt/homebrew/bin:/usr/local/bin:/Users/tester/.npm-global/bin:/Users/tester/.local/bin:/Users/tester/.volta/bin:/usr/bin:/bin",
              "PATH: \(env["PATH"] ?? "nil")")

        // Allowlist and resolution.
        let missing = CodeBurnRunner(candidates: [dir.appendingPathComponent("missing")])
        check(call(missing, "all").code == "failed", "period outside allowlist is rejected")
        check(call(missing, "today").code == "not-installed", "no executable candidate")

        // Exact argv.
        let args = CodeBurnRunner(candidates: [try fake("args", "echo \"$@\"")])
        let argsResult = call(args, "week")
        check(argsResult.code == nil, "args run succeeded: \(argsResult.code ?? "")")
        check(argsResult.data.map { String(decoding: $0, as: UTF8.self) } == "status --format menubar-json --period week --no-optimize\n",
              "argv: \(argsResult.data.map { String(decoding: $0, as: UTF8.self) } ?? "nil")")

        // Environment reaching the child.
        setenv("NODE_OPTIONS", "--inspect", 1)
        // Not named "env": candidate dirs precede /usr/bin on PATH, so the fake would call itself.
        let envRunner = CodeBurnRunner(candidates: [try fake("print-env", "/usr/bin/env")])
        let childEnv = call(envRunner, "today").data.map { String(decoding: $0, as: UTF8.self) } ?? ""
        check(childEnv.contains("NODE_ENV=production"), "child sees NODE_ENV")
        check(!childEnv.contains("NODE_OPTIONS="), "child does not see NODE_OPTIONS")

        // Non-zero exit.
        let failing = CodeBurnRunner(candidates: [try fake("fail", "echo boom >&2\nexit 3")])
        let failResult = call(failing, "today")
        check(failResult.data == nil && failResult.code == "failed", "non-zero exit maps to failed")

        // Output cap.
        let big = CodeBurnRunner(candidates: [try fake("big", "head -c 6000000 /dev/zero")])
        check(call(big, "today").code == "failed", "stdout over 5 MB maps to failed")

        // Timeout, busy, process group kill, exactly one reply.
        let pidFile = dir.appendingPathComponent("grandchild.pid")
        let slow = CodeBurnRunner(candidates: [try fake("slow", "sleep 30 &\necho $! > '\(pidFile.path)'\nwait")], timeout: 1)
        let first = DispatchSemaphore(value: 0)
        var replies = 0
        var firstCode: String?
        slow.run(period: "today") { _, code in
            replies += 1
            firstCode = code
            first.signal()
        }
        check(call(slow, "today").code == "busy", "second call while running is busy")
        check(first.wait(timeout: .now() + 8) == .success, "timed-out run replied")
        check(firstCode == "timeout", "timeout code: \(firstCode ?? "nil")")
        Thread.sleep(forTimeInterval: 3)
        check(replies == 1, "exactly one reply, got \(replies)")
        let grandchild = pid_t(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        check(grandchild > 0 && kill(grandchild, 0) != 0, "grandchild \(grandchild) was killed with the process group")
        check(call(slow, "today").code == "timeout", "runner is free again after a timeout")

        print("RunnerCheck OK")
    }
}

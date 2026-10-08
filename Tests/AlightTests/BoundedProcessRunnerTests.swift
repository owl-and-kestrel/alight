import Foundation
import Darwin
import Testing
@testable import Alight

@Suite("Bounded process runner", .serialized)
struct BoundedProcessRunnerTests {
  private func fixture(_ script: String) throws -> (directory: URL, executable: URL, pids: URL) {
    let directory = FileManager.default.temporaryDirectory.appending(path: "alight-runner-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let executable = directory.appending(path: "fake-tool")
    try Data(("#!/bin/sh\n" + script).utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return (directory, executable, directory.appending(path: "pids"))
  }

  private func recordedPIDs(_ file: URL) throws -> [pid_t] {
    try String(contentsOf: file, encoding: .utf8).split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
  }

  private func run(_ executable: URL, environment: [String: String] = [:], timeout: TimeInterval = 2,
    outputLimit: Int = 4096, grace: TimeInterval = 0.1) async -> BoundedProcessRunner.Result {
    await BoundedProcessRunner().run(
      executable: executable.path,
      arguments: ["--flag", "two words"],
      environment: environment,
      directory: executable.deletingLastPathComponent().path,
      timeout: timeout,
      outputLimit: outputLimit,
      terminationGrace: grace
    )
  }

  @Test("captures stdout, stderr, arguments, and exit status without a shell")
  func capturesOutput() async throws {
    let (directory, executable, _) = try fixture("""
      printf '%s|' "$@"
      printf 'warning on stderr\\n' >&2
      exit 3
      """)
    defer { try? FileManager.default.removeItem(at: directory) }
    let result = await run(executable)
    #expect(result.failure == nil)
    #expect(result.status == 3)
    #expect(String(decoding: result.stdout, as: UTF8.self) == "--flag|two words|")
    #expect(String(decoding: result.stderr, as: UTF8.self) == "warning on stderr\n")
  }

  @Test("stdin is /dev/null and only the given environment is passed")
  func isolatedInputAndEnvironment() async throws {
    let (directory, executable, _) = try fixture("""
      read line && echo "stdin:$line" || echo "stdin:eof"
      echo "only:${ALIGHT_ONLY_VAR:-missing}"
      echo "home:${HOME:-missing}"
      """)
    defer { try? FileManager.default.removeItem(at: directory) }
    let result = await run(executable, environment: ["ALIGHT_ONLY_VAR": "present"])
    let output = String(decoding: result.stdout, as: UTF8.self)
    #expect(output.contains("stdin:eof"))
    #expect(output.contains("only:present"))
    #expect(output.contains("home:missing"))
  }

  @Test("a missing executable is a launch failure")
  func launchFailure() async {
    let result = await BoundedProcessRunner().run(
      executable: "/nonexistent/alight-test-tool", arguments: [], environment: [:],
      directory: "/", timeout: 1, outputLimit: 1024)
    #expect(result.failure == .launchFailed)
    #expect(result.status == nil)
  }

  @Test("timeout kills and reaps a TERM-resistant child before returning")
  func resistantChildTimeout() async throws {
    let (directory, executable, pids) = try fixture("trap '' TERM\necho $$ > \"$ALIGHT_TEST_PID_FILE\"\nexec /bin/sleep 30\n")
    defer { try? FileManager.default.removeItem(at: directory) }
    let start = ProcessInfo.processInfo.systemUptime
    let result = await run(executable, environment: ["ALIGHT_TEST_PID_FILE": pids.path], timeout: 0.5)
    #expect(result.failure == .timedOut)
    #expect(result.status == nil)
    #expect(ProcessInfo.processInfo.systemUptime - start < 2)
    let pid = try #require(recordedPIDs(pids).first)
    #expect(kill(pid, 0) == -1 && errno == ESRCH)
  }

  @Test("an exited child's stdout-holding descendant is cleaned up before completion")
  func descendantCleanup() async throws {
    let (directory, executable, pids) = try fixture("trap '' TERM\n/bin/sleep 30 &\necho $$ $! > \"$ALIGHT_TEST_PID_FILE\"\nprintf 'done\\n'\nexit 0\n")
    defer { try? FileManager.default.removeItem(at: directory) }
    let start = ProcessInfo.processInfo.systemUptime
    let result = await run(executable, environment: ["ALIGHT_TEST_PID_FILE": pids.path], timeout: 1)
    #expect(result.failure == nil)
    #expect(String(decoding: result.stdout, as: UTF8.self) == "done\n")
    #expect(ProcessInfo.processInfo.systemUptime - start < 1)
    let processes = try recordedPIDs(pids)
    #expect(processes.count == 2)
    for pid in processes { #expect(kill(pid, 0) == -1 && errno == ESRCH) }
  }

  @Test("oversized stdout is capped and its writer is reaped without waiting for the deadline")
  func oversizedStdout() async throws {
    let (directory, executable, pids) = try fixture("trap '' TERM\necho $$ > \"$ALIGHT_TEST_PID_FILE\"\nexec /usr/bin/yes x\n")
    defer { try? FileManager.default.removeItem(at: directory) }
    let start = ProcessInfo.processInfo.systemUptime
    let result = await run(executable, environment: ["ALIGHT_TEST_PID_FILE": pids.path], timeout: 5)
    #expect(result.failure == .outputLimitExceeded)
    #expect(result.stdout.count <= 4096)
    #expect(ProcessInfo.processInfo.systemUptime - start < 1)
    let pid = try #require(recordedPIDs(pids).first)
    #expect(kill(pid, 0) == -1 && errno == ESRCH)
    // Output goes through bounded pipes; nothing is written to disk.
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == ["fake-tool", "pids"])
  }

  @Test("oversized stderr is capped too")
  func oversizedStderr() async throws {
    let (directory, executable, _) = try fixture("exec /usr/bin/yes x >&2\n")
    defer { try? FileManager.default.removeItem(at: directory) }
    let start = ProcessInfo.processInfo.systemUptime
    let result = await run(executable, timeout: 5)
    #expect(result.failure == .outputLimitExceeded)
    #expect(result.stderr.count <= 4096)
    #expect(ProcessInfo.processInfo.systemUptime - start < 1)
  }

  @Test("an escaped stdout holder cannot block completion; fixture cleans its own session")
  func escapedStdoutHolder() async throws {
    let script = """
      /usr/bin/python3 -c 'import os,time; os.setsid(); open(os.environ["ALIGHT_TEST_ESCAPE_FILE"],"w").write(str(os.getpid())); time.sleep(30)' &
      echo $$ $! > "$ALIGHT_TEST_PID_FILE"
      while [ ! -s "$ALIGHT_TEST_ESCAPE_FILE" ]; do /bin/sleep 0.01; done
      printf 'partial\\n'
      exit 0
      """
    let (directory, executable, pids) = try fixture(script)
    let escapedFile = directory.appending(path: "escaped-pid")
    var needsCleanup = true
    // Only this fixture's recorded child is signaled. The product never
    // inventories or kills a process outside its invocation's owned group.
    defer {
      if needsCleanup, let processes = try? recordedPIDs(pids), processes.count == 2 { _ = kill(processes[1], SIGKILL) }
      try? FileManager.default.removeItem(at: directory)
    }
    let start = ProcessInfo.processInfo.systemUptime
    let result = await run(executable, environment: ["ALIGHT_TEST_PID_FILE": pids.path,
      "ALIGHT_TEST_ESCAPE_FILE": escapedFile.path, "PATH": "/usr/bin:/bin"], timeout: 2)
    #expect(result.failure == .outputIncomplete) // Incomplete output never counts as success.
    #expect(result.status == nil)
    #expect(ProcessInfo.processInfo.systemUptime - start < 2)
    let processes = try recordedPIDs(pids)
    #expect(processes.count == 2)
    let escaped = try #require(recordedPIDs(escapedFile).first)
    #expect(escaped == processes[1])
    #expect(kill(processes[0], 0) == -1 && errno == ESRCH)
    #expect(kill(escaped, 0) == 0) // It did escape the runner-owned process group.
    #expect(kill(escaped, SIGKILL) == 0)
    let cleanupDeadline = ProcessInfo.processInfo.systemUptime + 1
    while kill(escaped, 0) == 0 && ProcessInfo.processInfo.systemUptime < cleanupDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    let cleaned = kill(escaped, 0) == -1 && errno == ESRCH
    #expect(cleaned)
    needsCleanup = !cleaned
  }
}

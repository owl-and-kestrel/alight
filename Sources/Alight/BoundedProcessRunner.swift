import Foundation
import Darwin

/// Runs one executable directly — never through a shell — and owns everything
/// it starts until the run is over.
///
/// - The child gets its own process group, stdin on `/dev/null`, an explicit
///   environment and working directory, and no inherited descriptors
///   (`POSIX_SPAWN_CLOEXEC_DEFAULT`).
/// - stdout and stderr are bounded pipes. A child that writes more than
///   `outputLimit` bytes to either stream is stopped instead of buffered.
/// - A deadline or an overflow sends SIGTERM to the group, then SIGKILL after
///   `terminationGrace`. When the direct child exits, the rest of its group is
///   killed too, so helpers it started cannot outlive the run.
/// - The direct child is reaped before the call returns, and runs on one
///   runner are serialized on a private queue: at most one child at a time.
///
/// `Foundation.Process` cannot start a child in a new process group, which is
/// why this uses `posix_spawn`.
final class BoundedProcessRunner: @unchecked Sendable {
  static let shared = BoundedProcessRunner()

  private let queue = DispatchQueue(label: "com.owlandkestrel.alight.bounded-process")

  enum Failure: String, Equatable, Sendable {
    case launchFailed
    case timedOut
    case outputLimitExceeded
    /// The child exited, but something outside its process group still held
    /// an output pipe open, so the captured output may be incomplete.
    case outputIncomplete
    case signaled
  }

  struct Result: Sendable {
    /// Exit status of a child that exited by itself. Nil whenever `failure`
    /// is set.
    let status: Int32?
    let stdout: Data
    let stderr: Data
    let failure: Failure?

    static func failed(_ failure: Failure) -> Result {
      Result(status: nil, stdout: Data(), stderr: Data(), failure: failure)
    }
  }

  func run(
    executable: String,
    arguments: [String],
    environment: [String: String],
    directory: String,
    timeout: TimeInterval,
    outputLimit: Int,
    terminationGrace: TimeInterval = 1
  ) async -> Result {
    await withCheckedContinuation { continuation in
      queue.async {
        continuation.resume(returning: Self.runSync(
          executable: executable,
          arguments: arguments,
          environment: environment,
          directory: directory,
          timeout: timeout,
          outputLimit: outputLimit,
          terminationGrace: terminationGrace
        ))
      }
    }
  }

  private static func runSync(
    executable: String,
    arguments: [String],
    environment: [String: String],
    directory: String,
    timeout: TimeInterval,
    outputLimit: Int,
    terminationGrace: TimeInterval
  ) -> Result {
    guard timeout.isFinite, timeout > 0, outputLimit > 0,
      terminationGrace.isFinite, terminationGrace >= 0 else {
      return .failed(.launchFailed)
    }
    let null = open("/dev/null", O_RDWR | O_CLOEXEC)
    guard null >= 0 else { return .failed(.launchFailed) }
    defer { close(null) }

    // [stdout, stderr] pipes as [read, write] descriptor pairs.
    var pipes: [[Int32]] = [[-1, -1], [-1, -1]]
    defer {
      for descriptor in pipes.joined() where descriptor >= 0 { close(descriptor) }
    }
    for index in pipes.indices {
      var descriptors: [Int32] = [-1, -1]
      guard pipe(&descriptors) == 0 else { return .failed(.launchFailed) }
      pipes[index] = descriptors
      guard fcntl(descriptors[0], F_SETFL, O_NONBLOCK) == 0 else { return .failed(.launchFailed) }
      _ = fcntl(descriptors[0], F_SETFD, FD_CLOEXEC)
      _ = fcntl(descriptors[1], F_SETFD, FD_CLOEXEC)
    }

    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else { return .failed(.launchFailed) }
    defer { posix_spawn_file_actions_destroy(&actions) }
    guard posix_spawnattr_init(&attributes) == 0 else { return .failed(.launchFailed) }
    defer { posix_spawnattr_destroy(&attributes) }
    guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
      posix_spawnattr_setpgroup(&attributes, 0) == 0,
      posix_spawn_file_actions_adddup2(&actions, null, STDIN_FILENO) == 0,
      posix_spawn_file_actions_adddup2(&actions, pipes[0][1], STDOUT_FILENO) == 0,
      posix_spawn_file_actions_adddup2(&actions, pipes[1][1], STDERR_FILENO) == 0,
      posix_spawn_file_actions_addchdir_np(&actions, directory) == 0 else {
      return .failed(.launchFailed)
    }
    let argv = ([executable] + arguments).map { strdup($0) } + [nil]
    let envp = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
    var pid: pid_t = 0
    let spawned = argv.withUnsafeBufferPointer { argv in
      envp.withUnsafeBufferPointer { envp in
        posix_spawn(&pid, executable, &actions, &attributes, argv.baseAddress!, envp.baseAddress!)
      }
    }
    guard spawned == 0 else { return .failed(.launchFailed) }
    // Only the child may hold the write ends, so EOF means it (and anything it
    // handed the descriptors to) is done writing.
    for index in pipes.indices {
      close(pipes[index][1])
      pipes[index][1] = -1
    }

    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    var failure: Failure?
    var stoppingAt: TimeInterval?
    var killed = false
    var exitedAt: TimeInterval?
    var outputs = [Data(), Data()]
    var closed = [false, false]
    var buffer = [UInt8](repeating: 0, count: 8192)

    func stop(_ reason: Failure, at now: TimeInterval) {
      guard stoppingAt == nil else { return }
      failure = reason
      stoppingAt = now
      _ = kill(-pid, SIGTERM)
    }

    while true {
      let now = ProcessInfo.processInfo.systemUptime
      for index in pipes.indices where !closed[index] {
        // One bounded read per stream per turn: an over-producing child is
        // stopped rather than drained forever, and the kernel pipe stays the
        // only buffer it can fill.
        let wanted = stoppingAt == nil
          ? min(buffer.count, outputLimit - outputs[index].count + 1)
          : buffer.count
        let count = read(pipes[index][0], &buffer, wanted)
        if count > 0 {
          if stoppingAt == nil {
            if outputs[index].count + count > outputLimit {
              stop(.outputLimitExceeded, at: now)
            } else {
              outputs[index].append(contentsOf: buffer.prefix(count))
            }
          }
        } else if count == 0 {
          closed[index] = true
        } else if errno != EAGAIN && errno != EINTR {
          closed[index] = true
          stop(.outputIncomplete, at: now)
        }
      }
      if stoppingAt == nil && now >= deadline { stop(.timedOut, at: now) }
      if let stoppingAt, !killed, now - stoppingAt >= terminationGrace {
        _ = kill(-pid, SIGKILL)
        killed = true
      }

      // WNOWAIT keeps the child PID reserved until its group has been
      // signaled, so a recycled process-group id can never be hit.
      var info = siginfo_t()
      if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 && info.si_pid == pid {
        _ = kill(-pid, SIGKILL) // Clean up any helpers left in the group.
        if exitedAt == nil { exitedAt = now }
        if closed.contains(false) {
          // Give owned writers a short drain after cleanup. A descendant that
          // left the group (new session) may still hold a pipe; close it and
          // fail rather than wait or signal a process Alight does not own.
          if now - exitedAt! < 0.1 {
            usleep(5_000)
            continue
          }
          if stoppingAt == nil { failure = .outputIncomplete; stoppingAt = now }
          for index in pipes.indices where !closed[index] {
            close(pipes[index][0])
            pipes[index][0] = -1
            closed[index] = true
          }
        }
        var status: Int32 = 0
        var reaped: pid_t
        repeat { reaped = waitpid(pid, &status, 0) } while reaped < 0 && errno == EINTR
        guard reaped == pid else { return .failed(failure ?? .launchFailed) }
        let signal = status & 0x7f
        if failure == nil && signal != 0 { failure = .signaled }
        return Result(
          status: failure == nil ? (status >> 8) & 0xff : nil,
          stdout: outputs[0],
          stderr: outputs[1],
          failure: failure
        )
      }
      usleep(5_000)
    }
  }
}

import Foundation
import Darwin

// Read from a signal handler: plain globals, filled once at launch and never changed afterwards.
private var relaunchArguments: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
private var relaunchEnvironment: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
private var launchedAt: time_t = 0

private func startReplacement() {
    guard let relaunchArguments else { return }
    var child: pid_t = 0
    posix_spawn(&child, "/bin/sh", nil, nil, relaunchArguments, relaunchEnvironment)
}
private func handleCrash(_ signalNumber: Int32) {
    // Restore the default action first so the system still records the crash, then start a fresh copy.
    signal(signalNumber, SIG_DFL)
    if time(nil) - launchedAt > Resilience.settleSeconds { startReplacement() }
    raise(signalNumber)
}

/// Keeps the notch usable when something goes badly wrong: after a crash, or when the interface has not
/// answered for several seconds, a fresh copy of the app takes over with the panel closed.
enum Resilience {
    /// A failure this soon after launch is not retried: restarting would only loop.
    static let settleSeconds = 20
    private static let lock = NSLock()
    private static var awaitingAnswer = false
    private static var missed = 0
    private static var watchdog: DispatchSourceTimer?

    static func install() {
        let path = Bundle.main.bundlePath
        guard path.hasSuffix(".app"), relaunchArguments == nil else { return }
        launchedAt = time(nil)
        let values = ["/bin/sh", "-c", "sleep 1.5; exec /usr/bin/open -n \"$0\" --args --relaunched", path]
        let pointer = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: values.count + 1)
        for (index, value) in values.enumerated() { pointer[index] = strdup(value) }
        pointer[values.count] = nil
        relaunchArguments = pointer
        let variables = ProcessInfo.processInfo.environment.map { $0.key + "=" + $0.value }
        let environment = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: variables.count + 1)
        for (index, value) in variables.enumerated() { environment[index] = strdup(value) }
        environment[variables.count] = nil
        relaunchEnvironment = environment
        for number in [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE] { signal(number, handleCrash) }

        // The main thread is asked for a sign of life every second. Counting unanswered requests, rather than
        // elapsed time, keeps sleep and a throttled timer from looking like a hang.
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "fr.notcher.watchdog", qos: .utility))
        timer.schedule(deadline: .now() + 5, repeating: 1, leeway: .milliseconds(200))
        timer.setEventHandler {
            lock.lock()
            if awaitingAnswer { missed += 1 } else {
                missed = 0; awaitingAnswer = true
                DispatchQueue.main.async { lock.lock(); awaitingAnswer = false; lock.unlock() }
            }
            let frozen = missed >= 10
            if frozen { missed = 0 }
            lock.unlock()
            guard frozen, time(nil) - launchedAt > settleSeconds else { return }
            startReplacement()
            _exit(75)
        }
        timer.resume()
        watchdog = timer
    }
}

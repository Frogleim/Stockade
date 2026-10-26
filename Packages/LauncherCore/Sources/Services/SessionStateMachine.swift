import Foundation

public enum SessionEvent: Sendable, Equatable {
    case launchRequested
    /// The steam.exe invocation we started has exited. It may have handed off to a running Steam.
    case steamRequestExited(ProcessExit)
    case snapshot(PrefixSnapshot)
    /// No game process was observed within the observation window.
    case observationWindowElapsed
    case launchFailed(String)
}

/// Pure transition rules, kept separate from timers and processes so they are easy to test.
/// The guiding rule: never claim the game is running unless a game process was observed.
public enum SessionStateMachine {
    public static func apply(_ event: SessionEvent, to session: inout LaunchSession, now: Date = Date()) {
        switch event {
        case .launchRequested:
            session.phase = .launchRequested
            session.failureReason = nil

        case .launchFailed(let reason):
            session.phase = .failed
            session.failureReason = reason
            session.endedAt = now

        case .steamRequestExited(let exit):
            session.steamRequestExitStatus = exit.status
            // A non-zero exit before anything was observed is a real failure.
            // A clean exit usually means Steam received the request; keep waiting.
            if !exit.succeeded, session.phase == .launchRequested {
                session.phase = .failed
                session.failureReason = "Steam exited with status \(exit.status) before the game was observed."
                session.endedAt = now
            }

        case .snapshot(let snapshot):
            switch session.phase {
            case .launchRequested, .starting, .statusUnknown:
                if !snapshot.gameProcesses.isEmpty {
                    session.phase = .runningObserved
                    session.observedGameProcesses = snapshot.gameProcesses.map(\.identity)
                } else if !snapshot.steamProcesses.isEmpty, session.phase == .launchRequested {
                    session.phase = .starting
                } else if snapshot.prefixProcesses.isEmpty, session.steamRequestExitStatus != nil {
                    // Steam took the request and everything in the prefix has since exited.
                    session.phase = .failed
                    session.failureReason = "Nothing is running in the prefix any more: the game did not stay open. See Diagnostics for the logs."
                    session.endedAt = now
                }
            case .runningObserved:
                if snapshot.gameProcesses.isEmpty {
                    session.phase = .exited
                    session.endedAt = now
                } else {
                    let known = Set(session.observedGameProcesses)
                    session.observedGameProcesses += snapshot.gameProcesses.map(\.identity).filter { !known.contains($0) }
                }
            default:
                break
            }

        case .observationWindowElapsed:
            if session.phase == .launchRequested || session.phase == .starting {
                session.phase = .statusUnknown
            }
        }
    }

    public static func isTerminal(_ phase: SessionPhase) -> Bool {
        phase == .exited || phase == .failed
    }
}

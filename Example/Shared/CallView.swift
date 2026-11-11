import ConduitCallEngine
import SwiftUI

struct CallView: View {
    let engine: CallEngine

    var body: some View {
        VStack(spacing: 24) {
            Text(ExampleAgent.target.displayName)
                .font(.title)
            Text(statusText)
                .font(.headline)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                Button("Call") {
                    Task { await engine.placeCall(ExampleAgent.target) }
                }
                .disabled(isCallInProgress)

                Button(engine.isMuted ? "Unmute" : "Mute") {
                    Task { await engine.setMuted(!engine.isMuted) }
                }
                .disabled(!isCallInProgress)

                Button("End", role: .destructive) {
                    Task { await engine.endCall() }
                }
                .disabled(!isCallInProgress)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var isCallInProgress: Bool {
        engine.state.isActive && !engine.state.isTerminal
    }

    private var statusText: String {
        switch engine.state {
        case .idle: "Ready"
        case .incomingRinging: "Ringing"
        case .dialing: "Dialing"
        case .connecting: "Connecting"
        case .connected(let since): "Connected since \(since.formatted(date: .omitted, time: .standard))"
        case .reconnecting(let attempt): "Reconnecting (attempt \(attempt))"
        case .ended(let outcome): "Ended: \(String(describing: outcome))"
        case .failed(let reason): "Failed: \(String(describing: reason))"
        }
    }
}

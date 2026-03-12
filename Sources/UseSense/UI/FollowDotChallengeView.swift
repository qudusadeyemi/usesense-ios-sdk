#if canImport(SwiftUI)
import SwiftUI

struct FollowDotChallengeView: View {
    let challenge: FollowDotChallenge
    let onComplete: () -> Void
    let onStepReached: (Int) -> Void
    var onProgress: ((Double) -> Void)?

    @State private var currentWaypointIndex = 0
    @State private var dotPosition: CGPoint = .zero
    @State private var timer: Timer?
    @State private var isActive = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Spec: 24pt red dot with shadow, 300ms spring animation
                Circle()
                    .fill(Color.UseSense.challengeDot)
                    .frame(width: 24, height: 24)
                    .shadow(color: Color.black.opacity(0.3), radius: 4, y: 2)
                    .position(dotPosition)
                    .animation(.easeInOut(duration: 0.3), value: dotPosition)

                // Instruction text at bottom (above chrome area)
                VStack {
                    Spacer()

                    Text("Follow the dot")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.bottom, 80)
                }
            }
            .onAppear {
                guard !challenge.waypoints.isEmpty else {
                    onComplete()
                    return
                }
                let first = challenge.waypoints[0]
                dotPosition = CGPoint(
                    x: CGFloat(first.x) * geometry.size.width,
                    y: CGFloat(first.y) * geometry.size.height
                )
                startChallenge(in: geometry.size)
            }
            .onDisappear { stopChallenge() }
        }
    }

    private var currentStepDuration: Double {
        guard currentWaypointIndex < challenge.waypoints.count else { return 0.5 }
        return Double(challenge.waypoints[currentWaypointIndex].durationMs) / 1000.0
    }

    private func startChallenge(in size: CGSize) {
        guard !isActive else { return }
        isActive = true
        moveToNextWaypoint(in: size)
    }

    private func moveToNextWaypoint(in size: CGSize) {
        guard currentWaypointIndex < challenge.waypoints.count else {
            onComplete()
            return
        }

        let waypoint = challenge.waypoints[currentWaypointIndex]
        let target = CGPoint(
            x: CGFloat(waypoint.x) * size.width,
            y: CGFloat(waypoint.y) * size.height
        )

        dotPosition = target
        onStepReached(waypoint.index)
        let total = Double(challenge.waypoints.count)
        onProgress?(Double(currentWaypointIndex + 1) / total)

        let delay = Double(waypoint.durationMs) / 1000.0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            currentWaypointIndex += 1
            moveToNextWaypoint(in: size)
        }
    }

    private func stopChallenge() {
        isActive = false
        timer?.invalidate()
        timer = nil
    }
}
#endif

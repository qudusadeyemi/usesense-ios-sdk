#if canImport(SwiftUI)
import SwiftUI

struct FollowDotChallengeView: View {
    let waypoints: [Waypoint]
    let dotSizePx: Int
    @Binding var currentWaypointIndex: Int
    @State private var dotPosition: CGPoint = .zero

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Dot
                Circle()
                    .fill(UseSenseTheme.Colors.indigo500)
                    .frame(width: CGFloat(dotSizePx + 4), height: CGFloat(dotSizePx + 4))
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    .shadow(color: UseSenseTheme.Colors.indigo500.opacity(0.5), radius: 6, x: 0, y: 0)
                    .position(dotPosition)
                    .animation(.easeInOut(duration: 0.4), value: dotPosition)

                // Step indicator
                VStack {
                    Spacer()
                    Text("Step \(currentWaypointIndex + 1) of \(waypoints.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(UseSenseTheme.Colors.indigo600.opacity(0.85))
                        )
                        .padding(.bottom, 16)
                }
            }
            .onChange(of: currentWaypointIndex) { newIndex in
                updateDotPosition(index: newIndex, in: geo.size)
            }
            .onAppear {
                updateDotPosition(index: currentWaypointIndex, in: geo.size)
            }
        }
    }

    private func updateDotPosition(index: Int, in size: CGSize) {
        guard index < waypoints.count else { return }
        let wp = waypoints[index]
        dotPosition = CGPoint(x: wp.x * size.width, y: wp.y * size.height)
    }
}
#endif

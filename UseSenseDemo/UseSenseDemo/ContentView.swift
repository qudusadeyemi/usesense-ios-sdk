import SwiftUI

struct ContentView: View {
    @State private var selectedMode: DemoMode = .mock
    @State private var showConfig = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "faceid")
                        .font(.system(size: 48))
                        .foregroundColor(.blue)

                    Text("UseSense Demo")
                        .font(.system(size: 28, weight: .bold))

                    Text("Human Presence Verification SDK")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                .padding(.top, 40)

                Spacer()

                // Mode picker
                Picker("Mode", selection: $selectedMode) {
                    Text("Mock").tag(DemoMode.mock)
                    Text("Live").tag(DemoMode.live)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 24)

                // Action buttons
                VStack(spacing: 12) {
                    NavigationLink {
                        EnrollmentView(mode: selectedMode)
                    } label: {
                        Label("Enrollment", systemImage: "person.badge.plus")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }

                    NavigationLink {
                        AuthenticationView(mode: selectedMode)
                    } label: {
                        Label("Authentication", systemImage: "person.badge.shield.checkmark")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                }
                .padding(.horizontal, 24)

                Spacer()

                // Config button
                Button(action: { showConfig = true }) {
                    Label("Configuration", systemImage: "gear")
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                }
                .padding(.bottom, 20)
            }
            .sheet(isPresented: $showConfig) {
                ConfigView()
            }
        }
    }
}

enum DemoMode {
    case mock
    case live
}

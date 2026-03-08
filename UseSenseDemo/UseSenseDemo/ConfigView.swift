import SwiftUI

struct ConfigView: View {
    @AppStorage("apiKey") private var apiKey = ""
    @AppStorage("environment") private var environment = "sandbox"

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("API Configuration") {
                    SecureField("API Key", text: $apiKey)
                        .autocapitalization(.none)
                }

                Section("Environment") {
                    Picker("Environment", selection: $environment) {
                        Text("Sandbox").tag("sandbox")
                        Text("Production").tag("production")
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Button("Reset to Defaults") {
                        apiKey = ""
                        environment = "sandbox"
                    }
                    .foregroundColor(.red)
                }
            }
            .navigationTitle("Configuration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

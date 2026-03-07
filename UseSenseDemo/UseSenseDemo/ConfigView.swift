import SwiftUI

struct ConfigView: View {
    @AppStorage("apiBaseUrl") private var apiBaseUrl = "https://api.usesense.ai/functions/v1/make-server-fc4cf30d"
    @AppStorage("apiKey") private var apiKey = ""
    @AppStorage("gatewayKey") private var gatewayKey = ""
    @AppStorage("environment") private var environment = "sandbox"

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("API Configuration") {
                    TextField("API Base URL", text: $apiBaseUrl)
                        .textContentType(.URL)
                        .autocapitalization(.none)

                    SecureField("API Key", text: $apiKey)
                        .autocapitalization(.none)

                    SecureField("Gateway Key (optional)", text: $gatewayKey)
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
                        apiBaseUrl = "https://api.usesense.ai/functions/v1/make-server-fc4cf30d"
                        apiKey = ""
                        gatewayKey = ""
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

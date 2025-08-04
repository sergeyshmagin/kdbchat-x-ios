// Тестовый код для проверки VoIP push локально
// Добавьте в DeveloperOptionsScreen для быстрого тестирования

import SwiftUI

struct VoIPTestView: View {
    @State private var testResult = ""
    @State private var isLoading = false
    
    var body: some View {
        VStack(spacing: 20) {
            Text("VoIP Push Diagnostics")
                .font(.title2)
                .bold()
            
            Button {
                Task {
                    await runVoIPTest()
                }
            } label: {
                if isLoading {
                    ProgressView()
                } else {
                    Text("🧪 Test VoIP Push")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isLoading)
            
            ScrollView {
                Text(testResult)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)
        }
        .padding()
    }
    
    private func runVoIPTest() async {
        isLoading = true
        testResult = "🔄 Running VoIP diagnostics...\n\n"
        
        // Test 1: Check VoIP token
        let notificationManager = ServiceLocator.shared.notificationManager
        let hasToken = notificationManager.hasVoIPToken()
        testResult += "1️⃣ VoIP Token: \(hasToken ? "✅ Available" : "❌ Not found")\n"
        
        // Test 2: Get diagnostics
        let diagnostics = notificationManager.getVoIPPusherDiagnostics()
        testResult += "\n2️⃣ VoIP Pusher Status:\n"
        testResult += "   • Has Token: \(diagnostics.hasToken ? "✅" : "❌")\n"
        testResult += "   • Token Prefix: \(diagnostics.tokenPrefix ?? "N/A")\n"
        testResult += "   • Last Registration: \(diagnostics.lastRegistrationAttempt?.description ?? "Never")\n"
        testResult += "   • Registration Success: \(diagnostics.registrationSuccess ? "✅" : "❌")\n"
        testResult += "   • Retry Count: \(diagnostics.retryCount)\n"
        testResult += "   • User Session: \(diagnostics.userSessionAvailable ? "✅" : "❌")\n"
        
        // Test 3: Try to register VoIP pusher
        testResult += "\n3️⃣ Testing VoIP Registration:\n"
        let testResult = await notificationManager.testVoIPPusherRegistration()
        self.testResult += "   • Success: \(testResult.success ? "✅" : "❌")\n"
        self.testResult += "   • Message: \(testResult.message)\n"
        if let error = testResult.errorDetails {
            self.testResult += "   • Error: \(error)\n"
        }
        
        // Test 4: Check build configuration
        self.testResult += "\n4️⃣ Build Configuration:\n"
        #if LIVEKIT_ENABLED
        self.testResult += "   • LiveKit: ✅ Enabled\n"
        #else
        self.testResult += "   • LiveKit: ❌ Disabled\n"
        #endif
        
        #if DEBUG
        self.testResult += "   • Build: Debug\n"
        #else
        self.testResult += "   • Build: Release\n"
        #endif
        
        self.testResult += "   • Push Gateway: \(BuildConfiguration.shared.pushGatewayURL)\n"
        self.testResult += "   • VoIP App ID: \(BuildConfiguration.shared.voipAppId)\n"
        
        // Test 5: Simulate incoming call
        self.testResult += "\n5️⃣ Simulating VoIP Push:\n"
        self.testResult += "   ⚠️ Real test requires push from server\n"
        self.testResult += "   • Check device logs for incoming pushes\n"
        
        isLoading = false
    }
}

// Добавьте в DeveloperOptionsScreen:
// NavigationLink("VoIP Push Test") {
//     VoIPTestView()
// }

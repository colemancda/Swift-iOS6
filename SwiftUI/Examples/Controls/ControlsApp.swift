import SwiftUI

// Text fields, a slider, a stepper, progress views and alerts: SwiftUI's input
// controls on UIKit's iOS 6 ones.

@main
struct ControlsApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ControlsView()
            }
        }
    }
}

struct ControlsView: View {
    @State var name = ""
    @State var password = ""
    @State var greeting = "Type a name and press Done"
    @State var volume = 4.0
    @State var count = 3
    @State var notify = true
    @State var showsAlert = false
    @State var resets = 0

    var body: some View {
        List {
            TextField("Name", text: $name)
                .onSubmit { greeting = name.isEmpty ? "Nobody's there" : "Hello, \(name)!" }
            Text(greeting)
                .foregroundColor(.gray)
            SecureField("Password", text: $password)
            Text(password.isEmpty ? "No password" : "\(password.count) characters")
                .foregroundColor(.gray)

            VStack(alignment: .leading, spacing: 8) {
                Text("Volume: \(Int(volume)) of 10")
                Slider(value: $volume, in: 0...10, step: 1)
                ProgressView(value: volume, total: 10)
            }
            Stepper("Copies: \(count)", value: $count, in: 0...9)
            Toggle("Notifications", isOn: $notify)
            HStack {
                Text("Working")
                Spacer()
                ProgressView()
            }

            Button("Reset…") { showsAlert = true }
            Text(resets == 0 ? "Not reset yet" : "Reset \(resets) times")
                .foregroundColor(.gray)
        }
        .navigationTitle("Controls")
        .alert(isPresented: $showsAlert) {
            Alert(title: Text("Reset everything?"),
                  message: Text("The name, password, volume and copies go back to the start."),
                  primaryButton: .destructive(Text("Reset")) {
                      name = ""
                      password = ""
                      greeting = "Type a name and press Done"
                      volume = 4
                      count = 3
                      resets += 1
                  },
                  secondaryButton: .cancel())
        }
    }
}

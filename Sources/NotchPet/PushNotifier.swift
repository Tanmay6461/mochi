import Foundation

/// Sends a phone push through ntfy (https://ntfy.sh) when an agent has waited too long.
/// Only active when `ntfyTopic` is set in config.json; install the ntfy app and subscribe to that topic.
struct PushNotifier {
    let server: String
    let topic: String

    func send(title: String, message: String) {
        guard let url = URL(string: "\(server)/\(topic)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(title, forHTTPHeaderField: "Title")
        request.setValue("robot", forHTTPHeaderField: "Tags")
        request.httpBody = Data(message.utf8)
        URLSession.shared.dataTask(with: request) { _, _, error in
            if let error { NSLog("NotchPet: push failed: \(error)") }
        }.resume()
    }
}

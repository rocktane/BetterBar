import AppKit

let folder = Bundle.main.bundleURL.deletingLastPathComponent()
final class Delegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("refuse").path) ? .terminateCancel : .terminateNow
    }
}
let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
let items = (0..<2).map { index in
    let item = NSStatusBar.system.statusItem(withLength: 18)
    item.button?.title = index == 0 ? "A" : "B"
    return item
}
let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
    MainActor.assumeIsolated {
        let frames = items.compactMap { $0.button?.window?.frame }.sorted { $0.minX < $1.minX }
        guard frames.count == 2, frames.allSatisfy({ $0.height > 0 }) else { return }
        let report: [String: Double] = ["pid": Double(ProcessInfo.processInfo.processIdentifier),
            "distance": frames[1].midX - frames[0].midX]
        if let data = try? JSONSerialization.data(withJSONObject: report) {
            try? data.write(to: folder.appendingPathComponent("frames.json"), options: .atomic)
        }
    }
}
app.run()

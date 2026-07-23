// Shared system share-sheet wrapper - used by both FileBrowserView (swipe-to-download) and
// FileDetailView ("Share / Download"). Split out so both can present the same identifiable-URL
// sheet without duplicating the UIActivityViewController bridge.
import SwiftUI

struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.path }
}

struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

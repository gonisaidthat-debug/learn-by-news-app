import SwiftUI

struct NotebookView: View {
    var articleId: String
    var focusId: String? = nil
    var body: some View { Text("공책 \(articleId)").navigationTitle("공책") }
}

import SwiftUI
import MarkdownUI
import Foundation

// Custom theme that includes think block style
extension Theme {
    public var think: BlockStyle<BlockConfiguration> {
        get {
            BlockStyle { config in
                ThinkBlockView(config: config) // Use our custom ThinkBlockView
            }
        }
        set { }
    }
    
    public func think<Body: View>(
        @ViewBuilder body: @escaping (_ configuration: BlockConfiguration) -> Body
    ) -> Theme {
        var theme = self
        theme.think = .init(body: body)
        return theme
    }
}

// Custom view for the Think block
struct ThinkBlockView: View {
    let config: BlockConfiguration
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("💭")
                    .font(.title2)
                Text("Thinking...")
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }
            
            config.label
                .padding(.leading, 4)
        }
        .padding()
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.blue.opacity(0.1)) // Light blue background
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.blue.opacity(0.3), lineWidth: 1) // Border around the block
        )
    }
}

// Main view to demonstrate the functionality
struct ThinkDemoView: View {
    
    var source: String

//    // Custom parser to handle the think blocks by replacing <think> tags
//    func processThinkBlocks(_ input: String) -> String {
//        // Replace <think> tags with custom markers that MarkdownUI can handle
//        let processed = input
//            .replacingOccurrences(of: "<think>\n", with: "\n")
////            .replacingOccurrences(of: "</think>", with: "\n>")
//        return processed
//    }

    func processThinkBlocks(_ input: String) -> String {
        var mutableInput = input
        
        // Handle complete think blocks first
        let completePattern = "<think>([\\s\\S]*?)</think>"
        if let regex = try? NSRegularExpression(pattern: completePattern, options: []) {
            let range = NSRange(location: 0, length: mutableInput.utf16.count)
            let matches = regex.matches(in: mutableInput, options: [], range: range)
            
            for match in matches.reversed() {
                guard let contentRange = Range(match.range(at: 1), in: mutableInput),
                      let fullRange = Range(match.range(at: 0), in: mutableInput) else {
                    continue
                }
                
                let content = String(mutableInput[contentRange])
                let quotedLines = content
                    .components(separatedBy: .newlines)
                    .map { line in
                        line.trimmingCharacters(in: .whitespaces).isEmpty ? ">" : "> " + line
                    }
                    .joined(separator: "\n")
                
                mutableInput.replaceSubrange(fullRange, with: quotedLines)
            }
        }
        
        // Handle incomplete think blocks (no closing tag yet)
        let incompletePattern = "<think>([\\s\\S]*?)$"
        if let regex = try? NSRegularExpression(pattern: incompletePattern, options: []) {
            let range = NSRange(location: 0, length: mutableInput.utf16.count)
            if let match = regex.firstMatch(in: mutableInput, options: [], range: range),
               let matchRange = Range(match.range(at: 0), in: mutableInput),
               let contentRange = Range(match.range(at: 1), in: mutableInput) {
                
                let content = String(mutableInput[contentRange])
                let quotedLines = content
                    .components(separatedBy: .newlines)
                    .map { line in
                        line.trimmingCharacters(in: .whitespaces).isEmpty ? ">" : "> " + line
                    }
                    .joined(separator: "\n")
                
                // Keep the opening <think> tag for incomplete blocks
                mutableInput.replaceSubrange(matchRange, with: "\(quotedLines)")
            }
        }
        
        return mutableInput
    }
    
    init(source: String) {
        self.source = source
    }
    
    var body: some View {
        Markdown(processThinkBlocks(source))
            .markdownTheme(
                Theme()
                    .blockquote { config in
                        let content = config.content.renderMarkdown()
                        
                        // Extract content between markers
                        let cleanContent = content
//                            .replacingOccurrences(of: "[THINK_START]", with: "")
//                            .replacingOccurrences(of: "[THINK_END]", with: "")
//                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        
                        // Return ThinkBlockView with styled content for the think block
                        ThinkBlockView(config: config)
//                            .overlay(
//                                Markdown(cleanContent)
//                                    .padding(.leading, 16)
//                                    .foregroundColor(.primary)
//                            )

                    }
            )
    }
}
//
//#Preview {
//    ThinkDemoView(source: """
//        # My Markdown Document
//        
//        This is a simple Markdown document with a think block.
//        
//        <think>
//        This is the content inside the think block.
//        
//        I really like this content.
//        </think>
//        
//        ## Conclusion
//        
//        That's it!
//        """
////        .trimmingCharacters(in: .whitespacesAndNewlines)
//        .replacingOccurrences(of: "\n", with: "\n>")
//    )
//        .padding()
//        .previewLayout(.sizeThatFits)
//}
//


#Preview {
    let raw = """
    <think>
    
    This is a Markdown block This is a Markdown block This is a Markdown block This is a Markdown block This is a Markdown block This is a Markdown block This is a Markdown block This is a Markdown block This is a Markdown block.
    
    This is a paragraph inside a blockquote.

    """
    let output = raw
//        .replacingOccurrences(of: "\n", with: "\n>")
        // replace first occurence of ">" with "\n>"
    ThinkDemoView(source:output)
        .textSelection(.enabled)
}

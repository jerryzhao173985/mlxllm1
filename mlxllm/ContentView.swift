import MLX
import MLXLLM
import MLXLMCommon
import MLXRandom
import MarkdownUI
import Metal
import SwiftUI
import Tokenizers
import Hub

struct ContentView: View {

    @State var prompt = ""
    @State var llm = LLMEvaluator(modelID: "mlx-community/DeepSeek-R1-Distill-Qwen-7B-abliterated-4bit", maxTokens: 4096)
    @Environment(DeviceStat.self) private var deviceStat

    enum displayStyle: String, CaseIterable, Identifiable {
        case plain, markdown
        var id: Self { self }
    }

    @State private var selectedDisplayStyle = displayStyle.plain

    // Controls the ephemeral "Copied!" animation
    @State private var showCopyConfirmation = false

    // State variable to track if the user is at the bottom
    @State private var isAtBottom: Bool = true

    var body: some View {
        VStack(alignment: .leading) {
            VStack {
                HStack {
                    Text(llm.modelInfo)
                        .textFieldStyle(.roundedBorder)

                    Spacer()

                    Text(llm.stat)
                }
                // make it of a smaller font size
                .font(.caption)
                .padding(.bottom, 5)
                // make it look nicer
                .background(Color(.secondarySystemBackground))
                .cornerRadius(8)
                
                HStack {
                    Spacer()
                    if llm.running {
                        ProgressView()
                            .frame(maxHeight: 20)
                        Spacer()
                    }
                    Picker("", selection: $selectedDisplayStyle) {
                        ForEach(displayStyle.allCases, id: \.self) { option in
                            Text(option.rawValue.capitalized)
                                .tag(option)
                        }

                    }
                    .pickerStyle(.segmented)
                    #if os(visionOS)
                        .frame(maxWidth: 250)
                    #else
                        .frame(maxWidth: 150)
                    #endif
                }
            }
            // Use a ZStack so we can overlay the ephemeral "Copied!" message
            ZStack {
                // Scrollable area for the output
                // show the model output
                ScrollView(.vertical) {
                    ScrollViewReader { sp in
                        VStack(alignment: .leading, spacing: 0) {
                            if selectedDisplayStyle == .plain {
                                Text(llm.output)
                                    .textSelection(.enabled)
                            } else {
                                ThinkDemoView(source: llm.output)
                                    .textSelection(.enabled)
                            }

                            // Invisible view at the bottom to detect if user is at the bottom
                            Color.clear
                                .frame(height: 1)
                                .id("bottom")
                                .background(
                                    GeometryReader { geo in
                                        Color.clear
                                            .preference(key: ScrollViewOffsetPreferenceKey.self, value: geo.frame(in: .named("scrollView")).maxY)
                                    }
                                )
                        }
                        .onPreferenceChange(ScrollViewOffsetPreferenceKey.self) { maxY in
                            // Determine if the bottom is visible
                            // Adjust the threshold as needed
                            let scrollViewHeight = UIScreen.main.bounds.height
                            isAtBottom = maxY <= scrollViewHeight + 10 // 10 is a threshold
                        }
                        .onChange(of: llm.output) { _, _ in
                            if isAtBottom {
                                withAnimation {
                                    sp.scrollTo("bottom", anchor: .bottom)
                                }
                            }
                        }

                        Spacer()
                            .frame(width: 1, height: 1)
                            .id("bottom")
                    }
                }
                // Detect tap on the entire scrollable area
                .onTapGesture {
                    guard !llm.output.isEmpty else { return }
                    copyToClipboard(prompt: prompt, response: llm.output)

                    // Trigger the "Copied!" animation
                    withAnimation {
                        showCopyConfirmation = true
                    }
                    // Hide the confirmation after 1.5 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation {
                            showCopyConfirmation = false
                        }
                    }
                }
                
                // Show ephemeral "Copied!" pop-up if tapped
                if showCopyConfirmation {
                    VStack {
                        Label("Copied!", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.green.opacity(0.9).cornerRadius(8))
                            .transition(.scale.combined(with: .opacity))
                    }
                    // Position it near the top (adjust to taste)
                    .padding(.top, 30)
                }
            }

            HStack {
                TextField("prompt", text: $prompt)
                    .onSubmit(generate)
                    .disabled(llm.running)
                    #if os(visionOS)
                        .textFieldStyle(.roundedBorder)
                    #endif
                Button("generate", action: generate)
                    .disabled(llm.running)
            }
        }
        #if os(visionOS)
            .padding(40)
        #else
            .padding()
        #endif
        .toolbar {
            ToolbarItem {
                Label(
                    "Memory Usage: \(deviceStat.gpuUsage.activeMemory.formatted(.byteCount(style: .memory)))",
                    systemImage: "info.circle.fill"
                )
                .labelStyle(.titleAndIcon)
                .padding(.horizontal)
                .help(
                    Text(
                        """
                        Active Memory: \(deviceStat.gpuUsage.activeMemory.formatted(.byteCount(style: .memory)))/\(GPU.memoryLimit.formatted(.byteCount(style: .memory)))
                        Cache Memory: \(deviceStat.gpuUsage.cacheMemory.formatted(.byteCount(style: .memory)))/\(GPU.cacheLimit.formatted(.byteCount(style: .memory)))
                        Peak Memory: \(deviceStat.gpuUsage.peakMemory.formatted(.byteCount(style: .memory)))
                        """
                    )
                )
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        copyToClipboard(prompt: prompt, response: llm.output)
                        // copyToClipboard(llm.output)
                    }
                } label: {
                    Label("Copy Output", systemImage: "doc.on.doc.fill")
                }
                .disabled(llm.output.isEmpty)
                // .disabled(llm.output == "")
                .labelStyle(.titleAndIcon)
            }

        }
        .coordinateSpace(name: "scrollView") // Define coordinate space for GeometryReader
        .task {
            self.prompt = "高跟鞋 简要简洁分析" /*llm.modelConfiguration.defaultPrompt*/

            // pre-load the weights on launch to speed up the first generation
            _ = try? await llm.load()
        }
    }

    private func generate() {
        Task {
            await llm.generate(prompt: prompt)
        }
    }

    // Removed the commented copyToClipboard function

    private func copyToClipboard(prompt: String, response: String) {
        // Format text as <input>\n<response>
        let formattedText = "\(prompt)\n\(response)"
        #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(formattedText, forType: .string)
        #else
            UIPasteboard.general.string = formattedText
        #endif
    }
}

// PreferenceKey to track scroll offset
struct ScrollViewOffsetPreferenceKey: PreferenceKey {
    typealias Value = CGFloat
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}


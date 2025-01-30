import Foundation
import Hub
import MLX
import MLXNN
import MLXLLM
import MLXLMCommon
import MLXRandom
import MarkdownUI
import Metal
import SwiftUI
import Tokenizers

// MARK: - A simple UserInputProcessor implementation
// You can keep customizing this based on your needs.

struct LLMUserInputProcessor: UserInputProcessor {
    let tokenizer: Tokenizer
    let configuration: ModelConfiguration

    init(tokenizer: any Tokenizer, configuration: ModelConfiguration) {
        self.tokenizer = tokenizer
        self.configuration = configuration
    }

    func prepare(input: UserInput) throws -> LMInput {
        do {
            let messages = input.prompt.asMessages()
            let promptTokens = try tokenizer.applyChatTemplate(messages: messages)
            return LMInput(tokens: MLXArray(promptTokens))
        } catch {
            // Fall back to direct text encoding if a chat template is not available
            let prompt = input.prompt
                .asMessages()
                .compactMap { $0["content"] }
                .joined(separator: ". ")
            let promptTokens = tokenizer.encode(text: prompt)
            return LMInput(tokens: MLXArray(promptTokens))
        }
    }
}

// MARK: - LLMEvaluator

@Observable
@MainActor
class LLMEvaluator {

    // MARK: - Public Variables
    
    /// The ID of the model on Hugging Face (e.g., "gpt2", "openlm-research/open_llama_7b", etc.)
    var modelID: String
    
    /// Whether the generator is currently running
    var running = false

    /// The latest text output from the model
    var output = ""
    
    /// Information string about the model loading process (e.g., “Downloading 45%”)
    var modelInfo = ""
    
    /// Simple stats about the generation (e.g., tokens/second)
    var stat = ""
    
    // MARK: - Configuration / Parameters
    
    /// A base prompt template that your use-case might need.
    /// This is just an example; feel free to adjust or remove.
    let basePrompt = """
    给出一个主题，请按照给定的主题，切实准确简洁且情感丰富地写一首现代诗：{title}
    """
    
    /// Generation parameters
    let generateParameters = GenerateParameters(temperature: 0)
    
    /// Maximum tokens to generate
    var maxTokens: Int = 240
    
    /// Update the display every N tokens
    let displayEveryNTokens = 4
    
    /// Where in local file system to store all downloaded models
    let localRootDirectory: URL
    
    // MARK: - Internal State

    enum LoadState {
        case idle
        case loaded(ModelContainer)
    }
    private var loadState: LoadState = .idle
    
    // MARK: - Initializer

    init(modelID: String, maxTokens: Int = 240) {
        self.modelID = modelID
        self.maxTokens = maxTokens
        
        // By default, store in: Documents/huggingface/models/<model-id>
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.localRootDirectory = documentsDir
            .appendingPathComponent("huggingface/models")
            .appendingPathComponent(modelID)
    }

    // MARK: - Model Directory Helpers

    /// Check if a model is already downloaded locally by verifying the safetensors file exists.
    private func modelExistsLocally() -> Bool {
        let weightsURL = localRootDirectory.appendingPathComponent("model.safetensors")
        return FileManager.default.fileExists(atPath: weightsURL.path)
    }

    /// Return a `ModelConfiguration` tailored to the local root directory.
    private func makeModelConfiguration() -> ModelConfiguration {
        return ModelConfiguration(
            directory: localRootDirectory,
            defaultPrompt: "Tell me about the history of Spain."  // or any fallback prompt
        )
    }

    // MARK: - Loading the Model
    
    /// The main loading function that checks local availability first, otherwise downloads.
    func load() async throws -> ModelContainer {
        switch loadState {
        case .idle:
            // Restrict GPU memory usage if needed
            MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)
            
            let container: ModelContainer
            if modelExistsLocally() {
                // Load from local
                modelInfo = "Loading model from local directory: \(modelID)"
                container = try await loadModelContainerFromLocal()
            } else {
                // Download from Hugging Face
                modelInfo = "Model not found locally. Downloading: \(modelID)"
                container = try await downloadAndLoadContainer()
            }
            
            let numParams = await container.perform { $0.model.numParameters() }
            modelInfo = "Loaded \(modelID). Weights: \(numParams / (1024 * 1024))M"
            loadState = .loaded(container)
            return container
            
        case .loaded(let container):
            return container
        }
    }
    
    /// Load a model container from local files without any network call.
    private func loadModelContainerFromLocal() async throws -> ModelContainer {
        let modelConfiguration = makeModelConfiguration()
        // A direct approach:
        // 1. Load all config from the local directory
        // 2. Create a bare model
        // 3. Load weights
        // 4. Create a tokenizer
        // 5. Return the container
        return try await ModelContainer(context: loadModelContext(modelConfiguration: modelConfiguration))
    }

    /// Download from the Hugging Face hub and then load as a container.
    private func downloadAndLoadContainer() async throws -> ModelContainer {
        let modelConfiguration = makeModelConfiguration()
        let hub = HubApi()
        
        // Download model files (json, safetensors, etc.)
        try await downloadModelFiles(hub: hub, modelID: modelID)

        // Then load via the factory convenience call
        // which also sets up tokenizers, weights, etc.
        return try await LLMModelFactory.shared.loadContainer(
            configuration: modelConfiguration
        ) { progress in
            Task { @MainActor in
                // Show user the download progress
                self.modelInfo = "Downloading \(self.modelID): \(Int(progress.fractionCompleted * 100))%"
            }
        }
    }

    // MARK: - Downloading Model Files

    /// Download model files (e.g., *.safetensors, *.json) from the Hugging Face Hub to localRootDirectory.
    private func downloadModelFiles(hub: HubApi, modelID: String) async throws {
        let repo = Hub.Repo(id: modelID)
        let modelFiles = ["*.safetensors", "*.json"]  // Adjust filters as needed

        let _ = try await hub.snapshot(from: repo, matching: modelFiles) { progress in
            Task { @MainActor in
                self.modelInfo = "Downloading \(modelID): \(Int(progress.fractionCompleted * 100))%"
            }
        }
    }
    
    // MARK: - Manually Building a ModelContext

    /// Create a `ModelContext` from local files (configuration, weights, tokenizer).
    private func loadModelContext(modelConfiguration: ModelConfiguration) async throws -> ModelContext {
        // 1. Load the base config (to know modelType, quantization, etc.)
        let configurationURL = modelConfiguration.modelDirectory().appendingPathComponent("config.json")
        let baseConfig = try JSONDecoder().decode(BaseConfiguration.self, from: Data(contentsOf: configurationURL))
        
        // 2. Create an empty model from the base config
        let model = try LLMModelFactory.shared.typeRegistry.createModel(
            configuration: configurationURL,
            modelType: baseConfig.modelType
        )
        
        // 3. Load the weights from disk
        try loadWeights(modelDirectory: modelConfiguration.modelDirectory(), model: model, quantization: baseConfig.quantization)
        
        // 4. Load a tokenizer
        let tokenizer = try await loadTokenizer(configuration: modelConfiguration, hub: HubApi(downloadBase: modelConfiguration.modelDirectory()))
        
        // 5. Construct the processor
        let processor = LLMUserInputProcessor(tokenizer: tokenizer, configuration: modelConfiguration)
        
        // 6. Return the full context
        return ModelContext(configuration: modelConfiguration, model: model, processor: processor, tokenizer: tokenizer)
    }

    // MARK: - Generating Text

    /// Generate text output by injecting `prompt` into the base prompt template.
    func generate(prompt: String) async {
        guard !running else { return }
        running = true
        self.output = ""
        // Capture `maxTokens` and `displayEveryNTokens` locally
        let localMaxTokens = self.maxTokens

        do {
            let modelContainer = try await load()
            // Interpolate the user input into the base prompt, if needed
            let fullPrompt = prompt
//            let fullPrompt = basePrompt.replacingOccurrences(of: "{title}", with: prompt)
            
            // Seed the random number generator for reproducible results
            MLXRandom.seed(UInt64(Date.timeIntervalSinceReferenceDate * 1000))

            // Perform generation
            let result = try await modelContainer.perform { context in
                let input = try await context.processor.prepare(input: .init(prompt: fullPrompt))
                return try MLXLMCommon.generate(
                    input: input,
                    parameters: generateParameters,
                    context: context
                ) { tokens in
                    if tokens.count % displayEveryNTokens == 0 {
                        let text = context.tokenizer.decode(tokens: tokens)
                        Task { @MainActor in
                            self.output = text
                        }
                    }
                    
                    return tokens.count >= localMaxTokens ? .stop : .more
                }
            }
            
            // Final output if we haven’t already updated it
            if result.output != self.output {
                self.output = result.output
            }
            
            // Update stats
            self.stat = " Tokens/second: \(String(format: "%.3f", result.tokensPerSecond))"
            
        } catch {
            self.output = "Failed: \(error)"
        }

        running = false
    }
}

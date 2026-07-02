import Foundation

/// Provider id → display name, matching CodexBar's `ProviderDescriptor` naming.
/// ponytail: map for known providers + a camelCase-split fallback for new ones,
/// so we don't ship "opencodego" when CodexBar shows "OpenCode Go".
public enum ProviderDisplayName {
    private static let known: [String: String] = [
        "amp": "Amp",
        "antigravity": "Antigravity",
        "augment": "Augment",
        "claude": "Claude",
        "codex": "Codex",
        "copilot": "Copilot",
        "cursor": "Cursor",
        "factory": "Droid",
        "gemini": "Gemini",
        "jetbrains": "JetBrains AI",
        "kilo": "Kilo",
        "kimi": "Kimi",
        "kimik2": "Kimi K2",
        "kiro": "Kiro",
        "minimax": "MiniMax",
        "ollama": "Ollama",
        "opencode": "OpenCode",
        "opencodego": "OpenCode Go",
        "openrouter": "OpenRouter",
        "synthetic": "Synthetic",
        "vertexai": "Vertex AI",
        "warp": "Warp",
        "zai": "z.ai",
        "azureopenai": "Azure OpenAI",
        "openai": "OpenAI",
        "windsurf": "Windsurf",
        "deepseek": "DeepSeek",
        "mistral": "Mistral",
        "grok": "Grok",
        "groq": "Groq",
        "bedrock": "Bedrock",
        "perplexity": "Perplexity",
        "moonshot": "Moonshot",
        "devin": "Devin",
        "doubao": "Doubao",
        "mimo": "Mimo",
        "zed": "Zed",
        "elevenlabs": "ElevenLabs",
        "deepgram": "Deepgram",
        "t3chat": "T3 Chat",
        "manus": "Manus",
        "abacusai": "AbacusAI",
        "venice": "Venice",
        "codebuff": "Codebuff",
        "crof": "Crof",
        "commandcode": "Command Code",
        "stepfun": "StepFun",
        "chutes": "Chutes",
        "poe": "Poe",
        "litellm": "LiteLLM",
        "llmproxy": "LLM Proxy",
        "alibaba": "Alibaba",
        "alibabatokenplan": "Alibaba Token Plan",
    ]

    public static func name(for id: String) -> String {
        if let n = known[id] { return n }
        // ponytail: fallback — split camelCase / known acronyms, title-case.
        return splitCamel(id)
    }

    #if DEBUG
    /// ponytail: self-check — duplicate keys crash at runtime (Swift fatal); catch at launch.
    private static let _assertNoDupes: Void = {
        let keys = known.keys
        assert(keys.count == Set(keys).count, "ProviderDisplayName.known has duplicate keys")
    }()
    #endif

    private static func splitCamel(_ s: String) -> String {
        var out = ""
        for (i, ch) in s.enumerated() {
            if i > 0 && ch.isUppercase && s[s.index(s.startIndex, offsetBy: i - 1)].isLowercase {
                out.append(" ")
            }
            out.append(ch)
        }
        return out.capitalized
    }
}

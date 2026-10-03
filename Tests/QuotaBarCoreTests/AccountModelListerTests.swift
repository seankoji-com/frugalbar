import Testing
import Foundation
@testable import QuotaBarCore

/// The selectable-model decisions per vendor, on trimmed copies of the live
/// responses captured on 3 Oct 2026.
@Suite("AccountModelLister parsers")
struct AccountModelListerTests {

    private func ids(_ models: [AccountModel]?) -> [String]? { models?.map(\.id) }

    @Test("Codex: only models the picker lists")
    func codex() {
        let body = #"""
        {"models":[
          {"slug":"gpt-6.1-sol","display_name":"GPT-6.1-Sol","visibility":"list"},
          {"slug":"gpt-reserve","display_name":"Reserve","visibility":"hide"},
          {"slug":"codex-auto-review","visibility":"hide"},
          {"slug":"gpt-6-luna","visibility":"list"}
        ]}
        """#
        let models = AccountModelLister.parseCodexModels(Data(body.utf8))
        #expect(ids(models) == ["gpt-6.1-sol", "gpt-6-luna"])
        #expect(models?.first?.name == "GPT-6.1-Sol")
        #expect(AccountModelLister.parseCodexModels(Data(#"{"detail":"bad"}"#.utf8)) == nil)
    }

    @Test("Copilot: picker chat models not disabled by policy; policy may be absent")
    func copilot() {
        let body = #"""
        {"data":[
          {"id":"claude-opus-5.5","name":"Claude Opus 5.5","model_picker_enabled":true,
           "policy":{"state":"enabled"},"capabilities":{"type":"chat"}},
          {"id":"grok-4.7","name":"Grok 4.7","model_picker_enabled":true,"capabilities":{"type":"chat"}},
          {"id":"gpt-6.1-sol","model_picker_enabled":true,"policy":{"state":"disabled"},"capabilities":{"type":"chat"}},
          {"id":"text-embedding-3","model_picker_enabled":true,"capabilities":{"type":"embeddings"}},
          {"id":"gpt-4o-mini","model_picker_enabled":false,"capabilities":{"type":"chat"}}
        ]}
        """#
        #expect(ids(AccountModelLister.parseCopilotModels(Data(body.utf8))) == ["claude-opus-5.5", "grok-4.7"])
    }

    @Test("Claude: entitled models only, named from the model options")
    func claude() {
        let body = #"""
        {"model_access":[
          {"api_name":"claude-opus-5-5","entitled":true,"max_effort_level":"high"},
          {"api_name":"claude-mythos-5-1","entitled":false},
          {"api_name":"claude-sonnet-5-5","entitled":true}
        ],
        "additional_model_options":[{"model":"claude-opus-5-5","name":"Opus 5.5","description":""}]}
        """#
        let models = AccountModelLister.parseClaudeBootstrap(Data(body.utf8))
        #expect(ids(models) == ["claude-opus-5-5", "claude-sonnet-5-5"])
        #expect(models?.first?.name == "Opus 5.5")
        // No `model_access` at all is not an empty entitlement list.
        #expect(AccountModelLister.parseClaudeBootstrap(Data(#"{"oauth_account":{}}"#.utf8)) == nil)
    }

    @Test("Gemini: internal helper ids are dropped")
    func gemini() {
        let body = #"""
        {"models":{
          "gemini-3.8-pro":{"displayName":"Gemini 3.8 Pro","quotaInfo":{"remainingFraction":1}},
          "chat_20706":{}, "tab_flash_lite":{}, "rev_x":{},
          "gemini-3.8-flash-image":{}, "gemini-mquery":{}, "gemini-3.8-flash-lite":{},
          "claude-sonnet-5-5":{"displayName":"Claude Sonnet 5.5"}
        }}
        """#
        #expect(ids(AccountModelLister.parseGeminiModels(Data(body.utf8))) == ["claude-sonnet-5-5", "gemini-3.8-pro"])
    }

    @Test("Kiro: every listed model id, with its name")
    func kiro() {
        let body = #"""
        {"defaultModel":{"modelId":"auto"},"models":[
          {"modelId":"auto","modelName":"Auto","rateMultiplier":1.0},
          {"modelId":"claude-sonnet-4.5","modelName":"Claude Sonnet 4.5"}
        ]}
        """#
        let models = AccountModelLister.parseKiroModels(Data(body.utf8))
        #expect(ids(models) == ["auto", "claude-sonnet-4.5"])
        #expect(models?.last?.name == "Claude Sonnet 4.5")
    }

    @Test("OpenAI-style lists (OpenCode Go, Grok, DevPass) drop deactivated models")
    func idList() {
        let body = #"""
        {"object":"list","data":[
          {"id":"grok-4.7","name":"Grok 4.7"},
          {"id":"gpt-6.1-sol","display_name":"GPT-6.1 Sol","name":"gpt-6.1-sol"},
          {"id":"old","deactivated_at":"2026-09-01T00:00:00Z"},
          {"id":""}
        ]}
        """#
        let models = AccountModelLister.parseIdList(Data(body.utf8))
        #expect(ids(models) == ["grok-4.7", "gpt-6.1-sol"])
        #expect(models?.last?.name == "GPT-6.1 Sol")
        #expect(AccountModelLister.parseIdList(Data(#"{"error":"unauthorized"}"#.utf8)) == nil)
    }

    @Test("ClinePass: the pass list counts only when the plan enables it")
    func clinePass() {
        let plan = #"{"data":{"plan":{"name":"Cline Pass","entitlements":{"cline_pass":{"enabled":true}}}}}"#
        let noPass = #"{"data":{"plan":{"name":"Free","entitlements":{"cline_pass":{"enabled":false}}}}}"#
        #expect(AccountModelLister.clinePassEnabled(Data(plan.utf8)))
        #expect(!AccountModelLister.clinePassEnabled(Data(noPass.utf8)))
        #expect(!AccountModelLister.clinePassEnabled(Data("{}".utf8)))

        let wrapped = #"{"data":{"clinePass":[{"id":"cline-pass/kimi-k3"},{"id":"cline-pass/glm-5.3"}],"free":[{"id":"x"}]}}"#
        let bare = #"{"clinePass":[{"id":"cline-pass/kimi-k3"}],"recommended":[]}"#
        #expect(ids(AccountModelLister.parseClinePassModels(Data(wrapped.utf8))) == ["cline-pass/kimi-k3", "cline-pass/glm-5.3"])
        #expect(ids(AccountModelLister.parseClinePassModels(Data(bare.utf8))) == ["cline-pass/kimi-k3"])
        #expect(AccountModelLister.parseClinePassModels(Data(#"{"free":[]}"#.utf8)) == nil)
    }

    @Test("the live lister never reaches the network under a test host")
    func liveIsInertInTests() async {
        for vendor in AccountModelLister.supportedVendors {
            #expect(await AccountModelLister.live(vendor) == nil)
        }
        #expect(!AccountModelLister.supportedVendors.contains(.commandcode))
        #expect(!AccountModelLister.supportedVendors.contains(.openrouter))
        #expect(AccountModelLister.productName(.openai) == "Codex")
    }
}

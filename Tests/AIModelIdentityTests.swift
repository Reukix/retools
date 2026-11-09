import XCTest
import UIKit
@testable import LiveContainerSwiftUI

final class AIModelIdentityTests: XCTestCase {
    func testModelsKeepTheirBrandOnCompatibleGateways() {
        let models: [(String, AIModelBrand)] = [
            ("gpt-image-2.6-sunburst", .openAI), ("chatgpt-image-latest", .openAI),
            ("dall-e-3", .openAI), ("o3-mini", .openAI),
            ("claude-sonnet-4-5", .claude), ("gemini-2.5-pro", .gemini),
            ("deepseek-chat", .deepSeek), ("Qwen3-235B-A22B", .qwen),
            ("grok-4", .xAI), ("Llama-3.3-70B-Instruct", .meta), ("codestral-latest", .mistral)
        ]
        for (model, brand) in models { XCTAssertEqual(AIModelBrand.resolve(model: model, provider: .openAI), brand, model) }
    }

    func testNamespacedModelsAndDisplayNamesAreRecognized() {
        XCTAssertEqual(AIModelBrand.resolve(model: "anthropic/claude-opus-4.1:thinking"), .claude)
        XCTAssertEqual(AIModelBrand.resolve(model: "gateway/openai/gpt-image-2.6-sunburst"), .openAI)
        XCTAssertEqual(AIModelBrand.resolve(model: "Qwen/Qwen2.5-VL-72B-Instruct"), .qwen)
        XCTAssertEqual(AIModelBrand.resolve(model: "custom-model", name: "Claude Sonnet"), .claude)
        XCTAssertEqual(AIModelBrand.resolve(model: "claude-sonnet-4-5", name: "GPT 代理"), .claude)
    }

    func testUnknownCompatibleModelsUseNeutralIdentity() {
        XCTAssertNil(AIModelBrand.resolve(model: "custom-model", provider: .openAI))
        XCTAssertNil(AIModelBrand.resolve(model: "", provider: .anthropic))
        XCTAssertEqual(AIModelBrand.resolve(model: "custom-model", provider: .anthropic), .claude)
    }

    func testBrandAssetsAreBundledWithTheUIFramework() {
        for brand in AIModelBrand.allCases {
            XCTAssertNotNil(UIImage(named: brand.assetName, in: AIModelBrand.assetBundle, compatibleWith: nil), brand.rawValue)
        }
    }
}

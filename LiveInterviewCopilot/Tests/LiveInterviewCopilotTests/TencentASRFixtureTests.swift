import Foundation
import XCTest
@testable import LiveInterviewCopilotKit

final class TencentASRFixtureTests: XCTestCase {
    func testDefaultEngineUsesStandardFreeQuotaModel() {
        XCTAssertEqual(TencentASRConfiguration.defaultEngineModel, "16k_zh")
    }

    func testSignatureSourceSortsParametersLexicographically() {
        XCTAssertEqual(
            TencentASRRequestSigner.signatureSource(
                appID: "123456",
                parameters: ["voice_id": "voice", "engine_model_type": "16k_zh_en", "nonce": "11"]
            ),
            "asr.cloud.tencent.com/asr/v2/123456?engine_model_type=16k_zh_en&nonce=11&voice_id=voice"
        )
    }

    func testSignedURLPercentEncodesBase64ReservedCharacters() throws {
        let configuration = TencentASRConfiguration(
            credentials: TencentASRCredentials(
                appID: "123456",
                secretID: "fixture-secret-id",
                secretKey: "fixture-key"
            ),
            engineModel: "16k_zh_en"
        )

        let url = try TencentASRRequestSigner.signedURL(
            configuration: configuration,
            voiceID: "voice-fixture",
            timestamp: 1_000,
            nonce: 11
        )

        XCTAssertTrue(url.absoluteString.contains("signature=KUrlpeMnPOM%2F73l%2Bg4u06z75tYY%3D"))
        XCTAssertFalse(url.absoluteString.contains("fixture-key"))
    }

    func testAppIDLookupBuildsSignedCAMRequestWithoutExposingSecretKey() throws {
        let request = try TencentAccountAppIDResolver.signedRequest(
            secretID: "fixture-secret-id",
            secretKey: "fixture-secret-key",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(request.url?.absoluteString, "https://cam.tencentcloudapi.com")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-TC-Action"), "GetUserAppId")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-TC-Version"), "2019-01-16")
        XCTAssertEqual(request.httpBody, Data("{}".utf8))
        let authorization = try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(authorization.contains("Credential=fixture-secret-id/2023-11-14/cam/tc3_request"))
        XCTAssertTrue(authorization.contains("SignedHeaders=content-type;host"))
        XCTAssertFalse(authorization.contains("fixture-secret-key"))
    }

    func testAppIDLookupRejectsMissingSecretPair() {
        XCTAssertThrowsError(
            try TencentAccountAppIDResolver.signedRequest(
                secretID: "",
                secretKey: "",
                timestamp: Date(timeIntervalSince1970: 1_700_000_000)
            )
        ) { error in
            XCTAssertEqual(error.localizedDescription, "请先填写 SecretID 和 SecretKey。")
        }
    }

    func testParserDecodesPartialStableAndFinalFixtures() throws {
        let partial = try TencentASRMessageParser.parse(Data(#"""
        {
            "code": 0,
            "message": "success",
            "result": {"slice_type": 1, "index": 0, "voice_text_str": "正在识别"},
            "final": 0
        }
        """#.utf8))
        let stable = try TencentASRMessageParser.parse(Data(#"""
        {
            "code": 0,
            "result": {"slice_type": 2, "index": 0, "voice_text_str": "请介绍项目"},
            "final": 0
        }
        """#.utf8))
        let final = try TencentASRMessageParser.parse(Data(#"""
        {
            "code": 0,
            "message": "success",
            "final": 1
        }
        """#.utf8))

        XCTAssertEqual(partial.result?.sliceType, 1)
        XCTAssertEqual(partial.result?.voiceText, "正在识别")
        XCTAssertEqual(stable.result?.sliceType, 2)
        XCTAssertEqual(stable.result?.voiceText, "请介绍项目")
        XCTAssertEqual(final.isFinal, 1)
    }

    func testParserMapsMalformedJSONToSafeError() {
        XCTAssertThrowsError(try TencentASRMessageParser.parse(Data("not-json".utf8))) { error in
            XCTAssertEqual(error as? InterviewASRError, .invalidResponse)
        }
    }
}

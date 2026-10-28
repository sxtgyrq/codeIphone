import XCTest
@testable import HelloYrq

final class MapNodeEditorTests: XCTestCase {
    func testAllRelationsAndNotUseServerExpressions() {
        XCTAssertEqual(MapNodeEditorRules.relations.map(\.symbol), ["=", "→", "↔", "¬", "⊇", "⊋", "⊆", "⊊"])
        for relation in MapNodeEditorRules.relations {
            XCTAssertEqual(MapNodeEditorRules.relationLogic(relation.symbol), relation.symbol == "¬" ? "¬(?)" : relation.symbol)
        }
    }

    func testBranchToggleAddsAndRemovesExactlyOneNegation() {
        XCTAssertEqual(MapNodeEditorRules.switchBranch(from: "True", to: "False", logic: "¬P"), "¬¬P")
        XCTAssertEqual(MapNodeEditorRules.switchBranch(from: "False", to: "True", logic: "¬¬P"), "¬P")
        XCTAssertEqual(MapNodeEditorRules.switchBranch(from: "True", to: "False", logic: ""), "")
        XCTAssertEqual(MapNodeEditorRules.branchSource(value: "False", logic: "¬P(a)"), "P(a)")
        XCTAssertNil(MapNodeEditorRules.branchSource(value: "False", logic: "P(a)"))
        XCTAssertNil(MapNodeEditorRules.branchSource(value: "False", logic: "¬"))
    }

    func testCasingKeepsDotNetSimpleMappingAndOnlyNormalizesInstancePrefix() {
        XCTAssertEqual(MapNodeEditorRules.uppercase("straße ﬁ"), "STRAßE ﬁ")
        XCTAssertEqual(MapNodeEditorRules.lowercase("ΟΣ İ I"), "οσ i i")
        XCTAssertEqual(MapNodeEditorRules.operandLogic("human(Name=Alice)", kind: "Custom"), "human(Name=Alice)")
        XCTAssertEqual(MapNodeEditorRules.operandLogic("Human", kind: "Class"), "HUMAN")
        XCTAssertEqual(MapNodeEditorRules.operandLogic("Human", kind: "Instance"), "human")
        XCTAssertEqual(MapNodeEditorRules.normalizeInstance("HUMAN(Name=Alice) Alias"), "human(Name=Alice) Alias")
    }

    func testInstanceAttributesAndAliasMatchServerExpression() {
        XCTAssertTrue(MapNodeEditorRules.validInstance("human(id=1,name=Alice) c"))
        XCTAssertEqual(MapNodeEditorRules.instanceExpression("human(id=1,name=Alice) c"), "c∈HUMAN∧1∈HUMAN.ID∧Alice∈HUMAN.NAME")
        XCTAssertEqual(MapNodeEditorRules.instanceExpression("human()"), "human()∈HUMAN")
        XCTAssertEqual(MapNodeEditorRules.instanceParent("human(name=Alice) c"), "HUMAN")
        for invalid in ["human", "(id=1)", "human(id=)", "human(=1)", "human(id=1,)", "human()c", "human() ", "human(())"] {
            XCTAssertFalse(MapNodeEditorRules.validInstance(invalid), invalid)
        }
    }

    func testValidationPreservesServerCreationDefaultsButRejectsInvalidEdits() {
        let blank = MapNodeProperties(value: "命题", info: "", logicLanguage: "", operandKind: "Custom")
        XCTAssertNil(MapNodeEditorRules.validation(properties: blank, size: 6, isNew: true))
        XCTAssertNotNil(MapNodeEditorRules.validation(properties: blank, size: 6, isNew: false))
        XCTAssertNil(MapNodeEditorRules.validation(properties: blank, size: 10, isNew: true, automaticInstance: true))
        XCTAssertNotNil(MapNodeEditorRules.validation(properties: blank, size: 10, isNew: true))
        var multiline = blank
        multiline.value = "first\nsecond"
        XCTAssertNotNil(MapNodeEditorRules.validation(properties: multiline, size: 6, isNew: true))
        multiline.value = "值"; multiline.info = "first\nsecond"
        XCTAssertNil(MapNodeEditorRules.validation(properties: multiline, size: 6, isNew: true))
        // Server limits count UTF-16 code units, not Swift grapheme clusters.
        multiline.value = String(repeating: "😀", count: 17)
        XCTAssertNotNil(MapNodeEditorRules.validation(properties: multiline, size: 6, isNew: true))
    }

    func testOnlyEligibleLn12ParentsOfferAutomaticInstances() {
        let parent = MapLogicalNode(code: "AAAAAAAAAA", owner: "demo", version: 1, x: 100.5, y: 100.5,
                                    sideLength: 12, properties: MapNodeProperties(value: "HUMAN"))
        XCTAssertTrue(MapNodeEditorRules.canInstantiate(parent))
        var chinese = parent
        chinese.properties.value = "人类"
        XCTAssertFalse(MapNodeEditorRules.canInstantiate(chinese))
        chinese.properties.value = "human"
        XCTAssertFalse(MapNodeEditorRules.canInstantiate(chinese))
        chinese.properties.value = "HUMAN()"
        XCTAssertFalse(MapNodeEditorRules.canInstantiate(chinese))
    }

    func testConflictLocationsAcceptBothExactServerDuplicateSuffixes() {
        let cases = [("DuplicateLogicalNodeValue", "值"), ("DuplicateLogicalNodeLogic", "逻辑语言")]
        for (code, kind) in cases {
            let error = MapAPIError(code: code, message: "边长为 12 的 LN \(kind)“HUMAN”已被 LN ABCDEFGHIJ（中心坐标 X=125.5, Y=482530.5）使用，请使用不同的\(kind)。")
            XCTAssertEqual(MapNodeConflictLocation.parse(error), MapNodePreviewLocation(code: "ABCDEFGHIJ", x: 125.5, y: 482530.5))
        }
    }

    func testConflictLocationRequiresTheTwoSpecifiedErrorCodes() {
        let message = conflictMessage()
        for code in ["VersionConflict", "HttpError", "LogicalNodeNotFound", "DuplicateLogicalNodeLogic ", "duplicatelogicalnodevalue", ""] {
            XCTAssertNil(MapNodeConflictLocation.parse(MapAPIError(code: code, message: message)), code)
        }
        XCTAssertNil(MapNodeConflictLocation.parse(NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: message])))
    }

    func testConflictLocationRejectsChangedSyntaxAndNonterminalCoordinates() {
        let valid = conflictMessage()
        let invalid = [
            valid + "\n", valid + " 附加文本", valid + " https://example.invalid/",
            valid.replacingOccurrences(of: "ABCDEFGHIJ", with: "ABCDEFGHI"),
            valid.replacingOccurrences(of: "ABCDEFGHIJ", with: "ABCDEFGHIJK"),
            valid.replacingOccurrences(of: "ABCDEFGHIJ", with: "abcdefghij"),
            valid.replacingOccurrences(of: "ABCDEFGHIJ", with: "ABCD1FGHIJ"),
            valid.replacingOccurrences(of: "（", with: "("),
            valid.replacingOccurrences(of: ", Y=", with: ",Y="),
            valid.replacingOccurrences(of: "X=", with: "X ="),
            valid.replacingOccurrences(of: "使用，请使用不同的值。", with: "使用。")
        ]
        for message in invalid {
            XCTAssertNil(MapNodeConflictLocation.parse(MapAPIError(code: "DuplicateLogicalNodeValue", message: message)), message)
        }
    }

    func testConflictLocationRejectsNondecimalOrNonfiniteCoordinates() {
        for coordinate in ["-1", "+1", "1e2", "nan", "NaN", "inf", "Infinity", "1,000", ".5", "1.", "１.５", " 1", "1 "] {
            for message in [conflictMessage(x: coordinate), conflictMessage(y: coordinate)] {
                XCTAssertNil(MapNodeConflictLocation.parse(MapAPIError(code: "DuplicateLogicalNodeValue", message: message)), message)
            }
        }
    }

    func testConflictLocationChecksExactMapBoundsBeforeDoubleRounding() {
        let boundary = MapAPIError(code: "DuplicateLogicalNodeValue", message: conflictMessage(x: "0000000.000", y: "500000.000"))
        XCTAssertEqual(MapNodeConflictLocation.parse(boundary), MapNodePreviewLocation(code: "ABCDEFGHIJ", x: 0, y: 500_000))
        for coordinate in ["500001", "500000.00000000000000001", "999999", String(repeating: "9", count: 400)] {
            for message in [conflictMessage(x: coordinate), conflictMessage(y: coordinate)] {
                XCTAssertNil(MapNodeConflictLocation.parse(MapAPIError(code: "DuplicateLogicalNodeValue", message: message)), coordinate)
            }
        }
    }

    func testConflictLocationUsesOnlyTheFinalSuffixAndPreservesTheErrorMessage() {
        let prefix = "值内含 https://example.invalid/ “" + conflictMessage(x: "1.5", y: "2.5") + "”"
        let message = prefix + conflictMessage(x: "200.5", y: "300.5")
        let error = MapAPIError(code: "DuplicateLogicalNodeValue", message: message)
        XCTAssertEqual(MapNodeConflictLocation.parse(error), MapNodePreviewLocation(code: "ABCDEFGHIJ", x: 200.5, y: 300.5))
        XCTAssertEqual(error.message, message)
        XCTAssertEqual(error.localizedDescription, message)
    }

    private func conflictMessage(x: String = "100.5", y: String = "200.5") -> String {
        "已被 LN ABCDEFGHIJ（中心坐标 X=\(x), Y=\(y)）使用，请使用不同的值。"
    }
}

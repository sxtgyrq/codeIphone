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
}

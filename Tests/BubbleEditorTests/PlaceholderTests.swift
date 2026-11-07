// Owner: QA. Replaced by the contract, EditPlan, export and server tests (docs/editor-architecture.md §8).
import BubbleEditor
import Testing

@Test func editorTargetBuilds() { #expect(BubbleEditor.defaultPort == 47621) }

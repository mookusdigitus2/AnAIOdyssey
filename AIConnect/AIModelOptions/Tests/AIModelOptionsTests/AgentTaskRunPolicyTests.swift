// SPDX-License-Identifier: MIT
import XCTest
@testable import AIModelOptions

final class AgentTaskRunPolicyTests: XCTestCase {
    func testTaskToolAllowListExcludesEmailAndCalendar() {
        XCTAssertTrue(
            AgentTaskRunPolicy.assertNoEmailOrCalendar(in: AgentTaskRunPolicy.allowedToolNames)
        )
        for name in AgentTaskRunPolicy.deniedToolNames {
            XCTAssertTrue(AgentTaskRunPolicy.isDenied(name), name)
            XCTAssertFalse(AgentTaskRunPolicy.isAllowed(name), name)
        }
        XCTAssertTrue(AgentTaskRunPolicy.containsEmailOrCalendar("list_emails"))
        XCTAssertTrue(AgentTaskRunPolicy.containsEmailOrCalendar("create_calendar_event"))
        XCTAssertFalse(AgentTaskRunPolicy.containsEmailOrCalendar("write_document"))
        XCTAssertTrue(AgentTaskRunPolicy.allowedToolNames.contains("write_document"))
        XCTAssertTrue(AgentTaskRunPolicy.allowedToolNames.contains("run_research"))
        XCTAssertTrue(AgentTaskRunPolicy.allowedToolNames.contains("update_document"))
        XCTAssertTrue(AgentTaskRunPolicy.allowedToolNames.contains("append_document"))
        XCTAssertFalse(AgentTaskRunPolicy.allowedToolNames.contains("create_document"))
        XCTAssertFalse(AgentTaskRunPolicy.allowedToolNames.contains("create_research"))
        XCTAssertFalse(AgentTaskRunPolicy.allowedToolNames.contains("update_research"))
    }

    func testResearchTasksRouteToResearchFeature() {
        XCTAssertTrue(
            AgentTaskRunPolicy.shouldUseResearchFeature(
                "Research visa requirements for Iceland and add them to the Trip Plan"
            )
        )
        XCTAssertEqual(
            AgentTaskRunPolicy.preferredTool(
                forAssignment: "Look up packing weather for Reykjavik"
            ),
            "run_research"
        )
        XCTAssertFalse(
            AgentTaskRunPolicy.shouldUseResearchFeature("Edit the Trip Plan document with Saturday times")
        )
        XCTAssertFalse(
            AgentTaskRunPolicy.shouldUseResearchFeature("Create a Packing List document")
        )
        XCTAssertTrue(AgentTaskRunPolicy.isSelfAuthoredResearchWrite("create_research"))
        XCTAssertTrue(
            AgentTaskRunPolicy.shouldBlockSelfAuthoredResearch(
                assignment: "Research ferry schedules",
                toolName: "create_research"
            )
        )
        XCTAssertFalse(
            AgentTaskRunPolicy.shouldBlockSelfAuthoredResearch(
                assignment: "Edit the Trip Plan",
                toolName: "create_document"
            )
        )
        XCTAssertEqual(
            AgentTaskRunPolicy.researchQuery(fromToolInput: "topic: Iceland packing\nInclude layers."),
            "Iceland packing"
        )
        XCTAssertTrue(AgentTaskRunPolicy.shouldAbortResearchRun(pauseRequested: true, stopRequested: false))
        XCTAssertTrue(AgentTaskRunPolicy.shouldAbortResearchRun(pauseRequested: false, stopRequested: true))
        XCTAssertFalse(AgentTaskRunPolicy.shouldAbortResearchRun(pauseRequested: false, stopRequested: false))
    }

    func testDocumentTasksRouteToDocumentsFeature() {
        XCTAssertTrue(
            AgentTaskRunPolicy.shouldUseDocumentsFeature("Create a Packing List document")
        )
        XCTAssertTrue(
            AgentTaskRunPolicy.shouldUseDocumentsFeature("Write a trip plan from the Iceland research")
        )
        XCTAssertTrue(
            AgentTaskRunPolicy.shouldUseDocumentsFeature("Draft a packing list")
        )
        XCTAssertFalse(
            AgentTaskRunPolicy.shouldUseDocumentsFeature("Edit the Trip Plan document with Saturday times")
        )
        XCTAssertFalse(
            AgentTaskRunPolicy.shouldUseDocumentsFeature("Research visa requirements for Iceland")
        )
        XCTAssertEqual(
            AgentTaskRunPolicy.preferredTool(forAssignment: "Create a Packing List document"),
            "write_document"
        )
        XCTAssertEqual(
            AgentTaskRunPolicy.preferredTools(
                forAssignment: "Research visa requirements for Iceland and write a Trip Plan document"
            ),
            ["run_research", "write_document"]
        )
        XCTAssertTrue(AgentTaskRunPolicy.isSelfAuthoredDocumentWrite("create_document"))
        XCTAssertTrue(
            AgentTaskRunPolicy.shouldBlockSelfAuthoredDocumentWrite(
                assignment: "Write a packing list document",
                toolName: "create_document"
            )
        )
        XCTAssertFalse(
            AgentTaskRunPolicy.shouldBlockSelfAuthoredDocumentWrite(
                assignment: "Edit the Trip Plan",
                toolName: "update_document"
            )
        )
        XCTAssertTrue(AgentTaskRunPolicy.shouldAbortDocumentWrite(pauseRequested: true, stopRequested: false))
        XCTAssertTrue(AgentTaskRunPolicy.shouldAbortDocumentWrite(pauseRequested: false, stopRequested: true))
        XCTAssertFalse(AgentTaskRunPolicy.shouldAbortDocumentWrite(pauseRequested: false, stopRequested: false))

        let parsed = AgentTaskRunPolicy.parseDocumentWriteInput(
            "title: Packing List\ncontext: Use the Iceland research.\nWrite a 7-day list."
        )
        XCTAssertEqual(parsed.title, "Packing List")
        XCTAssertEqual(parsed.brief, "Write a 7-day list.")
        XCTAssertEqual(parsed.context, "Use the Iceland research.")
        XCTAssertNil(parsed.documentID)

        let untitled = AgentTaskRunPolicy.parseDocumentWriteInput("Packing List\nLayers, rain shell, boots.")
        XCTAssertEqual(untitled.title, "Packing List")
        XCTAssertEqual(untitled.brief, "Layers, rain shell, boots.")

        XCTAssertEqual(
            AgentTaskRunPolicy.documentTitle(
                requested: nil,
                body: "# Trip Plan\n\nDay 1: Arrive",
                brief: "Write a trip plan"
            ),
            "Trip Plan"
        )
    }

    func testPauseContinueStopStateMachine() {
        XCTAssertEqual(
            AgentTaskRunPolicy.apply(.pause, to: .running),
            .paused
        )
        XCTAssertEqual(
            AgentTaskRunPolicy.apply(.continueRun, to: .paused),
            .running
        )
        XCTAssertEqual(
            AgentTaskRunPolicy.apply(.stop, to: .running),
            .stopped
        )
        XCTAssertEqual(
            AgentTaskRunPolicy.apply(.stop, to: .paused),
            .stopped
        )
        XCTAssertNil(AgentTaskRunPolicy.apply(.pause, to: .done))
        XCTAssertNil(AgentTaskRunPolicy.apply(.continueRun, to: .stopped))
        XCTAssertNil(AgentTaskRunPolicy.apply(.stop, to: .done))
        XCTAssertTrue(AgentTaskRunPolicy.canPauseOrContinue(.running))
        XCTAssertTrue(AgentTaskRunPolicy.canStop(.paused))
        XCTAssertFalse(AgentTaskRunPolicy.canStop(.done))
    }

    func testMigratesLegacyStatusesAndPausesRunningOnLaunch() {
        XCTAssertEqual(AgentTaskRunStatus.migrateStored("pending"), .paused)
        XCTAssertEqual(AgentTaskRunStatus.migrateStored("claimed"), .running)
        XCTAssertEqual(AgentTaskRunStatus.migrateStored("in_progress"), .running)
        XCTAssertEqual(AgentTaskRunStatus.migrateStored("handoff_human"), .paused)
        XCTAssertEqual(AgentTaskRunStatus.migrateStored("handoff_ai"), .paused)
        XCTAssertEqual(AgentTaskRunStatus.migrateStored("completed"), .done)
        XCTAssertEqual(AgentTaskRunStatus.migrateStored("failed"), .error)
        XCTAssertEqual(AgentTaskRunStatus.migrateStored("done"), .done)
        XCTAssertEqual(
            AgentTaskRunStatus.statusAfterLaunchRecovery(.running),
            .paused
        )
        XCTAssertEqual(
            AgentTaskRunStatus.statusAfterLaunchRecovery(.done),
            .done
        )
    }

    func testStatusLineAndBoundaryCopy() {
        XCTAssertEqual(
            AgentTaskRunPolicy.statusLine(status: .running, currentAction: "updating Trip Plan"),
            "Running: updating Trip Plan"
        )
        XCTAssertEqual(AgentTaskRunPolicy.statusLine(status: .paused), "Paused")
        XCTAssertEqual(AgentTaskRunPolicy.statusLine(status: .stopped), "Stopped")
        XCTAssertEqual(AgentTaskRunPolicy.statusLine(status: .done), "Done")
        XCTAssertEqual(
            AgentTaskRunPolicy.statusLine(status: .error, errorMessage: "The Internet connection appears to be offline."),
            "Error: The Internet connection appears to be offline."
        )
        XCTAssertEqual(
            AgentTaskRunPolicy.boundarySentence,
            "Tasks can read and edit your documents and research. They can't see your email or calendar."
        )
    }

    func testChangeLogRoundTripAndLabels() {
        let created = AgentTaskChangeEntry(
            action: "created",
            kind: "document",
            itemID: "doc-1",
            title: "Packing List"
        )
        XCTAssertEqual(created.label, "Created Packing List")
        XCTAssertEqual(
            AgentTaskRunPolicy.changeLogLabel(action: "edited", title: "Trip Plan"),
            "Edited Trip Plan"
        )
        XCTAssertEqual(
            AgentTaskRunPolicy.changeLogLabel(action: "researched", title: "Iceland packing"),
            "Researched Iceland packing"
        )
        let json = AgentTaskRunPolicy.encodeChangeLog([created])
        let decoded = AgentTaskRunPolicy.decodeChangeLog(json)
        XCTAssertEqual(decoded, [created])

        let parsed = AgentTaskRunPolicy.changeFromTool(
            name: "create_document",
            result: "Created document 'Packing List' (id: abc-123) at /."
        )
        XCTAssertEqual(parsed?.action, "created")
        XCTAssertEqual(parsed?.kind, "document")
        XCTAssertEqual(parsed?.title, "Packing List")
        XCTAssertEqual(parsed?.itemID, "abc-123")

        let researched = AgentTaskRunPolicy.changeFromTool(
            name: "run_research",
            result: "Researched 'Iceland packing' (id: res-9)."
        )
        XCTAssertEqual(researched?.action, "researched")
        XCTAssertEqual(researched?.kind, "research")
        XCTAssertEqual(researched?.title, "Iceland packing")
        XCTAssertEqual(researched?.itemID, "res-9")
        XCTAssertEqual(researched?.label, "Researched Iceland packing")

        let written = AgentTaskRunPolicy.changeFromTool(
            name: "write_document",
            result: "Created document 'Packing List' (id: doc-7)."
        )
        XCTAssertEqual(written?.action, "created")
        XCTAssertEqual(written?.kind, "document")
        XCTAssertEqual(written?.title, "Packing List")
        XCTAssertEqual(written?.itemID, "doc-7")
        XCTAssertEqual(written?.label, "Created Packing List")

        let rewritten = AgentTaskRunPolicy.changeFromTool(
            name: "write_document",
            result: "Edited document 'Trip Plan' (id: doc-8)."
        )
        XCTAssertEqual(rewritten?.action, "edited")
        XCTAssertEqual(rewritten?.label, "Edited Trip Plan")
    }

    func testCurrentActionIncludesItemName() {
        XCTAssertEqual(
            AgentTaskRunPolicy.currentAction(action: "edited", title: "Trip Plan"),
            "updating Trip Plan"
        )
        XCTAssertEqual(
            AgentTaskRunPolicy.statusLine(
                status: .running,
                currentAction: AgentTaskRunPolicy.currentAction(action: "edited", title: "Trip Plan")
            ),
            "Running: updating Trip Plan"
        )
    }
}

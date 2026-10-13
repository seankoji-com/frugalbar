import Testing
import QuotaBarCore
@testable import QuotaBarUI

@Suite("History failure copy")
struct HistoryFailurePresentationTests {
    @Test func openFailureDoesNotExposeFilesystemDetails() {
        let message = HistoryPresentation.failureMessage(for:
            HistoryDatabaseError.cannotOpen(path: "/Users/private-account/history.sqlite", code: 14))
        #expect(message.contains("Could not open"))
        #expect(!message.contains("private-account"))
        #expect(!message.contains("14"))
        #expect(message.contains("reopening FrugalBar"))
    }

    @Test func readFailureDoesNotExposeSQLOrDiagnostics() {
        let message = HistoryPresentation.failureMessage(for:
            HistoryDatabaseError.prepareFailed(sql: "SELECT private_data", message: "internal diagnostics"))
        #expect(message.contains("Could not read"))
        #expect(!message.contains("private_data"))
        #expect(!message.contains("internal diagnostics"))
    }
}

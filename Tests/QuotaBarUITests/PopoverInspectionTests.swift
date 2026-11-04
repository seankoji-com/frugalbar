import Foundation
import Testing
@testable import QuotaBarUI
import QuotaBarCore

/// Escape in the popover closes an open inspector and leaves the popover up;
/// only Escape on the list closes the popover. The app delegate keys that
/// choice off `dismiss()`'s answer, so the answer is the contract.
@MainActor
@Suite("Popover inspection")
struct PopoverInspectionTests {

    @Test("dismiss closes an open inspector and reports it")
    func dismissClosesAnOpenInspector() {
        let inspection = PopoverInspection()
        inspection.snapshot = QuotaSnapshot(
            id: "claude", vendorId: .claude, displayName: "Claude",
            category: .aiSubscriptions, metric: .percentage(usedFraction: 0.4, displayDetails: nil),
            status: .measured(.none), resetsAt: nil,
            lastUpdated: Date(timeIntervalSince1970: 0), auxiliaryInfo: nil,
            row1: nil, row2: nil
        )
        #expect(inspection.dismiss())
        #expect(inspection.snapshot == nil)
    }

    @Test("with no inspector open, dismiss reports nothing to close")
    func dismissWithNothingOpen() {
        #expect(!PopoverInspection().dismiss())
    }
}

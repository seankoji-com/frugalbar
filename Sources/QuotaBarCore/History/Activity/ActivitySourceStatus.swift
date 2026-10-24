import Foundation

/// What one adapter pass observed beyond the records themselves.
///
/// Counts are per source and per pass. `scannedInputs == 0` with no read
/// failure means every input was unchanged and skipped, so previously
/// persisted diagnostics remain current: a clean skip must not erase the
/// malformed records already found in that file.
public struct ActivityPassDiagnostics: Sendable, Equatable {
    public let scannedInputs: Int
    public let skippedInputs: Int
    public let malformedRecords: Int
    public let inconsistentRecords: Int
    public let incompleteRecords: Int
    public let recordsObserved: Int

    public init(
        scannedInputs: Int = 0,
        skippedInputs: Int = 0,
        malformedRecords: Int = 0,
        inconsistentRecords: Int = 0,
        incompleteRecords: Int = 0,
        recordsObserved: Int = 0
    ) {
        self.scannedInputs = scannedInputs
        self.skippedInputs = skippedInputs
        self.malformedRecords = malformedRecords
        self.inconsistentRecords = inconsistentRecords
        self.incompleteRecords = incompleteRecords
        self.recordsObserved = recordsObserved
    }

    public static let empty = ActivityPassDiagnostics()
}

/// The persisted, per-source account of the last scan and what it could not
/// represent. It is written by the engine, never synthesised by the UI.
public struct ActivitySourceStatus: Sendable, Equatable, Identifiable {
    public var id: String { source }
    public let source: String
    /// When this source was last attempted.
    public let lastScanAt: Date?
    /// When every input this source found was read. Malformed records do not
    /// make a scan unsuccessful; an input that could not be read does.
    public let lastSuccessfulScanAt: Date?
    /// Inputs that exist but could not be read on the last attempt.
    public let readFailures: Int
    /// Records that could not be parsed as the source's event shape.
    public let malformedRecords: Int
    /// Records that contradicted their own cumulative counter or duplicate
    /// identity. They are retained as observations but never reconciled into
    /// a fabricated difference.
    public let inconsistentRecords: Int
    /// Records whose token breakdown was partial or missing a total. Their
    /// unknown figures are not zero.
    public let incompleteRecords: Int
    /// Records the last scanned pass handed to the ledger, including those
    /// whose totals stayed unknown.
    public let recordsObserved: Int
    /// The last attempt read every input it found.
    public let lastPassComplete: Bool

    public init(
        source: String,
        lastScanAt: Date? = nil,
        lastSuccessfulScanAt: Date? = nil,
        readFailures: Int = 0,
        malformedRecords: Int = 0,
        inconsistentRecords: Int = 0,
        incompleteRecords: Int = 0,
        recordsObserved: Int = 0,
        lastPassComplete: Bool = false
    ) {
        self.source = source
        self.lastScanAt = lastScanAt
        self.lastSuccessfulScanAt = lastSuccessfulScanAt
        self.readFailures = readFailures
        self.malformedRecords = malformedRecords
        self.inconsistentRecords = inconsistentRecords
        self.incompleteRecords = incompleteRecords
        self.recordsObserved = recordsObserved
        self.lastPassComplete = lastPassComplete
    }
}

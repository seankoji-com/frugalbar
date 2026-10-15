# Sync publishing (Mac side)

`Sources/QuotaBarCore/Sync/` signs in to Google, then uploads the document
[`SnapshotExporter`](sync-export.md) builds to `snapshot.json` in Drive's app-data folder. The
phone reads it there. Settings → Phone & Watch (`QuotaBarUI/Settings/SyncSettingsPane.swift`)
drives it through `SyncController`.

## Opt-in and client values

- The Desktop OAuth client is never committed. `release.yml` stamps it from the Actions secrets
  `FRUGALBAR_GOOGLE_SYNC_CLIENT_ID` and `FRUGALBAR_GOOGLE_SYNC_CLIENT_SECRET` ("Stamp sync client"),
  after the tests and before the build. A source build reads the same two names from its
  environment.
- With neither, `SyncClientConfiguration.current` is nil: there is no `SyncController`, the pane is
  not listed, and nothing contacts Google. With a client, sync starts `off`. Sign-in is only ever
  needed for sync.

## Sign-in

`SyncSignInFlow`: random `state`, S256 PKCE, scope `drive.appdata`, `access_type=offline`,
`prompt=consent`. The redirect lands on `SyncLoopbackListener` at `127.0.0.1:<kernel-chosen port>`,
which closes on success, on cancel, or after 5 minutes ("Sign-in timed out" with Try Again). The
screen tells the owner to open the link in a browser on this Mac (spike decision 9).

Sign-in succeeds only once the refresh token is in the Keychain and reads back. `KeychainSyncSecretStore`
(service `com.quotabar.sync`) writes non-synchronizable generic passwords with
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. A bare binary's legacy keychain ignores that
attribute (spike decision 6). The same store holds the session's `publisherId`.

`about.get` gives the account's `permissionId` (the identity) and email (persisted for display).
"Sign in again" and "Sign in to finish cleanup" send `login_hint` and reject a different
`permissionId` before storing anything.

Refresh failures: 429, 5xx, network errors and timeouts back off (2, 4, 8, then 15 minutes). Any
other 4xx stops publishing and shows "Sign in again", with nothing scheduled. No code calls
Google's revoke endpoint.

## Publishing

`SyncPublisher` is tick-driven. The poll handler calls `SyncController.submit`, which returns at
once; `SyncController.start` runs the ticks in their own task.

| Rule | Value |
|---|---|
| Material change (D§2.2.D, `SyncMaterial`) | next 2-minute slot |
| Heartbeat, full document | when the last successful publish is 15 min old |
| Request timeout | 20 s, every Google request |
| Uncertain upload (timeout, cancel, lost connection, 5xx, a 2xx answer without a file id) | forced publish at the next slot, then a SHA-256 verification read; at most 3 forced per run, then only the heartbeat, even with a material change pending. A heartbeat that is itself uncertain moves the next one 15 min on |
| Foreign `publisherId` modified < 1 h ago by Drive's clock (its `modifiedTime` against the same response's `Date` header), or of unknown age | stop, "Another Mac (label) is syncing — Take over?" |
| Foreign id after this session published | stop, "Another Mac took over syncing" |

The last attempt time, the repair run and whether this session has published are persisted, so a
relaunch keeps the 2-minute floor and the 3-publish cap, and a former publisher still stops on a
takeover however old it is.

## Durable state fails closed

State lives in `~/Library/Application Support/FrugalBar/sync-state.json` (0600, one atomic write per
transition). A change that sync depends on takes effect only once it is on disk:

| Write | If it fails |
|---|---|
| Activation (active record with account) | sign-in reports it; sync stays off; the new publisherId and refresh token are deleted |
| Checkpoint before each attempt (floor, repair count, `uploadStartedAt`) | no Google request; retried after backoff |
| Outcome of an upload | `uploadStartedAt` stays on disk, so a relaunch treats the upload as uncertain: forced, verified, and a later foreign id is a takeover |
| Stop step 1 | nothing more publishes; step 1 is retried; a relaunch shows the session with Stop |
| Take over, Sign in again | no change; the prompt stays |
| A detected takeover, a terminal sign-in failure, a cleanup step | found again or retried; what stays on disk is the safe earlier record |

A missing state file means sync was never turned on. A file that exists but can't be read or
decoded is never treated as `off` and never written over: Settings says "Sync is paused", Start is
unavailable, and the file is read again every minute and on "Try Again".

`measuredAtTrusted` and `providersOmitted` count as material on top of the D§2.2.D list, so a
distrusted reading or a dropped provider reaches the phone before the heartbeat.

Every publish lists the folder first. That covers "re-list after an uncertain create" and deletes
duplicates. An export failure withholds the publish before any request, and Settings shows
`SnapshotExportState.settingsMessage`.

## Clock

- `macClockOffsetMs = Drive Date header − Mac clock`. Positive means the Mac is behind. The sample
  comes from the pre-upload `files.get` response, or from the listing when there is no file yet.
  No header means both fields are null.
- `NSSystemClockDidChangeNotification` (`SyncClockChangeObserver`), or two samples more than
  5 minutes apart, marks every retained reading `measuredAtTrusted: false`. The mark clears when
  that instance's `lastUpdated` changes, meaning it was measured again.

## Stop

The steps:

1. Persist `stopping` plus the cleanup record (publisherId, account, token item, +2/+10 min
   deadlines).
2. Cancel and await the in-flight upload.
3. Delete files that carry this session's id.
4. Re-list at +2 and +10 minutes.
5. Delete the token and publisherId, then write `stopped`.

Each step is persisted. A relaunch resumes at the first incomplete step. Nothing uploads or
repairs while `stopping`. If auth fails terminally during cleanup, the pane offers "Sign in to
finish cleanup" (same account, same publisherId, never publishes) and "Finish without deleting".
The second deletes the token, then writes `stopped` with a notice naming the account's email; until
that write lands, the pane stays on the two choices and Start stays unavailable. The notice is hidden while
this Mac publishes to that account again.

## Not covered here

- `SyncLinks.privacyPolicy` points at `docs/privacy.md`, which the privacy-policy gate
  (REQ-PRIVACY) still has to write and the owner approve.
- Keychain read-back after a restart for the Homebrew binary and a `swift run` build
  (REQ-MAC-OAUTH d), the live Stop cases (REQ-MAC-STOP f) and the Mac screenshots need a real
  account and are recorded by trace.

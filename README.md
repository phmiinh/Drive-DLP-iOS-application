# BitHub iOS

Native SwiftUI replacement for the local BitHub / Pydio Cells Android client that lives in the same workspace.

## Scope

This codebase is built from the local Android sources first:

- `cells-android-app/cells-client`
- `cells-android-app/sdk-java`

It preserves the local branding and OAuth client semantics found in the Android app:

- display name: `BitHub`
- OAuth client id: `cells-mobile`
- OAuth redirect scheme: `cellsauth://callback`

## Current implementation status

Implemented in this repository:

- app bootstrap and session restore foundation
- server inspection and Cells/P8 detection
- Cells OAuth login flow
- legacy P8 username/password login flow
- persisted accounts, server records, tokens and cached folder listings
- SwiftUI app shell with onboarding, accounts, browse, transfers and settings tabs
- workspace listing and folder browsing
- bookmark listing across the active account
- search inside the current folder scope
- create folder, rename, delete
- single-node move and copy with a remote destination picker
- upload staging from the iOS file importer into local app storage before queueing
- direct Cells upload and download execution through local S3-compatible signing logic
- direct legacy P8 XML login, browse, download and multipart upload execution
- preview and share for downloaded local files
- bookmark toggling and public-link create/load/remove actions for Cells and legacy P8
- offline root pinning, offline root browser, and recursive sync preparation that queues subtree downloads
- runtime logs and jobs screens inspired by the Android system section
- local cache housekeeping for browsing data, finished transfer entries, and downloaded files
- settings and cache cleanup
- transfer queue persistence, deduplication and limited concurrent execution

Known gaps in this iteration:

- legacy P8 captcha flows and advanced share edge cases are still incomplete
- transfer execution does not yet use background URLSession or resumable multipart flows
- offline sync still prepares and queues downloads; it does not yet reproduce the full Android diff engine and scheduled worker behavior
- full share management UI, background transfer parity, and rich document preview parity are still incomplete
- Xcode build was not executed in this Windows environment

## Project generation

This folder ships an `XcodeGen` spec instead of a pre-generated `.xcodeproj` because the current environment does not provide Xcode.

On macOS:

```sh
brew install xcodegen
cd pydio-ios
xcodegen generate
open BitHub.xcodeproj
```

## Structure

- `App/`
- `Core/`
- `Networking/`
- `Auth/`
- `Persistence/`
- `Services/`
- `Features/`
- `SharedUI/`
- `Resources/`
- `Tests/`
- `Docs/`

## Evidence baseline

- local Android app logic
- local Java SDK transport and API contracts
- App Store listing for `Pydio` on iOS for version and UX constraints

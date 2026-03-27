# A. What Was Inspected

- `cells-android-app/settings.gradle`
- `cells-android-app/build.gradle`
- `cells-android-app/cells-client/build.gradle`
- `cells-android-app/cells-client/src/main/AndroidManifest.xml`
- `cells-android-app/cells-client/src/main/java/com/pydio/android/cells`
- `cells-android-app/cells-client/src/main/java/com/pydio/android/legacy/v2`
- `cells-android-app/cells-client/schemas`
- `cells-android-app/cells-client/src/main/res`
- `cells-android-app/sdk-java/src/main/java/com/pydio/cells`
- App Store listing for `Pydio` on iOS

# B. Local Product Findings

- Local Android branding is customized to `BitHub`, not stock upstream naming.
- Core Android modules are split between `cells-client` and `sdk-java`.
- `cells-client` owns UI, Room DB, Android services, workers and transfer orchestration.
- `sdk-java` owns transport, OpenAPI contracts, OAuth token logic, Cells and P8 detection.

# C. Android To iOS Mapping

- `ViewModel` -> SwiftUI `ObservableObject`
- `Room / DAO` -> JSON backed persistence actors in this iteration
- `CredentialService / TokenStore` -> Keychain backed token store
- `SessionFactory / Transport` -> `PydioAPIClient` + `AuthSessionService`
- `ConnectionService` -> bootstrap plus per-session validation
- `TransferService` -> persisted transfer queue with direct Cells upload/download execution
- `OfflineService` / `OfflineSyncWorker` -> offline pinning plus recursive sync preparation service
- `JobService` / `LogDao` -> runtime repositories and system screens
- Compose navigation graphs -> SwiftUI `NavigationStack` and `TabView`

# D. Key Evidence

- OAuth flow generation and callback handling:
  - `cells-android-app/cells-client/src/main/java/com/pydio/android/cells/services/AuthService.kt`
  - `cells-android-app/cells-client/src/main/java/com/pydio/android/cells/ui/system/models/PreLaunchVM.kt`
- Session and account lifecycle:
  - `cells-android-app/cells-client/src/main/java/com/pydio/android/cells/services/AccountService.kt`
  - `cells-android-app/cells-client/src/main/java/com/pydio/android/cells/services/ConnectionService.kt`
- Server detection and transport:
  - `cells-android-app/sdk-java/src/main/java/com/pydio/cells/transport/ServerFactory.java`
  - `cells-android-app/sdk-java/src/main/java/com/pydio/cells/transport/CellsTransport.java`
  - `cells-android-app/sdk-java/src/main/java/com/pydio/cells/legacy/P8Transport.java`
- Browser and file actions:
  - `cells-android-app/sdk-java/src/main/java/com/pydio/cells/client/CellsClient.java`
- Transfers, offline, logs and jobs:
  - `cells-android-app/cells-client/src/main/java/com/pydio/android/cells/services/TransferService.kt`
  - `cells-android-app/cells-client/src/main/java/com/pydio/android/cells/services/S3TransferService.kt`
  - `cells-android-app/cells-client/src/main/java/com/pydio/android/cells/services/OfflineService.kt`
  - `cells-android-app/cells-client/src/main/java/com/pydio/android/cells/ui/system/screens/Logs.kt`
  - `cells-android-app/cells-client/src/main/java/com/pydio/android/cells/ui/system/screens/Jobs.kt`
- DB schemas:
  - `cells-android-app/cells-client/schemas`

# E. iOS UX Baseline Notes

- App Store listing indicates the current iOS release requires iOS 16.6+ and is designed for iPad.
- Release notes mention OAuth login, uploads, previews, paging and iPad fixes.
- This iteration therefore targets:
  - iOS 16.6 minimum
  - SwiftUI first
  - iPhone and iPad
  - navigation and data density closer to native iOS than to the Android drawer model

# F. Known Gaps In This Iteration

- Legacy P8 login, restore, browse, move/copy, bookmarks, public-link actions and transfer are now implemented, but captcha and advanced legacy share edge cases are still open.
- Transfer execution is not yet moved to background URLSession or resumable multipart flows.
- Offline sync still prepares and queues downloads rather than reproducing the full Android diff engine and worker cadence.
- Share management depth, background transfer parity, and richer preview affordances are not complete yet.

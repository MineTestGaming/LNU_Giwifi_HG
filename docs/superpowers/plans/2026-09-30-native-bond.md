# Native Desktop Bond Implementation Plan

**Goal:** Checkbox selection and authenticated-only native bonds on Windows, macOS and Linux.

**Architecture:** A controller owns fresh authentication evidence and lifecycle recovery; a separate native backend generates narrowly scoped scripts and invokes OS elevation. The UI displays per-interface state and retains the existing authentication selector.

**Tech Stack:** Dart IO, Flutter, PowerShell NetLbfo, networksetup, NetworkManager nmcli.

**Spec:** ../specs/2026-09-30-native-bond-design.md

## Global Constraints

- Never execute network mutations during development tests.
- No proxy fallback; unsupported configurations get explicit reasons.
- Member authentication is verified immediately before native mutation.
- Native creation changes the interface identity; verify the logical interface and roll back on failure.
- Persist recovery information before mutation; retain it until successful cleanup.
- Tests use injected authentication and native backends.

## Tasks

- [x] Add behavioral tests for `BondController.start`, `stop`, `verify` and authentication freshness. Assert that offline or unknown members never reach native creation, that post-create failure restores connections, and that failed restore keeps a retryable session.
- [x] Implement `lib/services/bond_controller.dart`: member checks, platform eligibility, serialized lifecycle, recovery store, bind-interface verification.
- [x] Implement `lib/services/native_bond_backend.dart`: read-only OS probes, DHCP/subnet/member validation, safely quoted platform scripts, time-limited probes and OS network operations, random ownership names, privileged execution and cleanup.
- [x] Add `lib/widgets/bond_card.dart`: per-interface check action and Checkbox, select only freshly online eligible cards; start/stop/check actions and system change confirmation.
- [x] Integrate HomePage authentication configuration and adapter refresh; persist recovery independently of credentials and regular settings. Member selection and authentication evidence are not restored as trusted online state.
- [x] Generate Linux runner and adapt macOS entitlements; document prerequisites, identity changes, recovery and platform validation limits.
- [x] Run `flutter test`, `flutter analyze`, Windows build and safe PowerShell parsing; inspect diff and mark tasks complete with evidence.

## Verification

- `flutter test --reporter compact`: 49 passed, including Checkbox selection, authentication expiry, recovery and non-executing PowerShell/shell syntax checks.
- `flutter analyze`: no issues.
- `flutter build windows --release`: succeeded, `build/windows/x64/runner/Release/giwifi_ua_switcher.exe`.
- `git diff --check`: passed.
- No live network mutations were run. macOS and Linux native builds and real authenticated multi-NIC bonding remain platform acceptance checks; these cannot be verified on this Windows development host.

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Flutter rewrite of the Kotlin/Compose TL temperature-humidity logger app
(`D:\AndroidStudioProjects\TL`). Android is the verified target; iOS builds and
real-device validation are still pending. The UI, protocol behavior, and export
layout are meant to match the original Compose app 1:1 — this is a port, not a
redesign.

Comments, docs, and most user-facing strings are Chinese; keep new text
consistent with the surrounding code and the original app.

## Environment and commands

Run from Git Bash on this machine:

```bash
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
export ANDROID_HOME="D:\Android_SDK"

/d/Flutter/flutter/bin/flutter pub get
/d/Flutter/flutter/bin/flutter analyze
/d/Flutter/flutter/bin/flutter test
/d/Flutter/flutter/bin/flutter test test/core/protocol/commands_test.dart   # single file
/d/Flutter/flutter/bin/flutter test --plain-name "verifyPassword prefixes 0x24 0x00 and encodes ASCII"
/d/Flutter/flutter/bin/flutter build apk --debug
/d/Flutter/flutter/bin/flutter devices
/d/Flutter/flutter/bin/flutter run -d <device-id>
```

Flutter 3.47.9 / Dart 3.13.7, JDK 21 at `D:\Flutter\jdk-21.0.13+9`, Android SDK
at `D:\Android_SDK`. The Gradle wrapper points at a Tencent mirror because
`services.gradle.org` is unreachable here. Building/running iOS requires a Mac.

`analysis_options.yaml` uses `flutter_lints` and excludes `build/`, `android/`,
and `ios/` from analysis.

## Architecture

Dependency direction: `ui → state → ble → BleTransport`; `core/` is pure Dart
with no Flutter dependency.

```
lib/main.dart                     ProviderScope → MaterialApp → ScannerScreen
lib/state/app_controller.dart     single Notifier<AppState>: all app coordination
lib/state/app_state.dart          AppState + per-device DeviceState
lib/ble/ble_transport.dart        platform-neutral BLE interface (opaque deviceId)
lib/ble/universal_ble_transport.dart  universal_ble implementation
lib/ble/device_connection.dart    per-device GATT/command/notification state machine
lib/core/protocol/                pure Dart protocol codecs and command builders
lib/core/chart/                   pure Dart chart math/layout (no drawing)
lib/export/                       CSV + two-phase PDF report rendering
lib/ui/                           ScannerScreen, device cards, overlay dialogs
```

### State and UI flow

- There is no router. `ScannerScreen` renders exactly one screen and overlays
  dialogs in a `Stack` according to `AppState` flags (`showPasswordDialog`,
  `showParamDialog`, `showRecordDialog`, `showLogisticsDialog`,
  `showStartConfirmDialog`). `activeDeviceId` says which device the dialog
  operates on.
- `AppController` holds the connection pool (`Map<String, DeviceConnection>`),
  scan timer, connect timeout, parameter-write queue, record-read chunking, and
  multi-step flows (e.g. clear-records → password → clear; start → optional
  logistics → start).
- `AppState.devices` is keyed by the opaque `deviceId`; `deviceOrder` is RSSI
  sorted. Every BLE callback is bound to its own `DeviceConnection` instance —
  do not reintroduce a global "dialog device address" in BLE callbacks, or
  multiple devices will cross-wire.
- `ProbeScreen` / `ProbeController` is a manual on-device BLE diagnostic console
  (scan fields, MTU, services, records, logistics, logs). It is not reachable
  from `main.dart`; temporarily set it as `home` when diagnosing hardware.

### BLE layer

- `BleTransport` (`scan`, connect/discover/read/write/notify/MTU) is the only
  platform boundary. Production uses `universal_ble`; tests use
  `test/ble/fake_ble_transport.dart` (`fullDevice()` builds the TL service
  table, notifications are emitted with `emit(...)`).
- `deviceId` is opaque: Android MAC or iOS CBPeripheral UUID. Never parse it or
  assume it is a MAC.
- `universal_ble` exposes manufacturer/service data as parsed maps, but all core
  parsers expect raw AD bytes. `ScanRecordBuilder` (`core/protocol/sensor_data.dart`)
  reconstructs AD structures; platform differences stay in
  `universal_ble_transport.dart`.
- `DeviceConnection` owns the GATT service cache, MTU request, notification
  registration, command writes, and record accumulation. It retries connect once
  because Android often returns status 133 immediately after a disconnect.
- Stop scanning before connecting (especially Android); scanning while
  connecting can hang in `connecting`.
- `universal_ble` was chosen over `flutter_blue_plus` partly because the latter
  requires a commercial license from 2.x onward.

### Export

- `CsvExporter.build` and `PdfReportBuilder.build` are pure builders; the
  controller supplies records, thresholds, logistics, time filters, and fonts.
- PDF rendering is two-phase: layout computes page coordinates first (so
  pagination and atomic chart blocks are decided up front), then `Document.save`
  replays draw closures. `PdfChartRenderer` only draws from the chart-core
  model/layout; it makes no layout decisions.
- PDFs need the bundled CJK font `assets/fonts/NotoSansSC-VF.ttf` (the `pdf`
  package's default Helvetica has no CJK glyphs).
- `ExportService` writes Android files through `FileSaver.saveToDownloads`
  (MediaStore). `saveFile` writes to an app-private directory, which was the
  wrong behavior. iOS writes a temp file and opens the system share sheet.

## Protocol invariants (do not regress)

1. **Authenticate with FFC3 before any FFD0 control command** (`0x02`, `0x03`,
   `0x05`, `0x08`, `0x0A`, …). That is `0x24 0x00` + ASCII password; the app's
   connection flow must keep the password dialog.
2. FFD0 command writes go to FFD1; responses arrive as FFD2 notifications.
   Parameter ACKs arrive on FFC4 as ASCII like `24@C3`, `24@A1`; match on the
   trailing suffix, and ignore stale ACKs from a different operation/device.
3. Two manufacturer-data segments exist: `0x4B4C` (TL sensor) and `0x004C`
   (iBeacon). `universal_ble`'s `companyId` is the little-endian interpretation
   of those bytes. Identify iBeacon by the subtype magic `value[2..3] == 02 15`,
   **not** by Company ID (Company ID is a user-editable field).
4. History records are 8 bytes: timestamp `uint32` LE, temperature `int16` LE
   divided by 100, humidity `uint8`, flags `uint8`. In streaming reads,
   `data_len == 0` is the batch boundary; a 500 ms idle timer is the fallback.
   Skip the first empty ACK of a stream. Do not stop reading at the first empty
   packet.
5. FFC5 logistics is a 508-byte v3 block (must stay ≤ 512 for a single GATT
   long read). The field table in `LogisticsInfo.fields` must match firmware
   `s_log_fields[]` item for item. Each of the 11 write packets has length
   exactly `slotSize + 1`, otherwise firmware returns GATT error `0x13`.
   Emptiness is `hasContent`, not `!= null` — blank device memory decodes to a
   non-null object with empty fields.
6. FFAx parameter writes are serialized: wait for the matching FFC4 ACK, 2500 ms
   timeout, 120 ms gap between operations. FFC2 device name is raw UTF-8 with no
   `0x24` prefix, at most 8 bytes; an empty name gets no ACK from firmware.
7. Store and compare alarm thresholds in ℃; convert only for display/export.
8. Chart X values are `double` epoch seconds. Downsampling must use LTTB, not
   even-stride or mean buckets, or short alarm spikes disappear from compliance
   reports. Chart block height constants live only in `ChartLayout`; layout and
   pagination tests lock their sum.
9. Do **not** add `neverForLocation` to `BLUETOOTH_SCAN` in the Android
   manifest. Some VIVO/Xiaomi/OPPO drivers stop sending scan requests under that
   flag, which drops the Scan Response and therefore the device name/service
   data.

## Tests

- Unit tests mirror `lib/` under `test/` and use `package:test` (via
  `flutter test`). There are currently no widget or integration tests.
- BLE behavior is tested against `FakeBleTransport`, including ACK handling,
  timeouts, record batching, and write logs. Prefer extending the fake over
  mocking `universal_ble`.
- PDF tests load the real `assets/fonts/NotoSansSC-VF.ttf` to exercise CJK
  shaping and pagination.
- Real-hardware BLE behavior cannot be covered by unit tests; use the app or
  `ProbeScreen` on an Android device for scan/connect/read verification.

## Reference docs

- `README.md` — environment, verified milestones, real-device findings.
- `docs/superpowers/specs/2026-11-03-flutter-refactor-design.md` — architecture,
  layering, protocol constraints, migration phases.
- The original Kotlin project `D:\AndroidStudioProjects\TL` and its `*.md`
  protocol documents remain the behavioral/authoritative reference. Do not copy
  protocol tables into this repo; they will diverge.

import 'dart:async';
import 'dart:typed_data';

import 'package:universal_ble/universal_ble.dart';

import '../core/protocol/sensor_data.dart';
import 'ble_transport.dart';

/// universal_ble 的生产实现。
///
/// 平台注意事项：
/// - `deviceId` 在 Android 是 MAC、iOS 是 CBPeripheral UUID，业务层不得解析。
/// - iOS 的 Scan Response 可能不可见，因此名称可能为空；能拿到的
///   manufacturer/service data 仍会正常上报。
/// - iOS 的 MTU 由系统管理，`requestMtu` 只返回当前值。
class UniversalBleTransport implements BleTransport {
  final StreamController<BleScanResult> _scanController =
      StreamController<BleScanResult>.broadcast();
  StreamSubscription<BleDevice>? _scanSub;
  bool _scanning = false;

  final Map<String, StreamSubscription<Uint8List>> _notifySubs = {};

  @override
  Stream<BleScanResult> scan({List<String> withServices = const []}) {
    if (!_scanning) {
      // 先订阅再开扫，避免漏掉首批广播。
      _scanSub ??= UniversalBle.scanStream.listen(
        (device) => _scanController.add(_toScanResult(device)),
        onError: (Object e) => _scanController.addError(e),
      );
      _scanning = true;
      unawaited(
        UniversalBle.startScan(
          scanFilter: ScanFilter(withServices: withServices),
          skipDuplicates: false,
        ).catchError((Object e) {
          _scanController.addError(e);
        }),
      );
    }
    return _scanController.stream;
  }

  BleScanResult _toScanResult(BleDevice d) {
    final manufacturer = <int, Uint8List>{
      for (final m in d.manufacturerDataList) m.companyId: m.payload,
    };
    final name = (d.rawName?.trim().isNotEmpty ?? false)
        ? d.rawName
        : (d.name?.trim().isNotEmpty ?? false ? d.name : null);
    final raw = ScanRecordBuilder.build(
      manufacturerData: manufacturer,
      serviceData: d.serviceData,
      name: name,
    );
    return BleScanResult(
      deviceId: UniversalBle.canonicalDeviceId(d.deviceId),
      name: name,
      rssi: d.rssi ?? 0,
      manufacturerData: manufacturer,
      serviceData: d.serviceData,
      services: d.services,
      rawScanRecord: raw,
    );
  }

  @override
  Future<void> stopScan() async {
    if (!_scanning) return;
    _scanning = false;
    try {
      await UniversalBle.stopScan();
    } finally {
      await _scanSub?.cancel();
      _scanSub = null;
    }
  }

  @override
  Future<void> connect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 15),
  }) =>
      UniversalBle.connect(deviceId, timeout: timeout);

  @override
  Future<void> disconnect(String deviceId) =>
      UniversalBle.disconnect(deviceId);

  @override
  Future<List<BleServiceRef>> discoverServices(String deviceId) async {
    final services = await UniversalBle.discoverServices(deviceId);
    return services.map((s) {
      final chars = s.characteristics.map((c) {
        final p = c.properties;
        return BleCharacteristicRef(
          uuid: c.uuid,
          canRead: p.contains(CharacteristicProperty.read),
          canWrite: p.contains(CharacteristicProperty.write),
          canWriteWithoutResponse:
              p.contains(CharacteristicProperty.writeWithoutResponse),
          canNotify: p.contains(CharacteristicProperty.notify) ||
              p.contains(CharacteristicProperty.indicate),
        );
      }).toList(growable: false);
      return BleServiceRef(uuid: s.uuid, characteristics: chars);
    }).toList(growable: false);
  }

  @override
  Future<Uint8List> readCharacteristic(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  ) =>
      UniversalBle.read(deviceId, serviceUuid, characteristicUuid);

  @override
  Future<void> writeCharacteristic(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
    Uint8List value, {
    required bool withResponse,
  }) =>
      UniversalBle.write(
        deviceId,
        serviceUuid,
        characteristicUuid,
        value,
        withoutResponse: !withResponse,
      );

  @override
  Future<void> setNotifiable(
    String deviceId,
    String serviceUuid,
    String characteristicUuid, {
    required bool enabled,
    required void Function(Uint8List value) onValue,
  }) async {
    final key = '${deviceId.toLowerCase()}/$characteristicUuid';
    final existing = _notifySubs.remove(key);
    await existing?.cancel();

    if (!enabled) {
      await UniversalBle.unsubscribe(
        deviceId,
        serviceUuid,
        characteristicUuid,
      );
      return;
    }

    await UniversalBle.subscribeNotifications(
      deviceId,
      serviceUuid,
      characteristicUuid,
    );
    _notifySubs[key] =
        UniversalBle.characteristicValueStream(deviceId, characteristicUuid)
            .listen(onValue);
  }

  @override
  Future<int> requestMtu(String deviceId, int mtu) =>
      UniversalBle.requestMtu(deviceId, mtu);

  @override
  Stream<bool> connectionState(String deviceId) =>
      UniversalBle.connectionStream(deviceId);

  @override
  Future<bool> isBluetoothAvailable() async {
    final state = await UniversalBle.getBluetoothAvailabilityState();
    return state == AvailabilityState.poweredOn;
  }

  @override
  Future<bool> enableBluetooth() => UniversalBle.enableBluetooth();

  @override
  Future<bool> hasPermissions({bool withAndroidFineLocation = true}) =>
      UniversalBle.hasPermissions(
        withAndroidFineLocation: withAndroidFineLocation,
      );

  @override
  Future<void> requestPermissions({bool withAndroidFineLocation = true}) =>
      UniversalBle.requestPermissions(
        withAndroidFineLocation: withAndroidFineLocation,
      );

  @override
  Future<void> dispose() async {
    await stopScan();
    for (final sub in _notifySubs.values) {
      await sub.cancel();
    }
    _notifySubs.clear();
    await _scanController.close();
  }
}

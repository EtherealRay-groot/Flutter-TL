import 'dart:async';
import 'dart:typed_data';

import 'package:tl_app/ble/ble_transport.dart';

/// 可脚本化的 BLE 传输层，供连接/读写/通知逻辑单测使用。
class FakeBleTransport implements BleTransport {
  FakeBleTransport({this.mtu = 247});

  int mtu;
  bool bluetoothAvailable = true;
  final List<BleServiceRef> services = [];

  final List<String> writeLog = [];
  final Map<String, Uint8List> readResponses = {};
  final Map<String, void Function(Uint8List)> _notifyHandlers = {};

  final StreamController<bool> _connectionStates =
      StreamController<bool>.broadcast();

  bool get isConnected => _connected;
  bool _connected = false;
  String? connectedDeviceId;
  int connectCalls = 0;

  @override
  Stream<BleScanResult> scan({List<String> withServices = const []}) =>
      const Stream.empty();

  @override
  Future<void> stopScan() async {}

  @override
  Future<void> connect(String deviceId,
      {Duration timeout = const Duration(seconds: 15)}) async {
    connectCalls++;
    connectedDeviceId = deviceId;
    _connected = true;
    _connectionStates.add(true);
  }

  @override
  Future<void> disconnect(String deviceId) async {
    _connected = false;
    _connectionStates.add(false);
  }

  @override
  Future<List<BleServiceRef>> discoverServices(String deviceId) async =>
      services;

  @override
  Future<Uint8List> readCharacteristic(
      String deviceId, String serviceUuid, String characteristicUuid) async {
    final key = _key(serviceUuid, characteristicUuid);
    final v = readResponses[key];
    if (v == null) throw StateError('no fake read for $key');
    return v;
  }

  @override
  Future<void> writeCharacteristic(String deviceId, String serviceUuid,
      String characteristicUuid, Uint8List value,
      {required bool withResponse}) async {
    writeLog.add(
        '${_key(serviceUuid, characteristicUuid)}:${value.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}');
  }

  @override
  Future<void> setNotifiable(String deviceId, String serviceUuid,
      String characteristicUuid,
      {required bool enabled,
      required void Function(Uint8List value) onValue}) async {
    final key = _key(serviceUuid, characteristicUuid);
    if (enabled) {
      _notifyHandlers[key] = onValue;
    } else {
      _notifyHandlers.remove(key);
    }
  }

  /// 模拟设备发来通知。
  void emit(String serviceUuid, String characteristicUuid, List<int> value) {
    final handler = _notifyHandlers[_key(serviceUuid, characteristicUuid)];
    if (handler == null) {
      throw StateError('notification not enabled for $characteristicUuid');
    }
    handler(Uint8List.fromList(value));
  }

  @override
  Future<int> requestMtu(String deviceId, int mtu) async => this.mtu;

  @override
  Stream<bool> connectionState(String deviceId) => _connectionStates.stream;

  @override
  Future<bool> isBluetoothAvailable() async => bluetoothAvailable;

  bool permissionsGranted = true;

  @override
  Future<bool> enableBluetooth() async => true;

  @override
  Future<bool> hasPermissions({bool withAndroidFineLocation = true}) async =>
      permissionsGranted;

  @override
  Future<void> requestPermissions({bool withAndroidFineLocation = true}) async {
    if (!permissionsGranted) throw StateError('permissions denied');
  }

  @override
  Future<void> dispose() async {
    await _connectionStates.close();
  }

  String _key(String service, String characteristic) =>
      '${BleUuids.shorten(service)}/${BleUuids.shorten(characteristic)}';
}

BleServiceRef tlService(String uuid, List<String> chars,
    {bool writable = true}) {
  return BleServiceRef(
    uuid: uuid,
    characteristics: chars
        .map((c) => BleCharacteristicRef(
              uuid: c,
              canRead: true,
              canWrite: writable,
              canWriteWithoutResponse: false,
              canNotify: true,
            ))
        .toList(),
  );
}

FakeBleTransport fullDevice() {
  final t = FakeBleTransport();
  t.services.addAll([
    tlService(BleUuids.ffc0,
        [BleUuids.ffc2, BleUuids.ffc3, BleUuids.ffc4, BleUuids.ffc5]),
    tlService(BleUuids.ffa0, [
      BleUuids.ffa1,
      BleUuids.ffa2,
      BleUuids.ffa3,
      BleUuids.ffa5,
      BleUuids.ffa6,
      BleUuids.ffa7,
      BleUuids.ffa8,
    ]),
    tlService(BleUuids.ffd0,
        [BleUuids.ffd1, BleUuids.ffd2, BleUuids.ffd3, BleUuids.ffd4]),
  ]);
  return t;
}

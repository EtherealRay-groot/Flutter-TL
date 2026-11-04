import 'dart:typed_data';

/// 平台无关的 BLE 扫描结果。
///
/// [deviceId] 是**不透明标识**：Android 为 MAC，iOS 为 CBPeripheral UUID。
/// 业务层不得解析它，也不得假设它像 MAC。
class BleScanResult {
  const BleScanResult({
    required this.deviceId,
    required this.name,
    required this.rssi,
    required this.manufacturerData,
    required this.serviceData,
    required this.services,
    this.rawScanRecord,
  });

  final String deviceId;
  final String? name;
  final int rssi;

  /// companyId -> payload（含 company id 的原始字节，与 Android 一致）。
  final Map<int, Uint8List> manufacturerData;

  /// service UUID -> payload。
  final Map<String, Uint8List> serviceData;

  /// 广播中声明的 service UUID。
  final List<String> services;

  /// Android 上可拿到完整广播字节；iOS 上为 null。
  final Uint8List? rawScanRecord;
}

/// 特征标识（UUID 统一为 128 位小写字符串）。
class BleCharacteristicRef {
  const BleCharacteristicRef({
    required this.uuid,
    this.canRead = false,
    this.canWrite = false,
    this.canWriteWithoutResponse = false,
    this.canNotify = false,
  });

  final String uuid;
  final bool canRead;
  final bool canWrite;
  final bool canWriteWithoutResponse;
  final bool canNotify;
}

/// 服务/特征标识（UUID 统一为 128 位小写字符串）。
class BleServiceRef {
  const BleServiceRef({required this.uuid, required this.characteristics});

  final String uuid;
  final List<BleCharacteristicRef> characteristics;
}

/// BLE 平台抽象。
///
/// 生产实现见 universal_ble_transport.dart；测试实现可回放脚本报文，
/// 从而在不连真机的情况下覆盖连接管理、参数串行写、记录读取等逻辑。
abstract class BleTransport {
  /// 扫描。实现方应持续推送结果，直到 [stopScan] 或扫描超时。
  Stream<BleScanResult> scan({List<String> withServices = const []});

  Future<void> stopScan();

  Future<void> connect(String deviceId, {Duration timeout = const Duration(seconds: 15)});

  Future<void> disconnect(String deviceId);

  /// 返回该设备的所有服务与特征 UUID。
  Future<List<BleServiceRef>> discoverServices(String deviceId);

  Future<Uint8List> readCharacteristic(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
  );

  Future<void> writeCharacteristic(
    String deviceId,
    String serviceUuid,
    String characteristicUuid,
    Uint8List value, {
    required bool withResponse,
  });

  /// 开启/关闭通知。实现方在收到 notify 时调用 [onValue]。
  Future<void> setNotifiable(
    String deviceId,
    String serviceUuid,
    String characteristicUuid, {
    required bool enabled,
    required void Function(Uint8List value) onValue,
  });

  /// Android 上请求 MTU；iOS 上返回当前 MTU（不可协商）。
  Future<int> requestMtu(String deviceId, int mtu);

  /// 连接状态：true=已连接，false=已断开。
  Stream<bool> connectionState(String deviceId);

  Future<bool> isBluetoothAvailable();

  /// Android 上弹出系统对话框请求开启蓝牙；iOS 返回 false。
  Future<bool> enableBluetooth();

  Future<bool> hasPermissions({bool withAndroidFineLocation = true});

  Future<void> requestPermissions({bool withAndroidFineLocation = true});

  Future<void> dispose();
}

/// 常用 UUID（16 位短 UUID 展开为 128 位）。
class BleUuids {
  BleUuids._();

  static const String ffc0 = '0000ffc0-0000-1000-8000-00805f9b34fb';
  static const String ffa0 = '0000ffa0-0000-1000-8000-00805f9b34fb';
  static const String ffd0 = '0000ffd0-0000-1000-8000-00805f9b34fb';

  static const String ffc2 = '0000ffc2-0000-1000-8000-00805f9b34fb';
  static const String ffc3 = '0000ffc3-0000-1000-8000-00805f9b34fb';
  static const String ffc4 = '0000ffc4-0000-1000-8000-00805f9b34fb';
  static const String ffc5 = '0000ffc5-0000-1000-8000-00805f9b34fb';

  static const String ffa1 = '0000ffa1-0000-1000-8000-00805f9b34fb';
  static const String ffa2 = '0000ffa2-0000-1000-8000-00805f9b34fb';
  static const String ffa3 = '0000ffa3-0000-1000-8000-00805f9b34fb';
  static const String ffa5 = '0000ffa5-0000-1000-8000-00805f9b34fb';
  static const String ffa6 = '0000ffa6-0000-1000-8000-00805f9b34fb';
  static const String ffa7 = '0000ffa7-0000-1000-8000-00805f9b34fb';
  static const String ffa8 = '0000ffa8-0000-1000-8000-00805f9b34fb';

  static const String ffd1 = '0000ffd1-0000-1000-8000-00805f9b34fb';
  static const String ffd2 = '0000ffd2-0000-1000-8000-00805f9b34fb';
  static const String ffd3 = '0000ffd3-0000-1000-8000-00805f9b34fb';
  static const String ffd4 = '0000ffd4-0000-1000-8000-00805f9b34fb';

  /// 把 16 位短 UUID（如 "FFC0"）展开成 128 位小写。
  static String expand(String uuid) {
    final u = uuid.replaceAll('-', '').toLowerCase();
    if (u.length == 4) {
      return '0000$u-0000-1000-8000-00805f9b34fb';
    }
    if (u.length == 8) {
      return '$u-0000-1000-8000-00805f9b34fb';
    }
    return u.length == 32
        ? '${u.substring(0, 8)}-${u.substring(8, 12)}-${u.substring(12, 16)}-'
            '${u.substring(16, 20)}-${u.substring(20)}'
        : uuid;
  }

  /// 128 位 → 16 位短形式（若属于 Bluetooth Base UUID），否则原样返回。
  static String shorten(String uuid) {
    final u = uuid.replaceAll('-', '').toLowerCase();
    const baseSuffix = '00001000800000805f9b34fb';
    if (u.length == 32 && u.substring(8) == baseSuffix) {
      return u.substring(4, 8);
    }
    return uuid;
  }
}

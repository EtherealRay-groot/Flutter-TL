import '../core/protocol/ibeacon_codec.dart';
import '../core/protocol/logistics_info.dart';
import '../core/protocol/record_entry.dart';
import '../core/protocol/sensor_data.dart';

/// 温度单位（UI / 导出 / 报警判定用；图表层另有 TemperatureDisplay）。
enum TemperatureUnit {
  celsius('℃'),
  fahrenheit('℉');

  const TemperatureUnit(this.symbol);

  final String symbol;
}

/// 单台设备的状态：扫描字段 + 连接态 + 记录/物流缓存。
class DeviceState {
  const DeviceState({
    required this.deviceId,
    this.name,
    this.rssi = 0,
    this.timestamp = 0,
    this.sensor,
    this.ibeacon,
    this.hasTlData = false,
    this.connected = false,
    this.connecting = false,
    this.authenticated = false,
    this.recordCount = 0,
    this.deviceInterval = 0,
    this.firstTime = 0,
    this.isRecording = false,
    this.records = const [],
    this.readCurrent = 0,
    this.readTotal = 0,
    this.logistics,
    this.beaconConfig,
    this.cachedName,
  });

  final String deviceId;
  final String? name;
  final int rssi;
  final int timestamp;
  final SensorData? sensor;
  final IBeaconConfig? ibeacon;
  final bool hasTlData;

  final bool connected;
  final bool connecting;
  final bool authenticated;

  final int recordCount;
  final int deviceInterval;
  final int firstTime;
  final bool isRecording;
  final List<RecordEntry> records;
  final int readCurrent;
  final int readTotal;
  final LogisticsInfo? logistics;

  /// 最近一次已知/写入成功的 iBeacon 参数，供参数弹窗预填。
  final IBeaconConfig? beaconConfig;

  /// FFC2 名称写入后的 App 缓存（固件读不回来）。
  final String? cachedName;

  String get displayName =>
      cachedName ?? name ?? (deviceId.isNotEmpty ? deviceId : 'Unknown');

  DeviceState copyWith({
    String? name,
    int? rssi,
    int? timestamp,
    SensorData? sensor,
    IBeaconConfig? ibeacon,
    bool? hasTlData,
    bool? connected,
    bool? connecting,
    bool? authenticated,
    int? recordCount,
    int? deviceInterval,
    int? firstTime,
    bool? isRecording,
    List<RecordEntry>? records,
    int? readCurrent,
    int? readTotal,
    LogisticsInfo? logistics,
    bool clearLogistics = false,
    IBeaconConfig? beaconConfig,
    String? cachedName,
  }) =>
      DeviceState(
        deviceId: deviceId,
        name: name ?? this.name,
        rssi: rssi ?? this.rssi,
        timestamp: timestamp ?? this.timestamp,
        sensor: sensor ?? this.sensor,
        ibeacon: ibeacon ?? this.ibeacon,
        hasTlData: hasTlData ?? this.hasTlData,
        connected: connected ?? this.connected,
        connecting: connecting ?? this.connecting,
        authenticated: authenticated ?? this.authenticated,
        recordCount: recordCount ?? this.recordCount,
        deviceInterval: deviceInterval ?? this.deviceInterval,
        firstTime: firstTime ?? this.firstTime,
        isRecording: isRecording ?? this.isRecording,
        records: records ?? this.records,
        readCurrent: readCurrent ?? this.readCurrent,
        readTotal: readTotal ?? this.readTotal,
        logistics: clearLogistics ? null : (logistics ?? this.logistics),
        beaconConfig: beaconConfig ?? this.beaconConfig,
        cachedName: cachedName ?? this.cachedName,
      );
}

class AppState {
  const AppState({
    this.isScanning = false,
    this.bluetoothEnabled = false,
    this.bluetoothLeSupported = true,
    this.permissionGranted = false,
    this.errorMessage,
    this.devices = const {},
    this.deviceOrder = const [],
    this.selectedDeviceId,
    this.activeDeviceId,
    this.showPasswordDialog = false,
    this.passwordError,
    this.showStartConfirmDialog = false,
    this.showLogisticsDialog = false,
    this.showParamDialog = false,
    this.showRecordDialog = false,
    this.showTimeRangePicker = false,
    this.temperatureUnit = TemperatureUnit.celsius,
    this.alarmThresholdLow = '',
    this.alarmThresholdHigh = '',
    this.currentIntervalCode = 5,
    this.currentTxPower = 4,
    this.beaconName = '',
    this.beaconUuidHex = IBeaconCodec.defaultUuidHex,
    this.beaconMajor = IBeaconCodec.defaultMajor,
    this.beaconMinor = IBeaconCodec.defaultMinor,
    this.beaconCompany = IBeaconCodec.defaultCompany,
    this.beaconRssi1m = IBeaconCodec.defaultRssi1m,
    this.beaconParsed = false,
    this.paramBusy = false,
    this.paramFieldResults = const [],
    this.editResult,
    this.recordInterval = 0,
    this.hasSelectedInterval = false,
    this.recordResult,
    this.recordDeviceName = '',
    this.recordDeviceAddress = '',
    this.filterStartTime,
    this.filterEndTime,
    this.timeRangeMin = 0,
    this.timeRangeMax = 0,
    this.isExporting = false,
    this.exportProgress = 0,
    this.exportResult,
  });

  final bool isScanning;
  final bool bluetoothEnabled;
  final bool bluetoothLeSupported;
  final bool permissionGranted;
  final String? errorMessage;

  final Map<String, DeviceState> devices;

  /// 按 RSSI 排序后的 deviceId 列表。
  final List<String> deviceOrder;

  /// 列表里展开详情的设备。
  final String? selectedDeviceId;

  /// 当前弹窗操作的设备。
  final String? activeDeviceId;

  final bool showPasswordDialog;
  final String? passwordError;
  final bool showStartConfirmDialog;
  final bool showLogisticsDialog;
  final bool showParamDialog;
  final bool showRecordDialog;
  final bool showTimeRangePicker;

  final TemperatureUnit temperatureUnit;
  final String alarmThresholdLow;
  final String alarmThresholdHigh;

  final int currentIntervalCode;
  final int currentTxPower;
  final String beaconName;
  final String beaconUuidHex;
  final int beaconMajor;
  final int beaconMinor;
  final int beaconCompany;
  final int beaconRssi1m;
  final bool beaconParsed;
  final bool paramBusy;
  final List<BeaconFieldResult> paramFieldResults;
  final String? editResult;

  final int recordInterval;
  final bool hasSelectedInterval;
  final String? recordResult;
  final String recordDeviceName;
  final String recordDeviceAddress;
  final int? filterStartTime;
  final int? filterEndTime;
  final int timeRangeMin;
  final int timeRangeMax;

  final bool isExporting;
  final double exportProgress;
  final String? exportResult;

  DeviceState? get activeDevice =>
      activeDeviceId == null ? null : devices[activeDeviceId];

  AppState copyWith({
    bool? isScanning,
    bool? bluetoothEnabled,
    bool? bluetoothLeSupported,
    bool? permissionGranted,
    String? errorMessage,
    bool clearError = false,
    Map<String, DeviceState>? devices,
    List<String>? deviceOrder,
    String? selectedDeviceId,
    bool clearSelected = false,
    String? activeDeviceId,
    bool clearActive = false,
    bool? showPasswordDialog,
    String? passwordError,
    bool clearPasswordError = false,
    bool? showStartConfirmDialog,
    bool? showLogisticsDialog,
    bool? showParamDialog,
    bool? showRecordDialog,
    bool? showTimeRangePicker,
    TemperatureUnit? temperatureUnit,
    String? alarmThresholdLow,
    String? alarmThresholdHigh,
    int? currentIntervalCode,
    int? currentTxPower,
    String? beaconName,
    String? beaconUuidHex,
    int? beaconMajor,
    int? beaconMinor,
    int? beaconCompany,
    int? beaconRssi1m,
    bool? beaconParsed,
    bool? paramBusy,
    List<BeaconFieldResult>? paramFieldResults,
    String? editResult,
    bool clearEditResult = false,
    int? recordInterval,
    bool? hasSelectedInterval,
    String? recordResult,
    bool clearRecordResult = false,
    String? recordDeviceName,
    String? recordDeviceAddress,
    int? filterStartTime,
    int? filterEndTime,
    bool clearFilters = false,
    int? timeRangeMin,
    int? timeRangeMax,
    bool? isExporting,
    double? exportProgress,
    String? exportResult,
    bool clearExportResult = false,
  }) =>
      AppState(
        isScanning: isScanning ?? this.isScanning,
        bluetoothEnabled: bluetoothEnabled ?? this.bluetoothEnabled,
        bluetoothLeSupported:
            bluetoothLeSupported ?? this.bluetoothLeSupported,
        permissionGranted: permissionGranted ?? this.permissionGranted,
        errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
        devices: devices ?? this.devices,
        deviceOrder: deviceOrder ?? this.deviceOrder,
        selectedDeviceId: clearSelected
            ? null
            : (selectedDeviceId ?? this.selectedDeviceId),
        activeDeviceId:
            clearActive ? null : (activeDeviceId ?? this.activeDeviceId),
        showPasswordDialog: showPasswordDialog ?? this.showPasswordDialog,
        passwordError: clearPasswordError
            ? null
            : (passwordError ?? this.passwordError),
        showStartConfirmDialog:
            showStartConfirmDialog ?? this.showStartConfirmDialog,
        showLogisticsDialog: showLogisticsDialog ?? this.showLogisticsDialog,
        showParamDialog: showParamDialog ?? this.showParamDialog,
        showRecordDialog: showRecordDialog ?? this.showRecordDialog,
        showTimeRangePicker:
            showTimeRangePicker ?? this.showTimeRangePicker,
        temperatureUnit: temperatureUnit ?? this.temperatureUnit,
        alarmThresholdLow: alarmThresholdLow ?? this.alarmThresholdLow,
        alarmThresholdHigh: alarmThresholdHigh ?? this.alarmThresholdHigh,
        currentIntervalCode: currentIntervalCode ?? this.currentIntervalCode,
        currentTxPower: currentTxPower ?? this.currentTxPower,
        beaconName: beaconName ?? this.beaconName,
        beaconUuidHex: beaconUuidHex ?? this.beaconUuidHex,
        beaconMajor: beaconMajor ?? this.beaconMajor,
        beaconMinor: beaconMinor ?? this.beaconMinor,
        beaconCompany: beaconCompany ?? this.beaconCompany,
        beaconRssi1m: beaconRssi1m ?? this.beaconRssi1m,
        beaconParsed: beaconParsed ?? this.beaconParsed,
        paramBusy: paramBusy ?? this.paramBusy,
        paramFieldResults: paramFieldResults ?? this.paramFieldResults,
        editResult:
            clearEditResult ? null : (editResult ?? this.editResult),
        recordInterval: recordInterval ?? this.recordInterval,
        hasSelectedInterval: hasSelectedInterval ?? this.hasSelectedInterval,
        recordResult:
            clearRecordResult ? null : (recordResult ?? this.recordResult),
        recordDeviceName: recordDeviceName ?? this.recordDeviceName,
        recordDeviceAddress:
            recordDeviceAddress ?? this.recordDeviceAddress,
        filterStartTime:
            clearFilters ? null : (filterStartTime ?? this.filterStartTime),
        filterEndTime:
            clearFilters ? null : (filterEndTime ?? this.filterEndTime),
        timeRangeMin: timeRangeMin ?? this.timeRangeMin,
        timeRangeMax: timeRangeMax ?? this.timeRangeMax,
        isExporting: isExporting ?? this.isExporting,
        exportProgress: exportProgress ?? this.exportProgress,
        exportResult:
            clearExportResult ? null : (exportResult ?? this.exportResult),
      );
}

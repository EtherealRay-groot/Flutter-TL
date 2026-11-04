# TL 温湿度记录仪 App — Flutter 重构设计

日期：2026-11-03
源工程：`D:\AndroidStudioProjects\TL`（Kotlin + Jetpack Compose，单模块）
目标工程：`D:\Flutter\tl_app`（Flutter，Android + iOS）

## 1. 目标与非目标

**目标**

- 用 Flutter 重建现有 App，功能与原版完全对齐：
  扫描 / 多设备连接 / 密码验证 / iBeacon 参数读写 / 记录开关 /
  Flash 历史读取（全部、最近 10 条、按时间段）/ 清除记录 /
  物流信息（FFC5 v3）/ PDF 报告 / CSV 导出 / 图表。
- UI 1:1 复刻现有 Compose 界面（Material 3，同一套 UI 双端共用）。
- 纯逻辑（协议编解码、图表计算）用 Dart 重写并保留全部单元测试。
- 为 iOS 预留平台抽象，首版在 Android 真机验收；iOS 待有 Mac 后验证。

**非目标**

- 不重新设计 UI/UX。
- 不做后台扫描、后台连接、云同步。
- 不兼容旧版 APK 的本地数据（现有 App 无持久化业务数据）。

## 2. 关键技术决策

| 领域 | 选择 | 理由 |
|------|------|------|
| BLE | `universal_ble`（BSD-3） | 跨 Android/iOS，暴露 manufacturer data / service data / RSSI / name；无商业授权成本。`flutter_blue_plus` 2.x 起需商业许可。 |
| 状态管理 | `flutter_riverpod` 3.x | 不依赖 BuildContext、易测试；替代原 `StateFlow`。 |
| PDF | `pdf` + `printing` | 纯 Dart，Canvas 语义与 `android.graphics` 接近；可直接移植 `PdfChartRenderer`。 |
| 中文字体 | 内置 Noto Sans SC（子集） | `pdf` 默认 Helvetica 无中文字形。 |
| 文件保存 | Android：MediaStore/Downloads；iOS：分享面板 | `export_service.dart` 平台分支。 |
| 测试 | `package:test` | 移植现有 193 个 JUnit 用例；新增假传输层状态机测试。 |
| 平台标识 | 不透明 `deviceId` | Android=MAC，iOS=CBPeripheral UUID；禁止业务层假设 MAC。 |

## 3. 分层与目录

```
lib/
  main.dart / app.dart
  core/                    # 纯 Dart，禁止 import flutter
    protocol/              # UUID、IBeaconCodec、广播解析、RecordEntry、
                           # FFD0 命令、LogisticsInfo(FFC5)
    chart/                 # 轴范围、LTTB、刻度、布局、主题、几何
  ble/
    ble_transport.dart     # 抽象接口
    universal_ble_transport.dart
    scan_controller.dart
    device_connection.dart # 每设备 GATT 状态与回调分流
    connection_pool.dart
    param_writer.dart      # 串行写 + ack + 超时
    record_reader.dart     # 分块/流式 + 批次边界
  export/
    pdf_report_builder.dart
    pdf_chart_renderer.dart
    csv_exporter.dart
    export_service.dart
  state/
    app_state.dart
    app_controller.dart    # Riverpod Notifier
  ui/
    scanner_screen.dart
    widgets/
    theme/
test/
```

依赖方向：`ui → state → ble → ble_transport`；`core/` 不依赖 Flutter。
`core/chart` 沿用原 `chart/core` 的硬约束：只做判断，不做绘制。

## 4. BLE 抽象

```dart
abstract class BleTransport {
  Stream<ScanResultData> scan({Duration timeout});
  Future<void> stopScan();
  Future<void> connect(String deviceId);
  Future<void> disconnect(String deviceId);
  Future<List<BleService>> discoverServices(String deviceId);
  Future<Uint8List> read(String deviceId, String service, String characteristic);
  Future<void> write(String deviceId, String service, String characteristic,
      Uint8List value, {bool withResponse = true});
  Future<void> setNotify(String deviceId, String service, String characteristic,
      void Function(Uint8List) onData);
  Future<int> requestMtu(String deviceId, int mtu);
}
```

- 生产实现包 `universal_ble`；测试实现 `FakeBleTransport`，按脚本回放报文。
- `ScanResultData` 暴露：`deviceId`、`name`、`rssi`、`manufacturerData: Map<int, Uint8List>`、
  `serviceData: Map<String, Uint8List>`、`services`。
- iOS 差异：无 MAC；Scan Response 的本地名可能缺失；MTU 不可协商。
  业务层只消费抽象字段，平台差异收敛在 `universal_ble_transport.dart`。

## 5. 状态模型

- `AppState`：扫描状态、设备列表、设置（单位、阈值）、当前弹窗引用的 `activeDeviceId`。
- `DeviceSessionState`（`Map<String, DeviceSessionState>`）：连接态、认证态、
  设备信息、记录、读取进度、参数写入结果。
- 所有异步回调携带自己的 `deviceId`，杜绝原实现中全局 `dialogDeviceAddress` 串设备。
- 超时参数保持原值：连接 15s、参数 ack 2500ms、参数间隔 120ms、记录批次空闲 500ms。

## 6. 协议移植要点（不可回退的约束）

1. FFC5 字段表与固件 `s_log_fields[]` 逐项一致，总长 508B ≤ 512B。
2. `hasContent` 判空，不能用 `!= null`。
3. iBeacon 识别用子类型魔数 `value[2..3] == 02 15`，不是 Company ID。
4. 广播含两段 Manufacturer Data：`0x4C4B`（TL 传感器）与 `0x4C00`（iBeacon）。
5. 历史记录 8B：时间戳 4B LE、温度 int16 LE ×100、湿度 1B、标志 1B。
6. 流式读取以 `data_len == 0` 为批次边界，500ms 空闲兜底；首次空 ack 跳过。
7. FFAx 参数串行写，等 FFC4 ack；名称 FFC2 裸 UTF-8、≤8 字节、空串固件不回 ack。
8. 阈值统一按 ℃ 存储与比较；图表内部再换算显示单位。
9. 时间轴用 `double`（epoch 秒精度）。
10. 图表是原子块，分页高度常量只在此一处定义。

## 7. 导出

- PDF 报告：沿用原结构（统计、图表、记录表、物流信息、分页规则）。
  `pdf_report_builder.dart` 负责排版，`pdf_chart_renderer.dart` 只消费 `RenderPlan` 画图。
- CSV：沿用原列顺序、转义与 BOM/编码行为。
- 保存：Android 保留「保存到 Downloads」；iOS 写临时文件后弹系统分享面板。
- 导出过程用 `Isolate.run` 或分帧执行，UI 显示进度。

## 8. 测试与验收

- 移植 193 个现有单测：IBeaconCodec、设备名、LogisticsInfo、传感器解析、
  chart core 六个测试类。
- 新增：`ParamWriter` 串行/超时/stale ack、`RecordReader` 批次边界与分块、
  连接池多设备回调隔离。
- 真机验收清单（Android）：扫描字段、连接、密码、参数写、开始/停止、读全部、
  按时间读、清除、物流写读、PDF、CSV、多设备并发、断线重连（status 133）。
- iOS：代码与平台配置就绪，验收延后到有 Mac 时。

## 9. 迁移阶段

1. **环境与骨架**：Flutter SDK、`flutter create`、依赖、目录。
2. **纯逻辑移植**：protocol + chart core + 测试全绿。
3. **BLE 验证**：真机验证 universal_ble 的广播字段、长读、通知、多设备。
4. **连接与命令**：扫描、连接池、密码、参数串行写、记录读取。
5. **UI 复刻**：主界面、侧边栏、各弹窗。
6. **导出**：PDF 报告 + 图表 + CSV。
7. **Android 验收与收尾**；iOS 平台配置与文档。

## 10. 风险

| 风险 | 应对 |
|------|------|
| iOS 不提供 Scan Response / 名称 | 早期 iOS 验证；名称可从 iBeacon 段/连接后属性兜底，保持可配置。 |
| universal_ble 长读 508B 行为 | 第 3 阶段真机验证；不满足则写平台通道补长读。 |
| 中文字体体积 | Noto Sans SC 子集，必要时按需裁剪。 |
| 原 ViewModel 状态机复杂 | 拆协调器 + 假传输层测试，逐条对照原逻辑。 |
| Windows 无法构建 iOS | iOS 代码与配置先就绪，验收延后。 |

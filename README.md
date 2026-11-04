# TL 温湿度记录仪 — Flutter 版

用 Flutter 重写 `D:\AndroidStudioProjects\TL`（Kotlin + Jetpack Compose）。
目标双端（Android / iOS），当前阶段先在 Android 真机上验证 BLE。

## 环境

本机已配置：

- Flutter 3.47.9 / Dart 3.13.7：`D:\Flutter\flutter\bin\flutter`
- JDK 21（Temurin）：`D:\Flutter\jdk-21.0.13+9`
- Android SDK：`D:\Android_SDK`
- pub 镜像：`https://pub.flutter-io.cn`
- Flutter 引擎镜像：`https://storage.flutter-io.cn`
- Gradle 发行版镜像：已把 `android/gradle/wrapper/gradle-wrapper.properties`
  指向腾讯云镜像（services.gradle.org 在本机不可达）。

每次开新终端建议先导出：

```bash
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
export ANDROID_HOME="D:\Android_SDK"
```

## 常用命令

```bash
/d/Flutter/flutter/bin/flutter pub get
/d/Flutter/flutter/bin/flutter analyze
/d/Flutter/flutter/bin/flutter test
/d/Flutter/flutter/bin/flutter build apk --debug
/d/Flutter/flutter/bin/flutter run -d <device-id>
```

## 目录

```
lib/core/protocol/   # 纯 Dart：UUID、iBeacon、广播解析、记录、FFD0 命令、FFC5
lib/core/chart/      # 纯 Dart：图表轴范围/LTTB/刻度/布局
lib/ble/             # BleTransport 抽象、universal_ble 适配、单设备连接
lib/state/           # Riverpod 控制器
lib/ui/              # 界面
test/                # 单元测试
docs/superpowers/specs/  # 设计文档
```

## 当前阶段

1. ✅ Flutter 工程、目录、依赖、Android/iOS 权限配置
2. ✅ 纯逻辑：iBeacon / 广播解析 / FFC5 / FFD0 命令
3. ✅ BLE 连接层 + 假传输层测试
4. ✅ 真机验证（Android，2026-11-03）：
   - 扫描/过滤、广播温度湿度电压/条数/iBeacon 解析
   - 连接、MTU 247、服务发现
   - FFC3 密码 `1234` 认证
   - FFD0 `0x01` 设备信息、`0x02` 开始记录、`0x03` 停止
   - FFD3 记录状态、FFD4 记录间隔
   - FFC5 508B 长读（空块正确解码）
   - FFD2 通知 + `0x08` 流式读取 16/16 条记录（时间戳/温度/湿度正确）
5. ✅ 图表核心移植（124 个测试）
6. ✅ 完整 1:1 UI：主界面、设备卡、侧边栏设置、密码/参数/记录/物流/开始确认弹窗；
   Android 12+ 动态取色与原 Compose 一致
7. ✅ CSV 导出：内容生成 + Android `MediaStore` 下载目录
8. ✅ PDF：图表渲染器 + 报告排版（中文字体、分页、图表原子块）
9. ✅ 真机端到端（2026-11-04）：
   - FFC3 认证 → FFD0 `0x08` 流式读取 **19560/19560 条**
   - CSV 659 KB、19578 行；PDF 748 KB、530 页，中文/图表/统计正常
   - 导出内容已确认；`file_saver.saveFile` 会写私有目录，已改用 `saveToDownloads`
10. ⏳ iOS 真机验证
11. ⏳ Release 构建与签名

### 真机验证中发现并已处理

- **所有 FFD0 控制命令（0x02/0x05/0x08 等）必须先做 FFC3 密码认证**，
  否则命令直接失败。完整 App 的连接流程必须保留密码弹窗。
- Android 上**边扫描边连接**容易卡在 connecting；连接前先 `stopScan`。
- `universal_ble` 的 `ManufacturerData.companyId` 对 TL 传感器段是 `0x4B4C`
  （广播字节 `4C 4B` 的小端解析），iBeacon 段是 `0x004C`；解析器已按字节还原。
- iOS 拿不到 MAC/Scan Response 名称，设备标识必须用不透明 `deviceId`；
  代码已按此抽象，待 iOS 真机验证。

## 协议文档

协议权威来源仍在原工程的根目录（`D:\AndroidStudioProjects\TL\*.md`），
迁移期间不要复制表格，避免分叉。

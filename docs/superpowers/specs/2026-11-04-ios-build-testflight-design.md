# 无 Mac 环境下的 iOS 构建与分发方案

日期：2026-11-04

## 背景与约束

- 开发机为 Windows，无法运行 Xcode / clang / codesign，iOS 包必须在 macOS 上编译。
- 项目当前没有 Mac，但需要把 App 装进 iPhone 做内部测试，后期还要上架 App Store。
- 代码仓库已有 GitHub remote：`https://github.com/EtherealRay-groot/Flutter-TL.git`。
- iOS 侧此前从未真正编译过，只有 Flutter 默认模板；首次云端构建需要预留排错时间。

## 目标

1. 现在（无付费账号）就能产出可安装的 iOS 包，验证 App 在 iPhone 上的启动、蓝牙扫描、连接、读记录和导出功能。
2. 付费 Apple Developer Program 开通后，切换到 TestFlight 内部测试，构建 90 天有效、无需 Mac。
3. 同一条 CI 流水线保留后续提交 App Store 审核的能力。

## 方案选型

采用 **Codemagic 云端 macOS 构建 + TestFlight** 作为主线，**Sideloadly 免费侧载**作为付费账号审核期间的过渡验证。

- Codemagic：Flutter 原生支持，免费额度 500 分钟/月，可用 App Store Connect API Key 自动管理签名证书。
- Sideloadly：Windows 可用，支持免费 Apple ID 签名，满足“今天就能装进 iPhone”的验证需求。
- 不使用 GitHub Actions：私有仓库的 macOS 分钟数折算后偏少，且证书/描述文件需手工拆成 secrets，维护成本更高。
- 不租用云 Mac：按小时计费，每次更新都要远程手动操作，不适合长期迭代。

## 构建与分发流程

```
Windows 本地 ──push──▶ GitHub
                         │
                         ▼
                Codemagic 云端 macOS
                ├─ ios-unsigned：未签名 IPA（免费，手动触发）
                └─ ios-testflight：签名 IPA → App Store Connect（付费账号）
                         │
             ┌───────────┴───────────┐
             ▼                       ▼
    Windows + Sideloadly        iPhone 上的 TestFlight
    （免费 Apple ID，7 天）      （付费账号，90 天/构建）
```

### Phase 0：免费验证（当前阶段）

1. 修复 iOS 工程可构建性（见“改动清单”）。
2. 新增 `codemagic.yaml` 的 `ios-unsigned` 工作流：
   - 实例 `mac_mini_m2`，Xcode 使用最新稳定版，Flutter 固定 3.47.9。
   - 执行 `flutter pub get`、`flutter test`、`flutter build ios --release --no-codesign`。
   - 将 `build/ios/iphoneos/Runner.app` 放入 `Payload/` 并 zip 为 `TL-unsigned.ipa`，作为构建产物。
   - 仅手动/tag 触发，避免消耗免费额度。
3. 在 Windows 上用 Sideloadly 签名安装：
   - 安装 Sideloadly 与官方 iTunes/Apple 驱动；iPhone 开启开发者模式并信任电脑。
   - 拖入未签名 IPA，输入免费 Apple ID 完成签名。
   - 安装后在“设置 → 通用 → VPN 与设备管理”信任开发者证书。
   - 免费证书 7 天过期，到期用同一 Apple ID 重签；免费账号最多 3 个自签 App。

### Phase 1：TestFlight（付费账号开通后）

1. 加入 Apple Developer Program（个人 99 美元/年）。
2. App Store Connect 创建 App 记录：bundle id `com.etherealray.tlapp`，名称 TL，主语言简体中文，填写 SKU。
3. 生成 App Store Connect API Key（Admin 或 App Manager 角色），在 Codemagic 的 Integrations 中保存。
4. `codemagic.yaml` 增加 `ios-testflight` 工作流：
   - `ios_signing` 使用 app_store 分发类型，bundle identifier 与 App 记录一致。
   - `flutter build ipa --release --build-name=1.0.0 --build-number=$BUILD_NUMBER`。
   - 通过 `publishing.app_store_connect` 上传并提交 TestFlight。
5. App Store Connect → TestFlight → 内部测试组（最多 100 人，无需 Beta 审核），iPhone 安装 TestFlight App 接收构建。
6. 每次上传必须递增 build number，构建 90 天内可安装。

### Phase 2：App Store 上架（后期，本方案提供操作手册）

- 正式 App 图标（1024×1024，无透明通道；当前仍是 Flutter 默认图标）。
- 隐私政策 URL、App 隐私标签（说明蓝牙用途、不收集数据）。
- 各尺寸截图、描述、关键词、年龄分级。
- 审核备注说明需要 TL 温湿度记录仪硬件才能完整体验，并附操作说明。
- 从 TestFlight 构建提交 App Store 审核，或增加 `submit_to_app_store` 发布步骤。

## 改动清单

| 文件 | 改动 |
|---|---|
| `ios/Runner.xcodeproj/project.pbxproj` | Runner bundle id 改为 `com.etherealray.tlapp`；RunnerTests 改为 `com.etherealray.tlapp.RunnerTests`（Debug/Release/Profile 三套配置） |
| `ios/Runner/Info.plist` | 增加 `ITSAppUsesNonExemptEncryption = false`，避免每次上传回答出口合规问题 |
| 新增 `codemagic.yaml` | `ios-unsigned` 工作流；付费账号后追加 `ios-testflight` |
| 新增 `docs/ios-build-guide.md` | Windows 侧载、TestFlight、App Store 上架的中文操作手册 |
| `ios/Podfile`（视构建结果） | 若插件走 CocoaPods，首次构建后把生成的 Podfile 与 Podfile.lock 纳入版本管理 |

不改动 Android 侧，不改动 Android `applicationId` 与 `namespace`。

## 验证方式

- 本地：`flutter analyze`、`flutter test` 全部通过。
- 云端：Codemagic 构建成功，能下载 `TL-unsigned.ipa`。
- 真机（Phase 0）：Sideloadly 安装成功；App 启动、蓝牙权限弹窗正常；能扫描到 TL 设备；连接、密码认证、读记录、CSV/PDF 导出与分享可用。
- 真机（Phase 1）：TestFlight 构建出现在内部测试组，TestFlight 安装成功，功能与 Phase 0 一致。
- 每次 iOS 改动后重新触发云端构建；iOS 层无法在 Windows 本地验证，以云端构建日志和真机结果为准。

## 错误处理与排错

- 首次云端构建失败按 Codemagic 日志定位：SwiftPM/CocoaPods 集成、插件编译错误、Xcode 与 Flutter 版本不匹配。
- 构建稳定后锁定 Flutter 与 Xcode 版本，避免镜像更新导致漂移。
- Sideloadly 常见问题：开发者模式未开、设备未信任、免费账号签名数量超限（3 个 App/7 天）、anisette 服务失败（更新 Sideloadly 或更换网络）。
- 若 Codemagic 镜像没有 Flutter 3.47.9，回退到 stable 并在 `codemagic.yaml` 中注明原因。

## 风险

- Flutter 3.47.9 在 Codemagic 镜像中的可用性未经确认。
- `file_saver`、`printing` 等插件在 iOS 上的保存路径与分享行为可能与 Android 不同，需要真机验证。
- 免费 Apple ID 证书 7 天过期，只适合验证，不适合长期使用。
- 国内网络访问 GitHub/Codemagic 可能不稳定；构建在云端执行，不受本地网络影响。
- App Store 对 BLE 类 App 的审核可能要求硬件说明和演示材料。

## 不在本次范围

- Android 端改动。
- 正式 App 图标、截图、隐私政策等上架素材的制作。
- iOS 真机 BLE 功能的代码修复（需根据真机结果另行排期）。

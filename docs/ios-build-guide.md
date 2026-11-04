# iOS 构建与安装指南（Windows 环境）

本指南对应设计文档 `docs/superpowers/specs/2026-11-04-ios-build-testflight-design.md`。

## 0. 前提

- 代码已推送到 GitHub 仓库 `EtherealRay-groot/Flutter-TL`。
- iPhone 运行 iOS 16 或更高版本（需要开发者模式）。
- 免费 Apple ID 可用于 Phase 0；TestFlight 与 App Store 需要付费 Apple Developer Program（99 美元/年）。

## 1. 在 Codemagic 上跑第一次未签名构建

1. 打开 <https://codemagic.io>，用 GitHub 账号登录。
2. 点击 **Add application**，选择 `Flutter-TL` 仓库，项目类型选 **Flutter App**。
3. 仓库根目录已有 `codemagic.yaml`，Codemagic 会自动识别。
4. 在应用页选择 **ios-unsigned** 工作流，点击 **Start new build**。
5. 首次构建预计 15–25 分钟。免费额度为 500 分钟/月。
6. 构建成功后，在 **Artifacts** 中下载 `TL-unsigned.ipa`。

首次构建如果失败，先看日志最后 50 行：

- `Flutter version 3.47.9 not found`：把 `codemagic.yaml` 里的 `flutter:` 改为 `stable` 后重试。
- `CocoaPods` 相关错误：确认 `cocoapods: default`，并把构建日志中生成的 `ios/Podfile` 提交到仓库。
- 插件编译错误：记录插件名与报错，回到本地用 `flutter analyze` / `flutter test` 排查 Dart 侧问题。

## 2. Windows 上安装 Sideloadly

1. 从 Apple 官网安装 iTunes（不要用 Microsoft Store 版本），确保 Apple 移动设备驱动可用。
2. 从 <https://sideloadly.io> 下载并安装 Sideloadly。
3. 用 USB 连接 iPhone，手机上点 **信任此电脑**。
4. iPhone 打开 **设置 → 隐私与安全性 → 开发者模式**，开启后重启手机。

## 3. 用免费 Apple ID 签名安装

1. 打开 Sideloadly，确认左上角识别到 iPhone。
2. 把 `TL-unsigned.ipa` 拖入 **IPA** 框。
3. 在 **Apple account** 填入免费 Apple ID。
4. 如果提示 bundle id 冲突，勾选自动修改 bundle id（Sideloadly 会加随机后缀）。
5. 点击 **Start**，输入 Apple ID 密码和双重认证验证码。
6. 安装完成后，在 iPhone 上打开 **设置 → 通用 → VPN 与设备管理**，信任对应的开发者证书。
7. 回到桌面启动 TL。

免费账号限制：

- 证书 7 天过期，到期后用 Sideloadly 重新安装同一 IPA；应用数据通常保留。
- 最多同时安装 3 个自签 App。
- 每 7 天最多注册 10 个 App ID。

## 4. 真机验证清单（Phase 0）

- [ ] App 能启动，不闪退。
- [ ] 首次进入出现蓝牙权限弹窗，文案为中文。
- [ ] 能扫描到 TL 温湿度记录仪。
- [ ] 能连接、输入密码并完成 FFC3 认证。
- [ ] 能读取历史记录并显示曲线。
- [ ] 能导出 CSV 和 PDF，中文不乱码。
- [ ] 能调起系统分享面板保存/发送文件。

## 5. 付费账号开通后的 TestFlight 配置

### 5.1 加入 Apple Developer Program

1. 打开 <https://developer.apple.com/programs/>，用 Apple ID 注册个人开发者账号。
2. 支付 99 美元/年，等待审核（通常 24–48 小时）。

### 5.2 在 App Store Connect 创建 App

1. 打开 <https://appstoreconnect.apple.com> → **我的 App** → **+** → **新建 App**。
2. 平台选 iOS，名称填 `TL`，主语言选简体中文。
3. Bundle ID 选择 `com.etherealray.tlapp`（若列表中没有，先在 **证书、标识符和描述文件** 中注册 App ID）。
4. SKU 可填 `tlapp-ios-001`。

### 5.3 创建 App Store Connect API Key

1. App Store Connect → **用户和访问** → **集成** → **App Store Connect API**。
2. 生成密钥，角色选 **App 经理** 或 **管理员**。
3. 记录 **Issuer ID**、**Key ID**，下载 `.p8` 文件（只能下载一次）。

### 5.4 在 Codemagic 添加集成

1. Codemagic → **Teams** → **Integrations** → **App Store Connect**。
2. 名称填 `TLAppStoreConnect`（必须与 `codemagic.yaml` 中的名字一致）。
3. 填入 Issuer ID、Key ID，上传 `.p8` 文件。

### 5.5 启用 `ios-testflight` 工作流

在 `codemagic.yaml` 的 `workflows:` 下追加：

```yaml
  ios-testflight:
    name: iOS TestFlight
    instance_type: mac_mini_m2
    max_build_duration: 90
    integrations:
      app_store_connect: TLAppStoreConnect
    environment:
      flutter: 3.47.9
      xcode: latest
      cocoapods: default
      ios_signing:
        distribution_type: app_store
        bundle_identifier: com.etherealray.tlapp
    scripts:
      - name: Flutter pub get
        script: flutter pub get
      - name: Run tests
        script: flutter test
      - name: Apply code signing profiles
        script: xcode-project use-profiles
      - name: Build signed IPA
        script: |
          flutter build ipa --release \
            --build-name=1.0.0 \
            --build-number=$BUILD_NUMBER \
            --export-options-plist=$HOME/export_options.plist
    artifacts:
      - build/ios/ipa/*.ipa
    publishing:
      app_store_connect:
        auth: integration
        submit_to_testflight: true
```

保存后推送，在 Codemagic 选择 **ios-testflight** 工作流运行。每次上传的 build number 会自动递增。

### 5.6 安装 TestFlight 构建

1. App Store Connect → **TestFlight** → **内部测试**，创建测试组并添加自己的 Apple ID。
2. iPhone 从 App Store 安装 **TestFlight**，用同一个 Apple ID 登录。
3. 构建处理完成后（通常 10–30 分钟）会出现在 TestFlight 中，点击安装。
4. 每个构建 90 天内可安装；过期后重新跑工作流即可。

## 6. App Store 上架清单（后期）

- [ ] 正式 App 图标（1024×1024 PNG，无透明通道；当前仍是 Flutter 默认图标）。
- [ ] 隐私政策 URL。
- [ ] App 隐私标签：蓝牙仅用于连接温湿度记录仪，不收集用户数据。
- [ ] 各尺寸截图与 App 描述、关键词。
- [ ] 年龄分级。
- [ ] 审核备注说明需要 TL 硬件才能完整体验，并附操作说明。
- [ ] 在 App Store Connect 选择 TestFlight 构建提交审核。

## 7. 常见问题

| 现象 | 处理 |
|---|---|
| Codemagic 找不到 Flutter 3.47.9 | 把 `codemagic.yaml` 的 `flutter:` 改为 `stable` |
| 构建报 CocoaPods 错误 | 确认 `cocoapods: default`，把生成的 `ios/Podfile` 与 `Podfile.lock` 提交 |
| Sideloadly 提示无法连接设备 | 重装 Apple 官网版 iTunes，重新插拔并信任电脑 |
| 提示未开启开发者模式 | 设置 → 隐私与安全性 → 开发者模式 |
| 免费证书过期 | 用同一 Apple ID 在 Sideloadly 重签，数据通常保留 |
| TestFlight 看不到构建 | 等 10–30 分钟处理；检查 App Store Connect 的构建状态与邮箱通知 |
| 上传报加密合规 | 确认 `Info.plist` 中 `ITSAppUsesNonExemptEncryption` 为 `false` |

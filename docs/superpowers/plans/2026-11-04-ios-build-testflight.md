# 无 Mac 的 iOS 构建与分发 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 Windows 开发机上通过 Codemagic 云端 macOS 构建出可安装的 iOS 包，先用免费 Apple ID 侧载验证，付费账号开通后切换到 TestFlight，并为 App Store 上架保留流水线。

**Architecture:** 代码推送到现有 GitHub 仓库，Codemagic 读取仓库根的 `codemagic.yaml`，在 macOS 实例上编译。免费阶段产出未签名 IPA，由 Windows 上的 Sideloadly 用免费 Apple ID 签名安装；付费阶段由 Codemagic 用 App Store Connect API Key 自动签名并上传 TestFlight。

**Tech Stack:** Flutter 3.47.9、Dart 3.13.7、Codemagic（macOS 构建）、Sideloadly（Windows 签名侧载）、TestFlight。

## Global Constraints

- 目标 bundle id：`com.etherealray.tlapp`（RunnerTests 为 `com.etherealray.tlapp.RunnerTests`）。
- iOS 部署目标保持 `IPHONEOS_DEPLOYMENT_TARGET = 15.0`，不修改。
- 不改动 Android 侧任何配置。
- Flutter 版本固定 3.47.9；若 Codemagic 镜像不可用，回退 `stable` 并在 `codemagic.yaml` 注释说明。
- 所有新增文档与注释使用中文，与仓库风格一致。
- 本仓库规则：未经用户明确要求不自动 `git commit` / `git push`；执行时保留工作区改动即可。

---

### Task 1: 修改 iOS bundle id

**Files:**
- Modify: `ios/Runner.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: 无
- Produces: 全部 Debug/Release/Profile 配置的 Runner bundle id 为 `com.etherealray.tlapp`，RunnerTests 为 `com.etherealray.tlapp.RunnerTests`。

- [ ] **Step 1: 替换全部 bundle id**

在 `ios/Runner.xcodeproj/project.pbxproj` 中把所有 `com.example.tlApp` 替换为 `com.etherealray.tlapp`（包括 `com.example.tlApp.RunnerTests`，替换后会自然变成 `com.etherealray.tlapp.RunnerTests`）。

- [ ] **Step 2: 验证替换结果**

Run:

```bash
grep -n "PRODUCT_BUNDLE_IDENTIFIER" ios/Runner.xcodeproj/project.pbxproj
```

Expected:

```
PRODUCT_BUNDLE_IDENTIFIER = com.etherealray.tlapp;
PRODUCT_BUNDLE_IDENTIFIER = com.etherealray.tlapp.RunnerTests;
PRODUCT_BUNDLE_IDENTIFIER = com.etherealray.tlapp.RunnerTests;
PRODUCT_BUNDLE_IDENTIFIER = com.etherealray.tlapp.RunnerTests;
PRODUCT_BUNDLE_IDENTIFIER = com.etherealray.tlapp;
PRODUCT_BUNDLE_IDENTIFIER = com.etherealray.tlapp;
```

且 `grep -c "com.example.tlApp" ios/Runner.xcodeproj/project.pbxproj` 输出 `0`。

---

### Task 2: 增加出口合规声明

**Files:**
- Modify: `ios/Runner/Info.plist`

**Interfaces:**
- Consumes: 无
- Produces: `Info.plist` 含 `ITSAppUsesNonExemptEncryption = false`，App Store Connect 上传时不再询问加密出口合规。

- [ ] **Step 1: 在 `NSBluetoothPeripheralUsageDescription` 之后插入**

```xml
	<key>ITSAppUsesNonExemptEncryption</key>
	<false/>
```

- [ ] **Step 2: 验证**

Run:

```bash
grep -A1 "ITSAppUsesNonExemptEncryption" ios/Runner/Info.plist
```

Expected:

```
<key>ITSAppUsesNonExemptEncryption</key>
<false/>
```

---

### Task 3: 新增 Codemagic 未签名构建工作流

**Files:**
- Create: `codemagic.yaml`

**Interfaces:**
- Consumes: Task 1 的 bundle id；Task 2 的 Info.plist。
- Produces: 工作流 `ios-unsigned`，产物 `build/ios/iphoneos/TL-unsigned.ipa`。

- [ ] **Step 1: 创建 `codemagic.yaml`**

完整内容：

```yaml
workflows:
  ios-unsigned:
    name: iOS unsigned IPA (free sideload)
    instance_type: mac_mini_m2
    max_build_duration: 60
    environment:
      # 与本地开发环境一致；若 Codemagic 镜像尚未提供 3.47.9，改成 stable。
      flutter: 3.47.9
      xcode: latest
      cocoapods: default
    scripts:
      - name: Flutter pub get
        script: flutter pub get
      - name: Analyze
        script: flutter analyze
      - name: Run tests
        script: flutter test
      - name: Build unsigned app
        script: flutter build ios --release --no-codesign
      - name: Package unsigned IPA
        script: |
          cd build/ios/iphoneos
          rm -rf Payload TL-unsigned.ipa
          mkdir -p Payload
          cp -R Runner.app Payload/
          zip -qry TL-unsigned.ipa Payload
          ls -lh TL-unsigned.ipa
    artifacts:
      - build/ios/iphoneos/TL-unsigned.ipa
    # 不配置 triggering：只在 Codemagic 界面手动触发，避免消耗免费额度。
```

- [ ] **Step 2: 校验 YAML 语法**

Run:

```bash
python -c "import yaml; yaml.safe_load(open('codemagic.yaml', encoding='utf-8')); print('YAML OK')"
```

Expected:

```
YAML OK
```

- [ ] **Step 3: 验证工作流与产物路径**

Run:

```bash
grep -n "ios-unsigned\|TL-unsigned.ipa\|flutter: 3.47.9" codemagic.yaml
```

Expected: 三处均能匹配到。

---

### Task 4: 编写 Windows 侧载与 TestFlight 操作手册

**Files:**
- Create: `docs/ios-build-guide.md`

**Interfaces:**
- Consumes: Task 3 的 `ios-unsigned` 工作流名称与产物路径。
- Produces: 供用户在 Windows 上完成安装、后续 TestFlight 与 App Store 上架的操作步骤。

- [ ] **Step 1: 创建 `docs/ios-build-guide.md`**

完整内容：

````markdown
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
````

- [ ] **Step 2: 验证文件结构**

Run:

```bash
grep -n "^## " docs/ios-build-guide.md
```

Expected: 至少包含 `## 1. 在 Codemagic 上跑第一次未签名构建`、`## 3. 用免费 Apple ID 签名安装`、`## 5. 付费账号开通后的 TestFlight 配置`。

---

### Task 5: 本地静态检查与测试

**Files:**
- 不新增文件；验证 Task 1–4 的改动。

**Interfaces:**
- Consumes: Task 1–4 的全部改动。
- Produces: 可提交的干净工作区，确认 Dart 侧无回归。

- [ ] **Step 1: 运行静态检查**

Run:

```bash
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
export ANDROID_HOME="D:\Android_SDK"
/d/Flutter/flutter/bin/flutter analyze
```

Expected: `No issues found!`（或仅有与本次改动无关的既有提示；如有，记录并在完成报告中说明）。

- [ ] **Step 2: 运行全部测试**

Run:

```bash
/d/Flutter/flutter/bin/flutter test
```

Expected: `All tests passed!`

- [ ] **Step 3: 检查 git 工作区**

Run:

```bash
git status --short
```

Expected: 只出现 `codemagic.yaml`、`docs/ios-build-guide.md`、`ios/Runner.xcodeproj/project.pbxproj`、`ios/Runner/Info.plist` 及设计/计划文档。不要提交，等待用户确认。

---

### Task 6: 第一次云端构建（需用户在 Codemagic 网页操作）

**Files:**
- 无代码改动；使用 Task 3 的工作流。

**Interfaces:**
- Consumes: 已推送到 GitHub 的 `codemagic.yaml`。
- Produces: 可下载的 `TL-unsigned.ipa`，以及首次构建的排错结论。

- [ ] **Step 1: 推送代码到 GitHub**

需要用户确认后执行：

```bash
git push origin main
```

- [ ] **Step 2: 在 Codemagic 创建应用并运行 ios-unsigned**

按 `docs/ios-build-guide.md` 第 1 节操作。若首次构建失败，把日志中最后 50 行反馈给执行者，按 Task 4 的排错表修正后重跑。

- [ ] **Step 3: 下载产物并侧载**

按 `docs/ios-build-guide.md` 第 2、3 节操作，完成安装后按第 4 节逐项验证。

---

### Task 7: 付费账号后启用 TestFlight 工作流（条件任务）

**Files:**
- Modify: `codemagic.yaml`（追加 `ios-testflight`）
- Modify: `docs/ios-build-guide.md`（如实际配置与手册不一致，同步修正）

**Interfaces:**
- Consumes: Task 3 的 `codemagic.yaml`；用户已创建的 App Store Connect API Key。
- Produces: 可上传 TestFlight 的 `ios-testflight` 工作流。

- [ ] **Step 1: 追加工作流**

把 `docs/ios-build-guide.md` 第 5.5 节的 YAML 追加到 `codemagic.yaml` 的 `workflows:` 下，并校验：

```bash
python -c "import yaml; yaml.safe_load(open('codemagic.yaml', encoding='utf-8')); print('YAML OK')"
```

Expected: `YAML OK`

- [ ] **Step 2: 在 Codemagic 运行 ios-testflight**

确认 Integration 名称 `TLAppStoreConnect` 已创建，运行工作流，检查 App Store Connect → TestFlight 出现新构建。

- [ ] **Step 3: 真机安装 TestFlight 构建并复验**

按 `docs/ios-build-guide.md` 第 5.6 节操作，重复第 4 节的验证清单。

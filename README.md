# 日益 · iPhone 与 Apple Watch 试用源码

这是「日益」的 iPhone / Apple Watch 客户端源码，供朋友在自己的设备上试用。仓库包含客户端编译所需的动作指南数据；不包含后端源码、服务器配置、账号、签名证书或安装包。

## 安装条件

- Mac、Xcode、iOS 18 或更新版本的 iPhone，以及与该 iPhone 配对、运行 watchOS 11 或更新版本的 Apple Watch。
- 在 Xcode 中登录自己的 Apple 账号。免费账号可使用 **Personal Team** 在自己的设备上安装测试，不需要 App Store 或 TestFlight。免费签名通常 7 天到期，届时需重新构建安装。
- 安装与设备授权需要本人在 Mac、iPhone 和 Apple Watch 上操作；不要把 Apple 账号密码交给 AI 或仓库作者。

## 构建与真机安装

1. 在 Xcode 的 **Settings → Accounts** 中登录自己的 Apple 账号。
2. 在本地副本的 `ios/project.yml` 中，将 `RIYI_IOS_BUNDLE_ID` 改为自己账号下唯一的 iPhone Bundle ID。Watch 的 Bundle ID 和 `WKCompanionAppBundleIdentifier` 会随它自动匹配。安装 XcodeGen 后在 `ios/` 目录执行 `xcodegen generate`，再打开 `ios/AiHealth.xcodeproj`。
3. 为 `AiHealth` 和 `AiHealthWatch` 两个目标选择自己的 Personal Team，启用自动签名，保留两端的 HealthKit 权限。先选择 iPhone 模拟器确认能编译。
4. 将配对 iPhone 连接 Mac，在 Xcode Device Hub 中确认 **iPhone 和 Apple Watch 均已被发现并登记**；按两台设备的提示完成信任与开发者模式。若手表未出现，先解决配对问题，不要用只含 iPhone 的描述文件给 Watch 签名。
5. 选择 `AiHealth` scheme 和配对 iPhone，构建并安装手机 App；再选择 `AiHealthWatch` scheme 和真实 Apple Watch，构建并安装手表 App。若 Xcode 已随手机 App 自动安装 Watch App，仍需在手表端确认它存在并能启动。
6. 分别在 iPhone 和 Apple Watch 上启动「日益」，确认手机端能使用本地记录、两端能完成一次演示训练同步。若要验证真实心率采集，请本人在 Watch 上授权健康权限后再单独测试。

项目默认连接 `https://health.qyos.top`。不登录也能使用「先体验本地记录」；若要使用云端功能，请自己注册账号。Apple 健康读取、健康上传和 AI 分析分别由本人在 App 中授权。请勿使用仓库作者的账号或密钥。客户端仓库不需要在你的电脑上部署数据库或后端。

换用自己的 Bundle ID 会创建独立的 App 数据空间，不会自动迁移其他安装版的本地记录。测试时不要卸载已有的同名 App，先确认 Bundle ID 与数据空间。

## 给 Codex 的任务

> 请阅读本仓库 README 和 `ios/project.yml`，协助我用自己的 Apple 账号 Personal Team 把「日益」**同时安装到我的 iPhone 和已配对的 Apple Watch**。先检查 Mac、Xcode、两台设备和签名条件；在我的本地副本中修改 `RIYI_IOS_BUNDLE_ID`、重新生成工程，为手机和手表目标设置自己的 Team 与自动签名，并保留 HealthKit。先验证构建，再确保 Xcode Device Hub 发现并登记两台设备、两端均启用开发者模式。分别安装并启动手机和手表 App，检查本地记录与演示训练同步；不能只凭 BUILD SUCCEEDED 或手机已装就称为完成。默认后端是 `https://health.qyos.top`，只验证其可达性，不修改或部署服务端。不要索取我的 Apple 密码，不使用作者证书，不把个人签名配置或密钥推回 GitHub。遇到阻碍请给出实际报错和下一步，最后分别报告 iPhone 与 Watch 的构建、签名、安装、启动和联动验证结果。

## 第三方资料

动作指南数据参考 [Free Exercise DB](third_party/free-exercise-db/NOTICE.md)。客户端中提及的营养与训练参考资料声明见 `third_party/` 下相应 NOTICE 和 LICENSE。除明确标注的第三方资料外，本仓库未授予其他再分发许可。

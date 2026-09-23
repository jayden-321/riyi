# 日益 · iPhone 试用源码

这是「日益」的 iPhone / Apple Watch 客户端源码，供朋友在自己的设备上试用。仓库包含客户端编译所需的动作指南数据；不包含后端源码、服务器配置、账号、签名证书或安装包。

## 安装条件

- Mac、Xcode、iOS 18 或更新版本的 iPhone。Watch 功能需要另有已配对的 Apple Watch。
- 在 Xcode 中登录自己的 Apple 账号。免费账号可使用 **Personal Team** 在自己的设备上安装测试，不需要 App Store 或 TestFlight。免费签名通常 7 天到期，届时需重新构建安装。
- 安装与设备授权需要本人在 Mac / iPhone 上操作；不要把 Apple 账号密码交给 AI 或仓库作者。

## 构建与真机安装

1. 在 Xcode 的 **Settings → Accounts** 中登录自己的 Apple 账号。
2. 打开 `ios/AiHealth.xcodeproj`。工程配置源文件是 `ios/project.yml`；若修改它，请安装 XcodeGen 后在 `ios/` 目录执行 `xcodegen generate`。
3. 为 `AiHealth` 和 `AiHealthWatch` 目标选择自己的 Personal Team，启用自动签名，并将两个 Bundle Identifier 改为自己账号下唯一且互相匹配的值。保留项目需要的 HealthKit 权限。可以让 Codex 协助修改本地工程配置。
4. 先选择 iPhone 模拟器确认能编译，再连接并选择自己的 iPhone，点击 **Run**。按 Xcode 与 iPhone 的提示完成设备信任、开发者模式和健康权限授权。先确认 iPhone App 能启动；Watch 另行安装验证。

项目默认连接 `https://health.qyos.top`。不登录也能使用「先体验本地记录」；若要使用云端功能，请自己注册账号。Apple 健康读取、健康上传和 AI 分析分别由本人在 App 中授权。请勿使用仓库作者的账号或密钥。客户端仓库不需要在你的电脑上部署数据库或后端。

换用自己的 Bundle ID 会创建独立的 App 数据空间，不会自动迁移其他安装版的本地记录。测试时不要卸载已有的同名 App，先确认 Bundle ID 与数据空间。

## 给 Codex 的任务

> 请阅读本仓库 README 和 `ios/project.yml`，协助我用自己的 Apple 账号 Personal Team 把「日益」安装到我的 iPhone。先检查 Mac、Xcode、设备和签名条件，再在我的本地副本中配置 Team、唯一的 iPhone / Watch Bundle ID 与自动签名，保留 HealthKit 能力。先验证构建，再真机安装并启动，检查本地记录；Watch 仅在我有手表时继续。默认后端是 `https://health.qyos.top`，只验证其可达性，不修改或部署服务端。不要索取我的 Apple 密码，不使用作者证书，不把个人签名配置或密钥推回 GitHub。遇到阻碍请给出实际报错和下一步，最后区分构建、安装、启动和功能验证结果。

## 第三方资料

动作指南数据参考 [Free Exercise DB](third_party/free-exercise-db/NOTICE.md)。客户端中提及的营养与训练参考资料声明见 `third_party/` 下相应 NOTICE 和 LICENSE。除明确标注的第三方资料外，本仓库未授予其他再分发许可。

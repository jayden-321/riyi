# 日益 · iPhone 与 Apple Watch 试用源码

这是「日益」的 iPhone / Apple Watch 客户端源码，供朋友在自己的设备上试用。仓库包含客户端编译所需的动作指南数据；不包含后端源码、服务器配置、账号、签名证书或安装包。

## 安装条件

- Mac、Xcode、iOS 18 或更新版本的 iPhone，以及与该 iPhone 配对、运行 watchOS 11 或更新版本的 Apple Watch。
- 在 Xcode 中登录自己的 Apple 账号。免费账号可使用 **Personal Team** 在自己的设备上安装测试，不需要 App Store 或 TestFlight。免费签名通常 7 天到期，届时需重新构建安装。
- 安装与设备授权需要本人在 Mac、iPhone 和 Apple Watch 上操作；不要把 Apple 账号密码交给 AI 或仓库作者。

## 构建与真机安装

1. 在 Xcode 的 **Settings → Accounts** 中登录自己的 Apple 账号。
2. 在本地副本的 `ios/project.yml` 中，将 `RIYI_IOS_BUNDLE_ID` 改为自己账号下唯一的 iPhone Bundle ID，并将共用的 `DEVELOPMENT_TEAM` 填为**同一个** Personal Team ID。Watch 的 Bundle ID 和 `WKCompanionAppBundleIdentifier` 会随 iPhone ID 自动匹配。安装 XcodeGen 后在 `ios/` 目录执行 `xcodegen generate`，再打开 `ios/AiHealth.xcodeproj`。
3. 在 Xcode 的 Signing & Capabilities 中确认 `AiHealth` 与 `AiHealthWatch` 显示同一 Team，均使用自动开发签名，并保留两端的 HealthKit 权限。两端 App ID 不同，因此各自需要匹配的描述文件；**同一个 Team / 开发签名不等于共用一份描述文件**。先选择 iPhone 模拟器确认能编译。
4. 将配对 iPhone 连接 Mac，在 Xcode Device Hub 中确认 **iPhone 和 Apple Watch 均已被发现并登记**；按两台设备的提示完成信任与开发者模式。若手表未出现，先解决配对问题，不要用只含 iPhone 的描述文件给 Watch 签名。
5. 选择 `AiHealth` scheme 和配对 iPhone，构建并安装手机 App；再选择 `AiHealthWatch` scheme 和真实 Apple Watch，构建并安装手表 App。检查两份签名产物的 Team ID 与开发证书指纹一致，同时分别检查手机、手表描述文件覆盖对应的 Bundle ID 和设备。若 Xcode 已随手机 App 自动安装 Watch App，仍需在手表端确认它存在并能启动。
6. 分别在 iPhone 和 Apple Watch 上启动「日益」，确认手机端能使用本地记录、两端能完成一次演示训练同步。若要验证真实心率采集，请本人在 Watch 上授权健康权限后再单独测试。

项目默认连接 `https://health.qyos.top`。本次试用请在欢迎页点击「已有账号？登录」，使用你自己的云端账号进入，**不要选择「先体验本地记录」**；没有账号时可自行注册。Apple 健康读取、健康上传和 AI 分析分别由本人在 App 中授权。请勿使用仓库作者的账号或密钥。客户端仓库不需要在你的电脑上部署数据库或后端。

当前客户端构建号为 **33**，包含训练／休息日日历、组团打卡、Apple 健康睡眠与体征、AI 教练、饮食文字与拍照粗估和新图标。饮食记录默认使用当前时刻；文字或照片粗估要求本人在 App 中同意 AI 使用数据，返回的范围需核对，份量不清时可先保存为“热量待估算”。教练请求断线后按请求号恢复同一次结果，避免盲目重复生成；云端登录过期时会提示重新登录，“我的”也有固定入口；只能重新登录同一账号，原本机记录会保留。清空教练聊天后，定时训练／睡眠分析仍可从「分析记录」单独查看。拍包装核对保存后会自动生成分享码，新商品默认可由其他用户按名称或品牌搜索；分享仅包含商品资料，不包含饮食记录，仍可关闭搜索或撤销分享。文字粗估接口已部署在默认服务器；此公开仓库仅含客户端。

饮食页把饮水放在最上方，方便每两小时快速记录；饮水详情按“今天已记录、最近记录、自定义补记、提醒”排列，快捷按钮采用浅色底与深色文字；热量汇总只显示已记录热量主数字；AI 粗估按上下限平均值计入“约”热量，每笔原范围仍可在记录行查看，只有真正缺失热量时才出现一行提示。

换用自己的 Bundle ID 会创建独立的 App 数据空间，不会自动迁移其他安装版的本地记录。测试时不要卸载已有的同名 App，先确认 Bundle ID 与数据空间。

## 给 Codex 的任务

> 请先 `git pull --ff-only origin main` 更新日益客户端源码，并保护我本机未提交的修改。阅读 README 与 `ios/project.yml`，用我自己的 Apple 账号 Personal Team 给 iPhone 和已配对的 Apple Watch 安装构建 **33** 的「日益」：两端必须使用同一个 Team、同一张 Apple Development 证书，各自的描述文件覆盖对应 Bundle ID 与设备。在本地填写独有的 `RIYI_IOS_BUNDLE_ID` 和共用 `DEVELOPMENT_TEAM`，重新运行 `xcodegen generate`，再用 Xcode 构建、安装并启动两端。手机欢迎页选择「已有账号？登录」，使用我自己的云端账号和默认服务器 `https://health.qyos.top`；**不要选择本地演示**，也不要使用仓库作者账号。请让我在设备上亲自输入密码并授予 Apple 健康、云端上传和 AI 权限。登录后核对云端数据、今天训练或休息日、手表收到的同日状态、饮食文字粗估、拍照识别及重新登录入口。只凭 BUILD SUCCEEDED 或已安装不能算完成；分别报告两端签名、安装、启动、同步与实际限制。不要部署或修改服务器，不索取 Apple 密码，不把个人签名配置、密钥或健康记录推回 GitHub。

## 第三方资料

动作指南数据参考 [Free Exercise DB](third_party/free-exercise-db/NOTICE.md)。客户端中提及的营养与训练参考资料声明见 `third_party/` 下相应 NOTICE 和 LICENSE。除明确标注的第三方资料外，本仓库未授予其他再分发许可。

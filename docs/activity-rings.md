# 训练成果与苹果三环

Apple Fitness 的红色活动环记录当天活动消耗（或按设备设置记录活动时间），绿色锻炼环记录锻炼分钟，蓝色站立环记录达到站立条件的小时。它们是**全天**进度，不能解释为某一场训练独得的分数。日益在训练日历的所选日期读取 HealthKit `HKActivitySummary` 并使用系统 `HKActivityRingView` 显示三环及目标数字。没有获准读取的活动汇总时显示缺失提示，不把未知当作零。参考 [Apple Fitness 活动圆环](https://support.apple.com/guide/iphone/see-your-activity-summary-iph4c34a8a95/ios) 与 [HealthKit 活动汇总查询](https://developer.apple.com/documentation/healthkit/hkactivitysummaryquery)。

三环只放在训练日历，点击圆环进入当天详情：周日期、三个目标、活动与锻炼的逐小时分布、站立小时、步数和距离。单场 HIIT 等已练记录不重复放当天圆环。圆环整日总数以 Apple 活动汇总为准，逐小时图取获准的 HealthKit 样本，苹果的来源合并方式可能使两者不能机械相加。训练页按周读取并缓存活动汇总；点同一周的其他日期只切换已读数值，不重复查询所有健康原始数据或调用服务器。

Apple Watch 上，没有当前训练任务时显示手表本机活动汇总的三环和活动、锻炼、站立数字；当天训练结束后也回到空闲三环，不停留在“训练已结束”。有进行中任务时继续优先展示动作、组数与休息倒计时。手表的活动汇总读取需要单独的 HealthKit 授权，缺数据时保留明确提示，不把空白当作三项零分。

单场训练继续单独量化已记录的时长、正式组数、重量容量、距离、可关联的心率采样与 HealthKit 活动能量。外部 Apple Fitness Workout 的活动能量按原始 HealthKit UUID 精确关联；日益训练写回 Apple 健康后，由苹果计算是否以及如何计入当天圆环。日益不另行推算或强行填满三环，也不把同一场训练的原始 Workout 能量再次加到每日活动能量中。

当前日益运动大类已分别映射到 Apple Workout 类型：力量、HIIT、普拉提、游泳、跑步、骑行、步行、瑜伽、徒步、划船和椭圆机。「其他运动」以及将来尚未映射的新类别使用 Apple 的 Other，避免误记成力量训练。手机或手表仅在实际训练完成且获得写入授权后保存 Workout；外部导入的训练不会再反向写入。

Apple 的睡眠评分目前没有对第三方开放读取 API；日益只读取可授权的睡眠时长与阶段，不把自行推算值标成苹果原分数。依据 [Apple Developer DTS 的说明](https://developer.apple.com/forums/thread/800403)；若未来系统接口变化，需要重新核实。

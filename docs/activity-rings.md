# 训练成果与苹果三环

Apple Fitness 的红色活动环记录当天活动消耗（或按设备设置记录活动时间），绿色锻炼环记录锻炼分钟，蓝色站立环记录达到站立条件的小时。它们是**全天**进度，不能解释为某一场训练独得的分数。日益在训练日历的所选日期，以及已完成训练的详情和总结页，读取 HealthKit `HKActivitySummary` 并使用系统 `HKActivityRingView` 显示三环及目标数字。没有获准读取的活动汇总时显示缺失提示，不把未知当作零。参考 [Apple Fitness 活动圆环](https://support.apple.com/guide/iphone/see-your-activity-summary-iph4c34a8a95/ios) 与 [HealthKit 活动汇总查询](https://developer.apple.com/documentation/healthkit/hkactivitysummaryquery)。

单场训练继续单独量化已记录的时长、正式组数、重量容量、距离、可关联的心率采样与 HealthKit 活动能量。外部 Apple Fitness Workout 的活动能量按原始 HealthKit UUID 精确关联；日益训练写回 Apple 健康后，由苹果计算是否以及如何计入当天圆环。日益不另行推算或强行填满三环，也不把同一场训练的原始 Workout 能量再次加到每日活动能量中。

当前日益运动大类已分别映射到 Apple Workout 类型：力量、HIIT、普拉提、游泳、跑步、骑行、步行、瑜伽、徒步、划船和椭圆机。「其他运动」以及将来尚未映射的新类别使用 Apple 的 Other，避免误记成力量训练。手机或手表仅在实际训练完成且获得写入授权后保存 Workout；外部导入的训练不会再反向写入。

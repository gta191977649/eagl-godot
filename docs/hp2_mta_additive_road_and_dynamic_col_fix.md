# HP2 → MTA 道路混合与动态 COL 修复

## 道路混合

`road_325ccf64d259ac574e16` 已由 packed 内容指纹反查为 Track 11
`TEX11LOCATION.BIN` 中哈希 `0xdb00d526` 的 `TUNNELROAD_MASK`。源纹理为
128×256 RGBA，TPK 标记 `alpha_bits=0x48`、`is_any_semitransparency=1`；
`0x48` 对应 HP2 PS2 的 `Cs*As + Cd`。该纹理被七组
`RD_SECTION{30,50,60}_TUNNELA_CH` 道路伴随层使用，源顶点 alpha 均为 255，
所以交界外观完全取决于纹理 alpha 和加法混合状态。

GTA 的模型 `additive` 标志在 packed/custom model 渲染路径中不能稳定复现该
方程，失效时遮罩会退化为普通源 alpha，遮罩的黑色高 alpha 一端因而成为横跨
道路的黑带。导出器现在逐赛道输出所有实际引用的 additive 内容纹理名，packed
资源附带 `effects/additive.fx`；`track_manager` 对这些精确纹理名执行
`SrcBlend=SrcAlpha, DestBlend=One, ZWrite=false`。规则来自 TPK blend 字段和材质
引用，不依赖赛道 ID、模型名或纹理名关键字。

## 动态物体穿过道路

30 条赛道当前生成 962 个带源物理定义的动态模型。审计显示它们的 HP2 碰撞
三角网格均为闭合流形；问题不是缺面。旧 COL 只包含三角面。GTA 的移动物体
窄相碰撞依赖 COL 球/盒 volume，因此会出现车辆能撞到精确网格、物体运动后却
穿过道路三角面的不一致行为。

导出器保留完整 HP2 三角 COL，并从同一局部碰撞包围范围增加一个 GTA primitive：

- 三轴半径比不超过 1.5 的近等轴物体使用外接球，保留风滚草一类物体的滚动；
- 其余物体使用局部 AABB；
- 任一轴总厚度最低为 0.10 m，避免薄路牌在一个物理步长内穿过路面；
- primitive 与 DFF、精确 COL 使用同一局部原点，未按名字或 track ID 分类。

最终 IMG 必须回读并同时含 `mesh_faces` 和至少一个 `boxes`/`spheres`，否则不能
视为通过。物理行为仍需在 MTA 客户端做撞击、落地、滚动和重新流送测试。

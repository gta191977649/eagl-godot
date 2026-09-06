# 动态道具导出支持（2026-09-05）

普通 MTA 导出与 packed/shared 已接入源物理绑定。已部署 packed 资源及其管理路径已更新。

源 34027 实例绑定决定动态分类，34026 参数决定配置身份；源 34022/34023/34025 邻接关系恢复实体碰撞面。不同物理参数的同一显示模型分成不同 definition。COL 顶点、重心和 DFF 使用相同缩放与原点重定位。动态对象禁止静态提升、空间切块及独立静态 LOD；混合材质保留在一个刚体中，独立 additive 渲染效果可能与源不同，报告明确列为限制。

definition 与 dynamic `<object>` placement 都输出 physicsRoot、simulated、frozen、breakable、respawn、mass、turnMass、airResistance、elasticity、buoyancy 和 centerOfMass；placement 另有 dynamic=true。重复字段使普通加载继续逐字段继承，也让直接实例化 XML row 的 packed 管理路径得到完整物理配置。所有动态物体都显式 simulated=true、frozen=false。breakable=true 会清除 custom object 的不可破坏登记；所选物理组的 damage effect 为 none，不会因此套用 GTA 的破碎模型。带 HP2 附件阈值的物体使用本地 object.dat/IDE 已核查的 noparkingsign1（1233）物理根；零阈值物体使用 barrel1（1218）。

首次 packed 部署暴露出运行时路径问题：`track_manager` 读取了 `<object dynamic="true">`，但旧调用只把位置和模型 ID 传给 EagleLoader 的 `streamObject`，导致 `streamElement` 收到 `overrides=nil`。这会把标签正确的 object 仍按静态模型物理创建。修复后 `track_manager` 传入原始 row 和 definition 所属资源；`streamObject` 只增加两个可选尾参数，并复用已有的 `getPlacementOverrides`、`mergePlacementOverrides`、创建前物理组设置和卸载恢复逻辑。旧调用签名保持兼容，没有另建动态物理实现。

物理组兼容基线取自已核查的本地 object.dat/IDE：有脱离阈值的对象采用 noparkingsign1（1233：mass 30、turnMass 50、airResistance .99、buoyancy 50），零脱离阈值采用 barrel1（1218：mass 50、turnMass 50、airResistance .99、buoyancy 50）。这些 GTA 参数会显式写入 definition，避免 custom model 依赖隐含默认值；它们是明确的 GTA 原生近似，不是伪装成 HP2 单位换算。elasticity 使用已确认的 HP2 恢复系数，centerOfMass 使用源重心变换。HP2 力臂脱离公式、摩擦、阻尼、风滚草二次阻力、运行时生成和效果状态机尚未实现。COL 表面暂用 0，未宣称源材质已映射。

packed 保持 DFF/TXD 几何共享，definition 身份额外包含源物理参数签名、COL、重心及运行状态。参数签名排除名称、模板 hash 和运行时指针，保留未知源参数，避免跨赛道同配置因名字不同重复保存，也避免不同物理共用模型组。缓存加入物理模块指纹。

验证：243 项测试通过、21 项按环境跳过；全部 30 条赛道的 576 条模板通过源碰撞面解码。当前五个 packed/shared 资源包含 331 个动态 definition 和 9668 个动态 `<object>` placement；动态 building 数量为 0。每个 placement 的 11 个物理字段均存在并与 definition 一致。离线验证不能替代实际客户端撞击测试。

后续正常运行普通导出或 family 导出即使用该逻辑。不要将本次支持描述为“全部 HP2 动态行为精确复现”。导出报告 dynamic_physics 保存每个模型的近似配置和未实现项。

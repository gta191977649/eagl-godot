# HP2 水坑反射与 LOD 修复

## 根因

HP2 赛道中实际存在两套水坑道路材质：Parkland 使用
`W_RDWATER`、`W_RDWATER02`、`W_DIRTWATER` 及遮罩；Alpine 使用
`RD_PUDDLE`、`RD_PUDDLE2` 及对应 `_MASK`。Desert、Mediterranean 和
Tropic 的道路材质中没有这套水坑 base/mask 结构。

此前导出器把名称含 `PUDDLE` 的 Alpine 材质改写为 `refl_*` 和
`reflmask_*`，而 Parkland 继续使用 Eagle Loader 的标准 `road_*`
材质路径。资源中没有消费前两种命名的反射处理，因此相同语义走了不同路径。
此外，混合和加法渲染层作为道路模型的 companion 输出时没有继承道路底层的
`lodParent`，会在远景切换时与底层失去同步。

## 历史修复（已由特殊贴图接口取代）

- 旧版曾按 TPK 名称把水坑归入 `road_*`；该规则现已删除，不能再作为分类依据。
- 当前实现仅按原生 `PUDDLE` / `MUD_PUDDLE` 面级碰撞材质和源 BLEND 材质证据
  生成独立 `refl_*` 变体。普通用途仍保持 `road_*`，共享像素不会跨用途合并。
- `refl_*` 的 DFF/definition 状态强制 opaque，不设置 `draw_last`、`additive`、
  `no_zbuffer_write`；TXD 仍原样保留源 alpha，交由 shader 使用。
- 同一道路切块的 base、blend 和 additive 高精度层共享同一个
  `lodParent` 和 `uniqueID`；远景只保留从不透明道路底层生成的简化 LOD。
- 没有修改 EagleLoader 源码。

## 覆盖与验证

- Parkland 11--16：78 个水坑模型实例，78 个有效 LOD 链接。
- Alpine 41--46：112 个水坑模型实例，112 个有效 LOD 链接。
- 原来的 190 个 LOD 链接统计仍是历史验证数据；当前反射贴图清单以
  `out/special_textures.md` 的全量重建结果为准。
- 30 条赛道的五个 packed/shared 资源通过离线引用验证。
- Python 测试结果：243 passed，21 skipped。
- 动态物体配置保持为 331 个 definition、9668 个 placement。

旧版资源曾部署至 `D:\dev\mta_hp2\mods\deathmatch\resources\[map]`；本页不再
代表当前特殊贴图命名契约，权威规则见 `hp2_special_texture_effects.md`。

以上为导出文件和离线加载契约验证；实际水面反射外观及 LOD 切换仍需在 MTA
客户端中从近景到远景观察确认。

# Track 25 MTA 道路错位修复

## 根因

MTA 导出器把 `RD_SECTION*` 当成静态流送几何，同时跳过对应的 scenery placement，始终使用 `MeshObject.transform`。这混淆了输出模型的流送类型与源模型的世界变换来源。

Track 25 的 SECTION10 / SECTION20 共 12 个道路对象保留了 `0.39369997382164` 的对象缩放，但场景实例矩阵为单位矩阵。GLB 的 `--with-placement` 用实例矩阵替换对象矩阵；旧 MTA 使用对象矩阵，导致道路整体缩小并向原点偏移，离开地形预留的道路位置。截图中的青色区域是暴露的背景。

| 原始道路 | 旧输出中的代表模型 | GLB 世界 Y 范围 | 旧 MTA 世界 Y 范围 |
| --- | --- | --- | --- |
| RD_SECTION10_CHOP3 | t25_s_fa738761_01 | -431.40375 ～ -322.54999 | -169.84364 ～ -126.98792 |
| RD_SECTION10_CHOP2 | t25_s_40b210e6_02 | -326.09149 ～ 143.68526 | -128.38221 ～ 56.56888 |

这里的范围是原始道路全部分块的合并范围。两个点名 DFF 分别有 509 / 274 个三角形，全部朝上，顶点和材质 alpha 都为 255；相关路面 TXD 像素也全部不透明。不是这两个模型的 alpha 或反面剔除错误。

旧的三角形数量检查和全场景包围盒检查无法发现：错误缩放没有减少三角形，其他地形仍维持了全场景边界。

## 修复

- 道路按 `object_index` / `chunk_offset` 匹配实例，先按实例矩阵烘焙，再进行材质分类、切块、碰撞匹配及 LOD 生成；实例矩阵替换对象矩阵，不叠乘。
- 保留所有不同的有效放置；现有流送重复记录去重逻辑仍生效。没有实例的道路继续使用自身矩阵。
- 已放置的道路模板也进入道路导出流程，避免模板身份导致遗漏。
- 新增 `road_transforms` 报告：源偏移、采用的矩阵、是否替换对象矩阵、世界包围盒、输出模型及误差。暂存清单增加源对象身份和模型原点。
- 新增 `tools/audit_mta_glb.py`，直接读取 GLB 顶点和最终 IMG 中的 DFF，再应用 `.map` 放置，比较道路 XY 覆盖及三角形重心处的高度。

## 验证结果（2026-09-04）

- 参考 GLB：`map_tools_ps2/out/track25_diagnosis/TRACK25_reference.glb`，由现有 GLB 导出器使用 track 25 和 `--with-placement` 生成。
- 修复前：27 段道路中 12 段与 GLB 不符，集中在 SECTION10 / SECTION20。
- 修复后：27/27 通过；没有缺失的重心采样，最大高度误差约 0.00000199。最大单段 XY 缺失面积约 0.00259，为文件浮点量化的边界误差。
- LOD：按实际 `lodParent` 替换，有 LOD 的用 LOD，没有的保留 detail。27 段均保留覆盖，无缺失重心采样；简化后的最大高度偏差约 0.1541，使用显式 0.2 的 LOD 高度容差。此项不代表 LOD 与高精度模型逐顶点相同。
- DragonFF 最终 DFF/COL/TXD 回读成功，缺失 DFF/COL 列表及 warnings 为空。
- `test_mta_export.py`、`test_glb_writer_topology.py`、`test_managed_export.py` 共 87 项通过。新增回归测试直接读取 GLB POSITION accessor 对照 MTA，覆盖旋转/平移、对象缩放替换、重复实例、不同有效放置、同名不同对象及无实例回退。
- 检查 track 11、21、31、41、61 的源道路实例：对象矩阵与放置矩阵全部一致，本次变换修复不改变这些道路的坐标。未声称已逐一重新导出这些赛道。
- Eagle 编辑器已实际加载新资源，机库周边原先露出背景的地面与道路可见。未修改编辑器；未在 MTA 游戏中执行验收。

## 输出与复现

修复资源：`map_tools_ps2/out/mta_desert_25_verified`。旧的 `mta_dessert_25` 与 MTA resources 目录未被覆盖。道路恢复世界尺寸后会重新切块，因此不应只替换两个旧 DFF；应加载完整新资源。

详细审计：`map_tools_ps2/out/track25_diagnosis/{before_glb_audit,after_glb_audit,lod_glb_audit}.json`。

在 `map_tools_ps2` 中执行：

```powershell
.\.venv\Scripts\python.exe tools\audit_mta_glb.py `
  out\track25_diagnosis\TRACK25_reference.glb out\mta_desert_25_verified `
  --dragonff "C:\Users\nurupo\AppData\Roaming\Blender Foundation\Blender\4.5\extensions\blender_org\dragonff" `
  --output out\track25_diagnosis\after_glb_audit.json
```

追加 `--lod --height-tolerance 0.2` 可检查实际 LOD 引用。该审计工具针对本导出器烘焙世界坐标的三角形 GLB 和 MTA 道路，并非通用 GLB/DFF 比较器。

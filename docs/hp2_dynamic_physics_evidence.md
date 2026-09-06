# HP2 PS2 动态物体：源证据与实现进度

状态：**源绑定解析、物理状态去重保护已实现；GTA 映射、实体 COL 转换和游戏验收未完成。** 根据用户要求，本次新增的 EagleLoader 显式唤醒控制已撤回，优先使用现有标准接口与资源侧配置。本文不是动态资源验收报告。

## 实际数据链

原方案中的 `0x34102` 不是物理描述表。`SLUS_203.62` 的代码表明，信息记录 `+0x0c/+0x0e/+0x10` 是三个 LOD 阈值，不能作为碰撞索引或动态标记。

实际关联如下：

```
0x34027 (8 bytes: uint32 physics_hash, int16 section_id, int16 instance_index)
  -> 0x34101 对齐结构 +8 的运行时分区 ID（不是 Python 枚举下标）
  -> 0x34103 中 48-byte 实例记录
  -> 实例 +0x0c 的 0x34102 信息表下标 -> 三个模型哈希

physics_hash
  -> 0x34026 中 224-byte 对齐物理描述，+0x70 同一哈希
  -> 0x80034020 下 0x34021 对齐碰撞头，+0x30 同一哈希
  -> 0x34024 顶点及其余碰撞拓扑块
```

`0x34026/0x34021/0x34101/0x34103` 的结构起点要按文件偏移向上对齐 16 字节。`0x34027` 从 payload 起点读取，**不能**套用该对齐规则。前三个模型哈希、名称前缀和 visibility_flags 均未用于物理分类。

## 可复现的 ELF 证据

可执行文件：`D:\ps2_game\SLUS_203.62`

SHA256：`7335b8ed479481082c648958f4b5be4da65b74d042d0ab2f5237df801eafacc2`

| 地址 | 直接观察 |
|---|---|
| `0x14ed48` | 用 34101 对齐结构 +8 建立运行时分区表 |
| `0x14ffc4` 起 | 读取 34102 的有符号 16 位阈值，选择 LOD 模型指针 |
| `0x21f080` | 分派 34026，对齐后按 `0xe0` 步长加载 |
| `0x21f198` | 34027 从 payload 开始，记录数为 size / 8 |
| `0x21f2a4/0x21f2bc` | 绑定记录 +4 选分区，+6 选 48-byte 实例 |
| `0x21f8f8` | 按物理描述 +0x70 的哈希查找模板 |
| `0x220498` | 物理描述 +0x20 传入刚体创建函数 |
| `0x19cc6c..80` | 参数首个 float 存到刚体 mass，倒数存到 inverse mass |
| `0x2204e4..ec` | 描述 +0x70 作为碰撞查询键，+0xa0 作为碰撞参考偏移传入 |
| `0x219090..98` | 碰撞头 +0x30 与查询键比较 |
| `0x220558/0x221370` | 描述 +0xb4 初始化受撞脱离阈值；碰撞处理读取并比较 |
| `0x221468` | 脱离后阈值清零；不能将创建时唤醒等同于启用物理 |
| `0x220d4c..70` | HP2 本身对 `0x98c6023c` 等模型有额外运动分支 |

证据生成器保存每条指令的地址、原始字节及通用 MIPS 解码。通用 Capstone 不完整支持 R5900，EE/VU 指令保留原始字节，不能把它们误读为 `bbit` 指令后继续推导。

## Track 25 的三个示例

| 输出模型 | 源模型哈希 | 物理模板 | 模板记录偏移 | 碰撞头偏移 | 原始绑定数 |
|---|---|---|---|---|---:|
| t25_p_7b37f4a7 | 6425d644 | CS_STREETSIGN_A | 0x5be30 | 0x47b40 | 2 |
| t25_p_364277b6 | f770a534 | CS_STREETSIGN_C | 0x5bff0 | 0x49cc0 | 94 |
| t25_p_2f133ebb | 98c6023c | CS_Tumbleweed_A_M | 0x5c530 | 0x53910 | 29 |

这些是文件中的绑定记录数，包含流送重叠，不是最终独立实例数量。

两种路牌的 mass 原始值约为 `0.005`，脱离阈值约为 `0.2`；风滚草分别约为 `0.1` 和 `0`。mass 字段语义已确认，**单位还没有确认，不能据此宣称分别为 5 kg 和 100 kg**。GTA object.dat 明确使用 kg，但这并不能证明 HP2 的转换比例。

碰撞模板分别有 8、9、12 个源顶点。风滚草的原碰撞数据有三维体积，不能用可视透明贴片替代。当前解析器保存原顶点；尚未转换其拓扑，因此没有宣称已产生实体 COL。

## 全 30 条赛道审计

| 家族 | 赛道数 | 模板记录数 | 物理绑定记录数 |
|---|---:|---:|---:|
| Parkland | 6 | 162 | 2508 |
| Desert | 6 | 198 | 4888 |
| Mediterranean | 6 | 78 | 306 |
| Alpine | 6 | 54 | 938 |
| Tropical | 6 | 84 | 1028 |
| 合计 | 30 | 576 | 9668 |

扫描没有记录步长、分区/实例/信息下标越界或缺失物理模板错误。统计尚未进行跨赛道模板去重。每赛道 JSON 包含源路径、SHA256、模板原始 224 字节、记录偏移、碰撞头关联、顶点、模型哈希及未支持项。所有 GTA 类别仍标记为未映射，`verified_gta_categories` 为空。

输出目录：`D:\dev\eagl-godot\map_tools_ps2\out\physics_source_audit`

## 已写入工作区的改动

- `source_physics.py`：独立源解析及报告；接入 Scene，使普通与 packed 构建均能携带源诊断。
- `mta_scene.py`：源实例去重键加入物理绑定状态。相同几何/放置但不同绑定、或未解析绑定与静态实例，不再提前合并。
- `managed_export.py`：缓存指纹包含物理解析器，避免读回缺少诊断的新旧混合缓存。
- EagleLoader：本次新增的 `wakeOnCreate` 源码及专用测试已撤回。后续优先使用现有 definition、physicsRoot 和 object 创建接口；现有接口不足的行为必须明确记录限制，不能宣称已实现。

这**尚未**实现独立刚体的模型变体键、共享物理 definition、动态 COL、LOD 排除和 track_manager 全路径物理接入。没有重导出并交付五个可验收的 packed 家族，没有覆盖正在使用的资源目录，也没有在游戏里完成撞飞/滚动验收。

## 验证与复现

在 `D:\dev\eagl-godot\map_tools_ps2` 下运行：

```powershell
.venv\Scripts\python.exe tools\audit_source_physics.py D:\ps2_game\GAME\ZZDATA\TRACKS out\physics_source_audit
.venv\Scripts\python.exe tools\audit_physics_elf.py D:\ps2_game\SLUS_203.62 out\physics_source_audit\elf_evidence.json
.venv\Scripts\python.exe -m pytest tests/test_source_physics.py tests/test_mta_export.py tests/test_managed_export.py -q
```

ELF 工具单独需要 `pyelftools` 和 `capstone`；普通解析/导出不依赖它们。

解析/去重与现有导出测试共 93 项通过。此前显式唤醒改动的四项 Lua 测试随改动一并撤回，不计入当前实现的验证结果。离线测试不能代替 GTA 游戏验收。

## 后续映射必须保留的边界

1. 源物理分类来自 34027→34026，碰撞体来自同哈希的 34021；不要回退到模型名称相似度。
2. 继续确认质量单位、矩阵是惯量还是逆惯量、+0xa0 与模型重心/碰撞重定位的完整契约。
3. GTA 的物理组含 uproot_limit、damage_effect、special_col_response；每物体接口只提供六类物理参数。不能通过设置质量替代物理组，也不能将破碎与脱离混为一谈。
4. 若使用近似体或 GTA 兼容类别，应明确记录近似来源、被省略的参数与行为；不能以任意 donor 的质量冒充 HP2 换算结果。

接口依据：[物理组属性](https://wiki.multitheftauto.com/wiki/EngineGetObjectGroupPhysicalProperty)、[每物体属性](https://wiki.multitheftauto.com/wiki/SetObjectProperty)。

# Apple 本地模型模拟器可行性闸门

> Issue: #37
> 日期: 2026-08-04
> 状态: 延期（不阻塞 BYOK）

## 结论

在当前 iOS 26 模拟器与工程依赖下，**无法稳定验证** Apple 本地模型的选择、结构化纪要生成、超时/取消与恢复流程。
因此 **不把 Apple 本地模型纳入 MVP 主链路**。BYOK 仍是唯一发布路径。

## 探测结果

应用内 `AppleLocalModelGate.probe()` 在模拟器返回：

- `availability`: `environmentInsufficient`
- `blocksBYOK`: `false`
- 说明：模拟器无法作为 Apple on-device structured minutes 的验收环境

真机探测在本闸门中保持 `unavailable`（产品未启用该 Provider），避免误导用户。

## 解除条件（进入开发前必须满足）

1. 模拟器可稳定检测模型可用性；
2. 可在模拟器完成最小文本生成、超时、取消；
3. 选择与失败路径可自动化测试；
4. 不改变 BYOK / 文件主权边界。

## 影响

- 不阻塞 #36 BYOK 厂商预设与后续发布。
- #42 回归不把本地模型作为必过项。

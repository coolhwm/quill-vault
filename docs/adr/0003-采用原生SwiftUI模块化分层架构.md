---
status: accepted
---

# 采用原生 SwiftUI 模块化分层架构

Quillvault MVP 采用 SwiftUI、Observation 与 Swift Concurrency 构建模块化单体，通过仓库内的本地 Swift Packages 划分 App、Features、Domain、Application、Infrastructure、DesignSystem 与 TestingSupport。依赖方向为 Presentation → Application → Domain ← Infrastructure，业务状态机和副作用不得放入 View；每个 Feature、类型与文件保持聚焦职责，并由 App 组合根完成依赖组装。项目不使用 TCA 作为全局架构框架，以避免长期架构锁定和额外概念成本；复杂的录音与纪要恢复由可独立测试的领域状态机和用例承担。

## ADDED Requirements

### Requirement: Journal 在文件副作用前持久化意图
Core SHALL 使用系统 SQLite3 的 WAL、foreign keys 和 `synchronous=FULL` journal，默认路径为 `~/Library/Application Support/Rascal/Operations/operations.sqlite`。RW journal打开前 MUST取得同目录的process-exclusive advisory lock并生成owner epoch；锁失败进入只读safe mode。Journal MUST由单进程、单actor-owned connection独占，禁止并发writer/checkpoint；每次打开连接 MUST查询确认PRAGMA值并记录 `sqlite3_libversion()`。Operations、items、receipts、append-only events及每个filesystem effect的intent/result MUST在对应durable boundary前后以可恢复顺序提交；journal write/fsync failure MUST阻止后续破坏性动作。

#### Scenario: 首次 journal 写失败
- **WHEN** operation intent 无法 durable persist
- **THEN** Core 返回 `journalFailure`，不创建 staging、不改变 destination 且不删除 source

#### Scenario: 提交事件写失败
- **WHEN** destination 已提交但完成事件无法 durable persist
- **THEN** operation 进入 `recoveryRequired` 或 `partialCommit`，不得报告 completed

#### Scenario: WAL 恢复检查
- **WHEN** service 在 crash 后重新打开 journal
- **THEN** 它把 sqlite、wal、shm 作为同一恢复集合，并同时运行 schema migration、integrity check 与 foreign-key check

#### Scenario: 第二进程争用 Journal
- **WHEN** 另一个 Rascal实例或helper尝试以RW打开同一journal而owner lock仍有效
- **THEN** 第二个service进入只读safe mode，不创建第二个active queue、writer或sequence owner

### Requirement: Journal owner lease 对旧进程与旧 action 做 fencing
RW owner lease MUST使用journal同目录、directory-FD anchored且`O_NOFOLLOW|O_CLOEXEC`
打开的固定lock file，并以nonblocking process-exclusive advisory lock从SQLite打开前持有到
connection关闭后；helper不得继承lease FD。成功取得lease后 MUST生成新owner epoch并在首个
journal事务持久化。每个effect intent、attempt和recovery action MUST绑定owner epoch。
action进入snapshot时 MUST以`offered`状态与当前epoch同事务持久化。新owner不得继续执行
旧epoch action或把旧ActionID重绑新epoch；它只能以当前epoch新ActionID重新签发且绑定已
检查旧effect的recovery action收敛。公开`RecoveryCommand`不新增epoch字段，service MUST
通过ActionID查询durable epoch并在filesystem effect前内部校验。

#### Scenario: Owner 被 SIGKILL 后接管
- **WHEN** 第一owner在持有lock时被SIGKILL，第二进程随后取得OS已释放的lock
- **THEN** 第二进程生成不同epoch，枚举旧journal并进入恢复；任一旧epoch action返回无副作用`controlRejected`，仍有效能力以新ActionID重新签发

#### Scenario: Helper 继承 lock FD
- **WHEN** CrashProbe启动helper并检查其open file descriptors
- **THEN** helper不持有owner lease FD；若`FD_CLOEXEC`或继承检查失败，owner进入safe mode且不执行filesystem effect

### Requirement: SQLite schema 与 migration 不允许隐式兼容
M3 schema v1 SHALL使用design中规范性SQLite表合同的PK/FK/UNIQUE/CHECK/index、
versioned canonical envelope及事务归组。已存在journal MUST在任何RW open、WAL切换或
migration前以只读connection预检`user_version`、完整canonical `sqlite_master` DDL全集、
所有canonical envelope及normalized row/blob一致性，并枚举完整恢复集合。首次建库只能执行原子
`PRAGMA user_version 0 → 1`；0但含未知user table、future version、DDL不匹配、
未知envelope、migration失败或任何孤儿FK MUST进入全局只读safe mode。只有不存在文件或
只读预检确认的空v0可进入建表migration；其他拒绝不得改写、删除、重建或跳过未知记录来
“修复”journal。Admission、event projection、effect intent、
effect result/summary receipt分别按design规定在单一transaction提交。新owner epoch只能在
只读预检及RW integrity/FK/再次全量decode均成功后注册；任何拒绝路径不得改变epoch、
checkpoint、action或sqlite/wal/shm恢复集合。

#### Scenario: Future schema
- **WHEN** service打开`user_version > 1`或含未知envelope version的journal
- **THEN** service拒绝RW/migration，保留sqlite/wal/shm及用户对象原样，不尝试降级读取后继续mutation

#### Scenario: Effect/result 孤儿
- **WHEN** migration fixture含无对应item/effect的result或receipt
- **THEN** `foreign_key_check`或decoder使整个service safe mode，不把孤儿记录忽略后启动queue

#### Scenario: DDL 或双表示被弱化
- **WHEN** fixture删除一个FK/CHECK/UNIQUE、改变index列序、增加trigger/view，或使normalized列与canonical blob不一致
- **THEN** 只读预检拒绝RW且journal/user object零mutation，不得因表名/索引名仍存在而接受

#### Scenario: Unknown envelope 不写 owner
- **WHEN** v1 journal含未知envelope version或无法枚举的action/effect
- **THEN** service在注册新owner epoch前进入safe mode，sqlite/wal/shm及恢复集合字节保持不变

### Requirement: Journal 数据可审计并受保守保留规则约束
Journal SHALL为每个operation保存ID、kind、state、request、latest sequence、owner epoch、时间和terminal error；每个item保存source/destination、opaque identity、state、staging/quarantine URL、进度和verification；单item receipt保存单调summary projection，commit identity/backup不可换绑，cleanup只可在purge result后从pending单向更新为complete并清空已不存在的quarantine URL；1:N append-only effect intent与immutable result保存backup、commit、source quarantine和逐节点purge的identity；event使用append-only sequence/payload。未完成、`recoveryRequired`、`cleanupRequired`和source-retained pending记录 MUST永不自动清除。safe terminal以transition的`updated_ms`计龄：29天和恰好30天保留，超过30天可删；另外按`updated_ms DESC, operation_id DESC`只保留最新100个safe terminal，两个候选集合取并集，但unresolved记录不计数且永不成为候选。Clear忽略龄期/数量但使用同一safe-terminal谓词。Retention/Clear MUST在写事务中二次重验整批候选仍无pending effect/action后才按operation级联删除；不得单独修剪event/effect/manifest证据。safe-terminal龄期固定为terminal transition时间，后续附属action更新时间不得刷新；任一无result或非completed result及任一offered/selected action均阻止删除。Replace的immutable backup URL可作为历史证据保留，但只有匹配的purgeBackup completed result与finalize action completed共同证明backup已处置后，operation才可进入普通safe-terminal删除集合。

#### Scenario: 清理历史记录
- **WHEN** 用户执行 Clear 且 journal 同时含 completed 与 recoveryRequired operations
- **THEN** 只有符合保留规则的终态记录可删除，recoveryRequired 及其 receipts/events 保持完整

#### Scenario: 29/30/31 天边界
- **WHEN** 三个safe terminal分别在29天、恰好30天和31天前终结
- **THEN** 前两个保留，31天记录可成为候选；若事务重验发现pending effect则仍不得删除

#### Scenario: 99/100/101 上限
- **WHEN** journal分别含99、100、101个safe terminal并混入任意数量unresolved operation
- **THEN** 99/100不因数量删除，101只使排序最老的safe terminal成为数量候选；unresolved不计数且全部保留

#### Scenario: Offered action 与已完成 backup purge
- **WHEN** 一个terminal operation仍有offered action，另一个replace已有durable purgeBackup result及completed finalize action
- **THEN** 前者永不成为候选；后者虽保留immutable backup URL历史证据，仍可按普通terminal龄期/数量规则成为候选

### Requirement: Journal 损坏时禁止猜测磁盘状态
SQLite 打开、integrity、schema migration 或记录解码无法给出唯一状态时，Core SHALL 进入 `recoveryRequired` 并禁用自动覆盖、source delete、backup delete 和 staging delete。恢复 UI MUST 给出只读检查和安全动作，不得把未知状态当作未开始或完成。

#### Scenario: 截断 journal
- **WHEN** 测试以截断或不一致记录重启 service
- **THEN** Core 不自动删除任何 source、destination、backup 或 staging，并报告 recoveryRequired

#### Scenario: 无法枚举 Operation
- **WHEN** journal 全局损坏到无法可靠发现 operation IDs
- **THEN** service 进入全局只读 safe mode，拒绝所有新 mutation，而不是构造一个虚假的单 operation 状态

### Requirement: 跨卷 move 强制完整内容验证
跨卷 move SHALL 复用 staged copy，但 verification policy MUST 强制提升为 `.sha256`，调用方不得降低。只有 source/staging SHA-256、结构和 required metadata 验证完成且 destination exclusive commit 持久记录后，Core 才可进入 source cleanup。

#### Scenario: 调用方请求 structural move
- **WHEN** 跨卷 move 请求提供 `.structural`
- **THEN** service 自动提升为 `.sha256` 并在 snapshot/receipt 中记录有效策略

#### Scenario: Digest 不匹配
- **WHEN** 跨卷 move verification 得到不同 digest
- **THEN** destination 不提交、source 不删除，并返回 `verificationMismatch`

### Requirement: Source cleanup 是独立且不可误报的阶段
Destination receipt durable后，cross-volume move SHALL先进入 `committedAwaitingCleanup`。未取消时，Core MUST先写durable quarantine intent，再在source卷以directory-FD/no-follow、exclusive same-volume rename把顶层source移入operation-owned quarantine；effect返回后核对quarantine identity并写result。身份不匹配 MUST停止且不得purge。随后按冻结manifest的稳定NodeID与leaf-to-root `purge_ordinal`逐节点purge；symlink只操作link，hard-link按directory entry记录，每个node/root各有独立intent/result及三ACK并在`unlinkat`前以同一parent FD重验identity。Manifest外child、type/identity/parent变化均停止自动删除。`ENOENT`本身不得表示成功，必须结合parent identity、manifest与已有result只读检查后得到唯一结论。任意失败进入 `cleanupRequired`/`recoveryRequired`，可幂等重试但不得映射为completed。无法提供安全quarantine语义的adapter MUST禁用cross-volume directory/package move。quarantine rename返回后 MUST从anchored destination parent重读并严格比较expected object；任何purge intent前 MUST先完成整个quarantine root的no-follow child集合、parent NodeID及canonical manifest/digest预检，不能先删除已知node后才由root ENOTEMPTY发现unexpected child。

#### Scenario: Source delete 权限失败
- **WHEN** 已提交 move 的 source quarantine rename或后续purge返回EACCES
- **THEN** destination完整，source仍在原路径或已登记quarantine，effect ledger记录精确阶段，状态为cleanupRequired

#### Scenario: Source path 被替换
- **WHEN** identity recheck后、quarantine rename竞态中source path被替换，或quarantine结果identity不符
- **THEN** Core不purge该对象，保留原路径/quarantine现状并进入recoveryRequired

#### Scenario: 目录 Purge 中途崩溃
- **WHEN** 第N个manifest node删除后、effect receipt前进程被SIGKILL
- **THEN** committed destination保持完整；重启只根据node effect ledger与identity继续或进入recoveryRequired，不删除unexpected child

#### Scenario: Quarantine 出现 unexpected child
- **WHEN** purge前或中途在quarantine目录加入manifest外child、替换symlink或改变parent identity
- **THEN** Core停止后续purge并进入recoveryRequired，不删除unexpected child、替换对象或其target

#### Scenario: Node 路径已不存在
- **WHEN** unresolved node intent重启后按relative path得到ENOENT
- **THEN** Core不直接记completed；只有同一parent/NodeID证据能唯一证明既有effect完成时才补result，否则保持recoveryRequired

#### Scenario: Rename 最后重验后对象被替换
- **WHEN** source/staging在最后一次pre-syscall identity检查后被swap，或quarantine后对象内容/manifest改变
- **THEN** post-rename anchored identity与purge前完整manifest重验阻止completed/purge，operation进入recoveryRequired且不误删替换对象

### Requirement: Replace 在新内容就绪前保持旧目标
Replace SHALL是destination commit strategy而不是source disposition。Standalone `kind.replace`定义为source-retaining replacement；`copy + conflictPolicy.replace`永不cleanup source；`move + conflictPolicy.replace`只有durable replacement receipt后才进入source quarantine/cleanup。Replace MUST在destination卷完成新内容staging、metadata和验证后才进入commit，并先把旧目标保存在operation-owned同卷recovery area。若adapter使用backup rename + final rename而非已验证swap，则每个effect分别写intent/identity/result；旧destination在第一个commit effect开始前保持原路径和内容不变。Replace默认采用source metadata。Replacement commit后backup MUST继续保留，直到当前epoch签发的`finalizeKnownCommit`重验final/backup identity并以独立`purgeBackup` effect收敛，或`restoreBackup`按ledger恢复；不得在terminal projection或普通Clear中隐式删除backup。

Replacement commit与summary receipt durable后，item与operation MUST先投影为
`recoveryRequired`，snapshot MUST同时提供当前owner epoch新签发的
`finalizeKnownCommit`和`restoreBackup`；未处置backup时不得投影为`completed`。
任一进程重启后的恢复准备 MUST仅从durable effect intent/result、manifest与summary
receipt重建，不得依赖前一进程的workspace registry。若这些持久事实不足以唯一重建
final、backup、staging、quarantine或recovery-area identity，Core MUST保持
`recoveryRequired`且不执行filesystem effect。
启动时 MUST联合reconcile snapshot与effect ledger，覆盖`sourceQuarantining`及所有真实
effect中间态；若operation不可由scheduler自动收敛，snapshot必须有当前epoch且由durable事实
可执行的ActionID。七类action不得在restart后重新plan，不能以合成effect harness替代真实
move/replace W1/W2/W3 action reachability。

#### Scenario: Replace 复制失败
- **WHEN** 新内容 staging 或 verification 失败
- **THEN** 旧 destination 仍在原路径且内容不变，不产生虚假的 replace completed

#### Scenario: Replace commit 后崩溃
- **WHEN** 新 destination 已公开但进程在写 terminal event 前被 SIGKILL
- **THEN** 重启后 journal/receipt 能识别新对象和 backup，结果为可恢复状态而非重复替换

#### Scenario: Copy 与 Move 的 Replace Source 语义
- **WHEN** 两个请求分别以copy+replace和move+replace提交相同形状的source/destination
- **THEN** copy完成后source保留；move仅在replacement receipt durable后进入source quarantine，二者不得共享含糊的delete行为

#### Scenario: Finalize 时 backup identity 改变
- **WHEN** replacement receipt已durable但`finalizeKnownCommit`前backup被替换或出现unexpected child
- **THEN** Core不purge该backup并进入recoveryRequired；final destination保持完整

#### Scenario: Restore backup 重复提交
- **WHEN**同一ActionID的`restoreBackup`在effect返回或result durable窗口后被重复调用
- **THEN** effect ledger与identity检查只允许一次namespace mutation，第二次返回同一结果或无副作用

#### Scenario: Replace receipt ACK 后重启
- **WHEN** replacement result/summary receipt已durable且backup仍存在，但进程在签发finalize/restore前被SIGKILL
- **THEN** 重启投影为recoveryRequired并以新epoch签发双action，不得由receipt projection直接变为completed

### Requirement: Durable failpoint 的恢复结果有限且可解释
每个 destructive effect SHALL使用design冻结的十类effect inventory与精确三ACK：
durable intent事务COMMIT并read-back后/effect前、effect返回后/任何result写入前、
result/summary receipt事务COMMIT并read-back后/下一effect前。ACK MUST绑定scenario/run nonce、
operation/item/effect ID、kind、ordinal、owner epoch与journal sequence；driver只可在全部字段精确匹配
且本run首次出现后SIGKILL，stale/duplicate/提前ACK均失败。SIGKILL后重启，
`recoveryRequired`只表示无法自动选择动作，不能豁免filesystem最低不变量：final永不partial；
Replace在任何时刻至少有一个identity已验证的完整old/new副本位于final/backup/registered staging；
Move quarantine前source与committed destination均完整，quarantine/purge开始后committed destination
始终完整。任何silent partial、验证前删源、旧目标提前消失、完整副本全失或错误completed
SHALL使该写通道停止启用。

#### Scenario: 每个边界崩溃矩阵
- **WHEN** crash probe 在 plan、staging、data、metadata、verify、backup、commit、source cleanup 与 terminal persist 边界逐一被 SIGKILL
- **THEN** design冻结的10个effect × 3个窗口共30个stable sub-ID全部执行且无skip，每个满足对应filesystem predicate，并且重复resume/rollback不产生额外覆盖或删除

### Requirement: 同卷 move/rename 使用相同 receipt 和身份校验
同卷 move/rename MAY 使用文件系统原子 rename，但 SHALL 经过同一 request validation、identity recheck、journal、receipt、typed error 和 recovery contract；不得因快捷路径绕过 operation service。

#### Scenario: 同卷 rename 目标竞态
- **WHEN** preflight 后 destination 被另一个进程创建
- **THEN** operation 不覆盖该对象，并返回 destinationChanged/conflict

### Requirement: M3 不提前切换正式 UI
M3 SHALL 实现并验证 journal、move、replace 和 crash recovery，但正式 UI 的 move/replace 写入能力 MUST 保持禁用，直到 M4 的单引擎路由、活动 UI 和旁路扫描全部通过。

#### Scenario: M3 Core 测试通过但 M4 未完成
- **WHEN** 正式构建启动
- **THEN** 用户仍不能通过 UI 进入尚未切换完成的 move/replace 路径

# 整合开发容量处理记录

## 当前结论

已按用户确认删除两个ThinLTO缓存及旧151 obj/gen，范围已结束。当前系统重要用途可用容量至少30GiB、直接空闲至少8GiB；LLD新增目录另设3GiB预算，持续监测。15GiB历史策略另存，未改旧构建报告。容量读取10项正常、边界及临时文件竞态测试通过；没有追加清理。

## 容量口径复核（历史）

用户指出系统仍显示100多GB可用后，使用磁盘工具只读核对实际项目所在的Data卷（disk3s5、`/System/Volumes/Data`）：可用123.98GB，其中102.71GB可清除，未使用21.27GB。以上为界面显示的十进制GB与当时快照；不是不同硬盘，也不是GB/GiB换算造成的差距。macOS可按需释放可清除空间，不能将全部可用容量说成只有约20GiB；也不能将可清除空间当作已经释放的空闲空间。

当前两个构建驱动使用`shutil.disk_usage(...).free`检查30GiB直接空闲底线，因此仍会停止。该底线是本任务的保守余量设置，不是实测证明剩余构建需要超过100GB。此前以这一检查直接推导“必须继续删除旧151对象目录”不充分；新增清理方案暂停，未获准也未执行。此次复核未修改构建门槛，未恢复编译。

口径说明见[Apple磁盘工具文档](https://support.apple.com/guide/disk-utility/get-detailed-information-about-a-disk-dskutl1005/mac)。

原清单两个ThinLTO缓存已获用户确认并删除，均验证不存在。清理前可用空间已从上轮29.3GiB降到17.07GiB；清理后约20.03GiB，净增加约2.96GiB，仍低于30GiB构建底线。实际余量同时受文件系统共享块和其他应用写入影响，未将已分配大小冒充实际回收量。

## 已完成范围

| 精确目录 | 删除前已分配空间 |
|---|---:|
| `/Users/lazy/Projects/GCSA-aegis-build/macos/src/out/AegisRelease/thinlto-cache` | 2.34 GiB |
| `/Users/lazy/Projects/GCSA-aegis-build/upstream-candidate/src/out/AegisRelease/thinlto-cache` | 1.96 GiB |

执行前核对真实路径、文件数量与大小，确认无编译进程，并取得构建锁。执行结果见 `.artifacts/integration-20260915/cleanup-result.json`。源码、固定037App、旧包及配套Profile、测试二进制与验证记录保留；没有启动新构建。

## 后续获准并完成的范围（以下为原提案）

以下两目录尚未获准或删除，位于旧Chromium151构建目录，不是当前153候选目录：

| 精确目录 | 已分配空间 |
|---|---:|
| `/Users/lazy/Projects/GCSA-aegis-build/macos/src/out/AegisRelease/obj` | 9.63 GiB |
| `/Users/lazy/Projects/GCSA-aegis-build/macos/src/out/AegisRelease/gen` | 2.50 GiB |

合计约12.13GiB。删除后旧151再次编译需重新生成对象和中间文件，耗时会增加；源码、现有App、Profile、测试二进制、失败和签名证据保留。只读清单见 `.artifacts/integration-20260915/cleanup-proposal-151-intermediates.json`。实际回收仍须复测，达到30GiB后才恢复040及Linux漏洞回归。

上一次“允许”只覆盖两个ThinLTO缓存，未覆盖本次两个新增目录。[维护流程](../chromium-upstream-maintenance.zh-CN.md)规定：“空间不足时保留候选和准确失败原因，不自动删除 out、源码、依赖、用户资料或旧证据。”因此新增范围仍需确认。

用户随后要求继续。新增只读容量检查使用CoreFoundation重要用途属性，不安装依赖、不请求清理；系统可用至少30GiB，同时直接空闲至少15GiB，串行构建并持续复测。系统属性失败时只用直接空闲，仍要求30GiB。7项边界/失败/恢复测试、正常/错误路径/恢复CLI实跑与quality:fast均通过。Linux已恢复，旧失败记录保留为attempt5；Mac SDK查询因未接受Xcode许可退出69，用户已收到本机处理提示，未绕过许可或启动040。证据见capacity-policy.json、capacity-cli-tests.json、capacity-quality-fast.log与xcode-preflight.json。新增清理方案不执行。

结果：双容量检查支持本次Linux V8构建完成，未触发空间保护，未追加删除。两项原始漏洞测试直接执行通过；当前Mac阻断为Xcode SDK许可与旧SDK路径失效，不再笼统记为容量不足。

用户明确允许清理旧151 obj/gen后，重新核对精确路径与已分配大小、无编译进程，并取得两输出构建锁和候选测试锁后删除；两目录均已不存在。实际净回收7914070016字节（约7.37GiB），直接空闲约21.05GiB，系统重要用途约113.43GiB，双容量检查通过。差异不是将目录大小当作净回收；证据cleanup-151-result.json。未删除其他目录，随后启动带输入冻结/产物绑定流程的040构建，尚未记为通过。

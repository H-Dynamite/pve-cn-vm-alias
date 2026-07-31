# PVE 中文虚拟机别名补丁

在不改变 Proxmox VE 虚拟机或容器真实名称的前提下，让左侧资源树优先显示“备注”的第一行，因此可以用中文作为管理界面的显示别名。

例如：

```text
真实名称：windows7
备注首行：财务部 Windows 7
资源树显示：100（财务部 Windows 7）
```

## 为什么不直接允许中文名称

PVE 将 QEMU 虚拟机的 `name` 和 LXC 容器的 `hostname` 作为系统标识使用，并按 DNS 名称规则校验。直接解除中文校验可能影响 API、DNS、迁移、备份及第三方自动化。

本补丁不修改名称校验，而是将“内部名称”和“界面显示名称”分开：

- 英文名称仍作为稳定的系统标识；
- 备注第一行仅作为资源树中的显示别名；
- 没有备注时继续显示原名称；
- 完整备注仍可用于记录 IP、负责人和用途等信息。

## 实现原理

### 后端

PVE 9.2.2 会将备注的每一行编码后写到 VM/CT 配置文件顶部：

```text
#%E8%B4%A2%E5%8A%A1%E9%83%A8%20Windows%207
```

补丁修改：

```text
/usr/share/perl5/PVE/API2/Cluster.pm
```

处理过程：

1. `/cluster/resources` 完成 `VM.Audit` 权限检查；
2. 根据资源所属节点、类型和 VMID 定位配置文件；
3. 使用 PVE 自带的 `file_read_firstline()` 读取第一行；
4. 仅接受以 `#` 开头的备注行；
5. 使用 PVE 自带的 `decode_text()` 解码；
6. 在 API 结果中增加可选的 `description` 字段。

配置路径包含节点名，因此不仅适用于单节点：

```text
/etc/pve/nodes/<节点>/<qemu-server|lxc>/<VMID>.conf
```

备注读取发生在权限检查之后，不会向无 `VM.Audit` 权限的用户泄露内容。

### 前端

补丁修改：

```text
/usr/share/pve-manager/js/pvemanagerlib.js
```

主要变化：

1. 在 `PVE.data.ResourceStore` 注册 `description` 字段；
2. VMID 优先排序时使用 `description || name`；
3. 名称优先排序时同样使用 `description || name`；
4. 只显示备注第一行；
5. 使用 `Ext.htmlEncode()` 转义文本，避免备注内容被当成 HTML。

## 兼容性

已基于以下版本的实际安装文件开发和验证：

```text
pve-manager 9.2.2
```

脚本不依赖固定 IP、节点名或 VMID，也不依赖固定文件哈希。其他 PVE 9.x 版本如果相关代码结构一致也可能适用；如果结构不同，脚本会因唯一匹配检查失败而自动恢复，不会继续盲目修改。

PVE 升级可能覆盖补丁。升级后应先确认新版本代码结构，不能假设旧补丁继续兼容。

## 安装

将脚本上传到 PVE：

```bash
scp install.sh root@<PVE地址>:/root/pve-cn-vm-alias-install.sh
```

在 PVE 上执行：

```bash
chmod +x /root/pve-cn-vm-alias-install.sh
/root/pve-cn-vm-alias-install.sh
```

默认文件位置：

```text
/usr/share/perl5/PVE/API2/Cluster.pm
/usr/share/pve-manager/js/pvemanagerlib.js
```

测试或特殊安装可通过环境变量覆盖：

```bash
CLUSTER_PM=/其他路径/Cluster.pm \
PVE_JS=/其他路径/pvemanagerlib.js \
BACKUP_ROOT=/其他备份目录 \
./pve-cn-vm-alias-install.sh
```

## 自动安全检查

脚本执行时会：

1. 检查 root 权限和依赖；
2. 记录当前 `pve-manager` 版本；
3. 检查补丁是否已经安装；
4. 备份两个原始文件；
5. 对每个修改点执行唯一匹配检查；
6. 执行 `perl -c` 检查后端语法；
7. 重启 `pvedaemon` 和 `pveproxy`；
8. 调用 `/cluster/resources`；
9. 将 API 返回值与安装前扫描到的真实备注逐项比较；
10. 任一步骤失败时自动恢复两个原文件并重启服务。

如果系统中暂时没有填写备注的 VM/CT，脚本仍会验证 API 可以正常调用，但会跳过备注值对比。建议安装前至少给一个 VM 或 CT 设置一行备注。

## 验证

安装成功会输出类似：

```text
API verified: qemu 100 description='财务部 Windows 7'
Patch and API functional verification completed.
```

也可以手动检查：

```bash
pvesh get /cluster/resources --type vm --output-format json-pretty |
grep -E '"(vmid|name|description)"'
```

然后使用平时的 PVE 地址并添加脚本输出的防缓存参数，例如：

```text
https://<PVE地址>:8006/?alias_patch=时间戳
```

再按 `Ctrl+F5` 强制刷新。

## 回滚

每次安装会生成独立备份目录：

```text
/root/pve-cn-alias-backup-<时间戳>/
```

其中包含：

```text
Cluster.pm
pvemanagerlib.js
pve-manager-version.txt
expected-notes.json
cluster-resources-after.json
restore.sh
```

执行对应的回滚脚本：

```bash
/root/pve-cn-alias-backup-<时间戳>/restore.sh
```

回滚会恢复两个原始文件，并重启 `pvedaemon` 和 `pveproxy`。

## 注意事项

- 这是对 PVE 系统文件的补丁，不是官方功能。
- 请先在测试环境或维护窗口执行。
- 不要删除脚本生成的备份目录。
- PVE 更新可能覆盖补丁，也可能改变内部代码结构。
- 不要为了中文显示而解除 VM 名称的后端 DNS 校验。
- 如需提交问题，请附上 `pveversion --verbose`、脚本完整输出和备份目录中的版本文件，避免只描述“没有效果”。

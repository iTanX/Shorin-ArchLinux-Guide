# 软件安装

安装 snapper 和 btrfs-assistant

```
sudo pacman -S snapper btrfs-assistant
```

# 命令行管理

## 创建快照

1. 创建快照配置

   ```sh
   # 为根分区 (/) 创建配置
   sudo snapper -c root create-config /
   
   # 为家目录 (/home) 创建配置
   sudo snapper -c home create-config /home
   ```

2. 快照配置内容

   编辑 root 配置：

   ```sh
   sudo vim /etc/snapper/configs/root
   ```

   找到并修改以下参数（没有就添加）：

   ```
   TIMELINE_CREATE="no"
   TIMELINE_CLEANUP="no"
   NUMBER_CLEANUP="no"
   ```

   - `TIMELINE_CREATE="no"`：禁用按时间线自动创建快照。
   - `TIMELINE_CLEANUP="no"`：禁用基于时间线的自动清理。
   - `NUMBER_CLEANUP="no"`：禁用基于数量的自动清理。

   对 `home` 配置（`/etc/snapper/configs/home`）做同样的修改。

3. 手动创建快照

   现在你可以根据需要随时创建快照。

   ```sh
   # 创建 root 分区的快照，-d 用于添加描述
   sudo snapper -c root create -d "变更前的状态"
   
   # 创建 home 分区的快照
   sudo snapper -c home create -d "文档修改前"
   ```

   创建后，可以用以下命令确认快照已存在：

   ```sh
   sudo snapper -c root list
   ```

## 恢复快照

btrfs-assistant 命令行（推荐）

1. 切换至 root

   以普通用户 `sudo` 运行可能会出现环境问题，建议切换到 root。

   ```
   su -
   ```

2. 确认要使用的快照的 **snapper 序号**

   ```
   snapper -c root list
   ```

   可以使用 `grep` 筛选快照。

   ```
   snapper -c root list | grep "Before"
   ```

   假设我要用的快照的 snapper 序号是 `11`。

   [![img](https://github.com/iTanX/Shorin-ArchLinux-Guide/raw/main/wiki/pictures/snap/snapperlist.png)](https://github.com/iTanX/Shorin-ArchLinux-Guide/blob/main/wiki/pictures/snap/snapperlist.png)

3. 用 snapper 序号找到对应的 **btrfs-assistant 序号**

   ```
   btrfs-assistant -l
   ```

   在下图这个例子中，snapper 序号为 `11` 的 root 快照对应着 btrfs-assistant 的序号 `1`。

   [![img](https://github.com/iTanX/Shorin-ArchLinux-Guide/raw/main/wiki/pictures/snap/btrfs-assistant.png)](https://github.com/iTanX/Shorin-ArchLinux-Guide/blob/main/wiki/pictures/snap/btrfs-assistant.png)

   > 注意一个细节，这条命令会把 home 和 root 的快照排在同一个列表里。图中 snapper 序号为 `11` 的 home 快照对应着 btrfs-assistant 序号 `6`。

4. 回档

   ```
   btrfs-assistant -r 1
   ```

   这里的数字是要使用的快照的 **btrfs-assistant 序号**。

**恢复原理**

以根子卷 `@` 为例，btrfs-assistant 的恢复过程大致如下：

1. 将原来的 `@` 改名为 `@_backup_时间戳`，保留恢复前的状态。
2. 从选中的快照创建一个新的可写子卷，命名为 `@`，替换原来的路径。原快照仍然保留，数据块通过写时复制共享，无须完整复制文件。
3. 将原子卷中的嵌套子卷（如 `.snapshots`）移动到新子卷的对应位置。这些嵌套子卷保留现有内容，不会随父子卷一起回档；独立的 `/home` 子卷也需要单独恢复。

恢复后，当前挂载的 `/` 仍指向旧子卷，**应尽快重启**，让系统重新挂载新的 `@`。这要求启动配置和 `/etc/fstab` 按路径（如 `subvol=@`）挂载；如果固定使用旧的 `subvolid`，仍会挂载旧子卷。

## 删除快照

### 基本删除

首先，用 `list` 命令查看快照编号，确认你要删除的是哪一个。

```sh
sudo snapper -c root list
```

然后，使用 `delete` 子命令和快照编号进行删除。这里的 `-c root` 指定了配置，如果你为 `home` 创建了配置，同样需要指定 `-c home`。

```sh
# 删除 root 配置下的快照 65
sudo snapper -c root delete 65
```

### 批量删除

**删除多个不连续的快照**：只需在命令后列出多个编号即可。

```bash
# 同时删除快照 65 和 70
sudo snapper -c root delete 65 70
```

**删除一个范围内的快照**：使用连字符 `-` 指定范围。

```bash
# 删除从 65 到 70 的所有快照（包含首尾）
sudo snapper -c root delete 65-70
```

### 立即释放

默认情况下，删除快照后占用的空间可能不会立刻被回收。如果急需释放空间，可以加上 `--sync` 选项。

```sh
sudo snapper -c root delete --sync 65
```

# 图形化管理

1. 创建配置

   打开 btrfs assistant，切换到 `snapper settings` 页面。我们创建子卷的时候至少创建了一个 `@` 子卷和一个 `@home` 子卷，所以需要两个 `config（配置）`。

   - root 根目录快照

     点击 `new config` 新建配置，`config name` 写 `root`，`backup path` 选择 `/`，然后点击 `save` 保存。

     接着进行一些按照时间自动生成快照的设置。`systemd unit settings` 里面有三个服务。`timeline` 是按照时间计划自动创建快照；`cleanup` 是快照数量达到 `number` 设定的数量上限之后自动清理快照；`boot` 是每次开机自动创建快照。按需设置，设置完记得点 `apply`。

   - home 目录快照

     按照同样的方法创建一个 home 目录的配置。

2. 创建快照

   到 `snapper` 页面，`select config` 选择配置，要创建 root 子卷的快照就选择刚刚创建的名为 `root` 的配置。点击 `new` 创建快照，`description` 是快照的自定义文字描述（注释）。

3. 使用快照进行恢复

   `snapper` 页面 --> `Browse/restore` 页面

   `select target` 选择想恢复的子卷，再选择想使用的快照，点击 `restore`，此时会自动帮你创建一个额外的子卷用来备份当前的数据然后弹出一个确认窗口让你填写这个子卷的名字（可以空着不填写）。

4. 使用快照进行全盘恢复

   因为 `@` 子卷和 `@home` 子卷在创建的时候是平级的，所以虽然 root 目录包含了 home 目录，但是创建 `@` 子卷的快照时不会包含 `@home` 子卷里的内容。这样的子卷布局叫作 `扁平布局`。因此，需要分别创建 `@` 和 `@home` 的快照，然后分别恢复。
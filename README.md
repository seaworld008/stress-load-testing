# Stress Load Testing

一套用于内网 Linux 服务器批量部署定时压测任务的参考流程。

核心使用方式：运维人员在一台内网控制机上维护 `scripts/servers.yaml`，执行一个入口脚本，
把受管理的 `/root/scripts/load_stress.sh` 分发到目标服务器，并为每台服务器写入确定性的
root cron。

## 文件

- `scripts/servers.yaml`：真实服务器清单，本地使用，不提交到 git。
- `scripts/servers.yaml.example`：配置模板。
- `scripts/apply_load_stress.sh`：推荐入口，默认 dry-run，使用 `--apply` 正式部署。
- `scripts/deploy_load_stress.sh`：部署引擎，解析 YAML、计算排班、上传脚本、替换 cron。
- `scripts/load_stress.sh`：最终放到目标机执行的压测脚本。

## 最终使用流程

下面模拟一个正常运维人员从零开始使用的完整步骤。命令默认在内网控制机上执行。

### 1. 进入工作目录并克隆仓库

```bash
mkdir -p /root/soft
cd /root/soft

git clone git@github-seaworld:seaworld008/stress-load-testing.git
cd stress-load-testing
```

如果控制机没有配置 GitHub SSH key，也可以用 HTTPS 地址：

```bash
git clone https://github.com/seaworld008/stress-load-testing.git
cd stress-load-testing
```

### 2. 准备控制机依赖

控制机需要有 `bash`、`awk`、`ssh`、`scp`。如果 `servers.yaml` 里使用密码登录，正式部署时还需要
`sshpass`；脚本会尝试自动安装 `sshpass`。

CentOS 7 可先确认基础命令：

```bash
bash --version
awk --version
ssh -V
scp -V
```

### 3. 创建本地配置文件

```bash
cd /root/soft/stress-load-testing
cp scripts/servers.yaml.example scripts/servers.yaml
chmod 600 scripts/servers.yaml
```

`scripts/servers.yaml` 已加入 `.gitignore`，可以放内网 IP 和密码，不会提交到仓库。

### 4. 修改 servers.yaml

编辑配置：

```bash
vi scripts/servers.yaml
```

可以直接按下面这个结构改。注意：注释要单独写一行，不要写在配置值后面。

```yaml
# settings 是运行策略。以后改压测窗口、并发数量、压测时长和压测强度，优先改这里。
settings:
  # 允许启动压测的开始时间，格式固定为 HH:MM。
  window_start: "02:00"

  # 允许启动压测的结束时间。脚本不会安排 04:00 或之后启动。
  window_end: "04:00"

  # 每隔多少分钟安排一批机器。
  slot_minutes: 15

  # 每一批最多同时启动多少台机器，避免所有机器同一时间打满。
  max_parallel_per_slot: 2

  # 单台机器每次压测持续秒数。900 秒 = 15 分钟。
  duration_seconds: 900

  # CPU 压测比例，范围 0-100，表示最多按总 CPU 核数的多少比例启动 CPU worker。
  # 计算公式为 CPU worker = CPU 核数 * cpu_percent / 100，结果向下取整。
  # cpu_percent: 25 表示最多约 25% CPU，例如 4 核启动 1 个 CPU worker，12 核启动 3 个。
  # cpu_percent: 0 表示不启动 CPU 压测，只执行内存压测。
  cpu_percent: 25

  # 内存压测 worker 数。一般保持 1。
  vm_workers: 1

  # 内存压测比例。15 表示使用总内存约 15%。
  vm_percent: 15

  # 单个内存 worker 的最小内存，单位 MB。
  vm_min_mb: 256

  # 单个内存 worker 的最大内存，单位 MB，防止大内存机器压力过高。
  vm_max_mb: 8192

# defaults 是所有服务器的默认 SSH 配置。单台服务器可以覆盖这些值。
defaults:
  # SSH 用户。当前脚本默认写 /root/scripts 和 root crontab，建议使用 root。
  user: root

  # SSH 端口。
  port: 22

  # SSH 密码。使用 SSH key 免密登录时填 ""。
  password: "CHANGE_ME"

  # 默认是否启用服务器。单台机器可用 enabled: false 临时跳过。
  enabled: true

# servers 是服务器清单。脚本会按这里的顺序排班。
servers:
  # name 只用于日志展示，建议包含主机名或业务名。
  # host 是服务器 IP 或域名。
  - name: pressure-node-01
    host: 192.0.2.11

  - name: pressure-node-02
    host: 192.0.2.12

  - name: pressure-node-03
    host: 192.0.2.13

  # 临时跳过某台机器时，不用删除，改成 enabled: false 即可。
  - name: pressure-node-04
    host: 192.0.2.14
    enabled: false
```

### 5. 先检查 SSH 连通性

任选一台目标服务器测试：

```bash
ssh root@192.0.2.11 'hostname'
```

如果使用密码方式，也可以先手动测试：

```bash
sshpass -p 'CHANGE_ME' ssh root@192.0.2.11 'hostname'
```

### 6. 执行 dry-run

```bash
cd /root/soft/stress-load-testing/scripts
./apply_load_stress.sh --dry-run
```

dry-run 只解析配置并打印排班，不连接远端服务器，不修改 crontab。

输出类似：

```text
[2026-04-30 10:05:53] schedule window 02:00-04:00, slot=15m, max_parallel=2, duration=900s, cpu_percent=25, vm_percent=15
[2026-04-30 10:05:53] deploying to pressure-node-01 (root@192.0.2.11:22) with schedule 02:00
[2026-04-30 10:05:53] deploying to pressure-node-02 (root@192.0.2.12:22) with schedule 02:00
[2026-04-30 10:05:53] deploying to pressure-node-03 (root@192.0.2.13:22) with schedule 02:15
[2026-04-30 10:05:53] processed 3 enabled server(s)
```

确认这些信息：

- 时间窗口是否正确，例如 `02:00-04:00`。
- `cpu_percent`、`vm_percent` 是否符合预期。
- 服务器 IP、端口、账号是否正确。
- 排班是否在窗口内，没有超出结束时间。
- 启用服务器数量是否符合预期。

### 7. 正式部署

确认 dry-run 正确后执行：

```bash
./apply_load_stress.sh --apply
```

脚本会对每台启用服务器执行：

- 创建 `/root/scripts`。
- 上传并覆盖 `/root/scripts/load_stress.sh`。
- 设置脚本权限为 `700`。
- 删除旧的受管理 cron 条目。
- 写入新的定时压测 cron 条目。

重复执行是安全的：同一台机器只会保留一条受管理的 `/root/scripts/load_stress.sh` cron。

### 8. 抽查部署结果

任选一两台目标服务器检查：

```bash
ssh root@192.0.2.11 'crontab -l | grep load_stress'
ssh root@192.0.2.11 'ls -l /root/scripts/load_stress.sh'
```

压测执行后查看日志：

```bash
ssh root@192.0.2.11 'tail -n 50 /var/log/load_stress.log'
```

如需手动试跑远端脚本：

```bash
ssh root@192.0.2.11 '/root/scripts/load_stress.sh'
```

### 9. 后续调整配置

以后只需要改 `scripts/servers.yaml`，再 dry-run、apply：

```bash
cd /root/soft/stress-load-testing/scripts
vi servers.yaml

./apply_load_stress.sh --dry-run
./apply_load_stress.sh --apply
```

常见调整：

- 改压测窗口：修改 `settings.window_start`、`settings.window_end`。
- 改同批并发：修改 `settings.max_parallel_per_slot`。
- 改 CPU 压力：修改 `settings.cpu_percent`。
- 改内存压力：修改 `settings.vm_percent`、`settings.vm_min_mb`、`settings.vm_max_mb`。
- 临时跳过机器：在对应服务器下增加 `enabled: false`。
- 新增机器：在 `servers` 末尾增加一段 `name` 和 `host`。

## 排班规则

- 时间窗口由 `settings.window_start` 和 `settings.window_end` 控制。
- 每个排班槽由 `settings.slot_minutes` 控制。
- 每个排班槽最多启动数由 `settings.max_parallel_per_slot` 控制。
- 容量 = 时间窗口分钟数 / 排班间隔 * 每槽最大并发；超过会失败退出，不会部分部署。

启用服务器按 `servers.yaml` 中出现的顺序排班。比如 `02:00-04:00`、15 分钟一槽、每槽 2 台，
就是前 2 台 `02:00`，接下来 2 台 `02:15`，以此类推；不会安排 `04:00` 或之后启动。

## 目标机压测行为

目标机上的 `/root/scripts/load_stress.sh` 会：

- 要求 root 执行。
- 自动安装 `stress`。
- CPU worker 由 `settings.cpu_percent` 控制，按比例向下取整。
- 内存 worker 和内存比例由 `settings.vm_workers`、`settings.vm_percent`、`settings.vm_min_mb`、`settings.vm_max_mb` 控制。
- 运行时长由 `settings.duration_seconds` 控制。
- 使用锁目录避免同一台机器上的任务重叠。

## 安全约定

`scripts/servers.yaml` 已被 `.gitignore` 忽略。不要把真实内网 IP、账号或密码提交到仓库。

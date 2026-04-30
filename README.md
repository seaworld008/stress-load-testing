# Stress Load Testing

一套用于内网 Linux 服务器批量部署定时压测任务的参考流程。

目标很简单：在一台内网控制机上维护 `scripts/servers.yaml`，执行一个入口脚本，把受管理的
`/root/scripts/load_stress.sh` 分发到目标服务器，并为每台服务器写入确定性的 root cron。

## 文件

- `scripts/servers.yaml`：真实服务器清单，本地使用，不提交到 git。
- `scripts/servers.yaml.example`：配置模板。
- `scripts/apply_load_stress.sh`：推荐入口，默认 dry-run，使用 `--apply` 正式部署。
- `scripts/deploy_load_stress.sh`：部署引擎，解析 YAML、计算排班、上传脚本、替换 cron。
- `scripts/load_stress.sh`：最终放到目标机执行的压测脚本。

## 最终使用流程

### 1. 准备控制机

控制机需要能 SSH 到所有目标服务器。推荐优先使用 SSH key；如果 `servers.yaml` 中配置了
`password`，正式部署时控制机还需要 `sshpass`。

```bash
ssh root@192.0.2.11
```

控制机还需要 `bash`、`awk`、`ssh` 和 `scp`。如果 `servers.yaml` 中配置了 `password`，
正式 `--apply` 会检查并尝试安装必要的 `sshpass`。

### 2. 创建服务器清单

```bash
cp scripts/servers.yaml.example scripts/servers.yaml
chmod 600 scripts/servers.yaml
```

编辑 `scripts/servers.yaml`：

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

  # CPU 压测强度。2 表示使用 CPU 核数的一半；值越小压力越大，不能小于 1。
  cpu_divisor: 2

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
    # password: "" 表示这台机器使用 SSH key 免密登录。
    password: ""

  - name: pressure-node-04
    host: 192.0.2.14
    # enabled: false 表示保留配置但本次跳过部署。
    enabled: false
```

字段说明：

- `settings` 是运行策略，后续改时间窗、并发和压测强度都改这里。
- `window_start/window_end` 控制定时任务的启动窗口，脚本只会在这个窗口内安排启动时间。
- `slot_minutes` 是排班间隔，`max_parallel_per_slot` 是同一时间最多启动多少台。
- `duration_seconds`、`cpu_divisor`、`vm_*` 会写入 cron，控制目标机压测行为。
- `defaults` 会被每台服务器继承。
- 单台服务器上的字段会覆盖 `defaults`。
- `password: ""` 表示使用 SSH key，不使用 `sshpass`。
- `enabled: false` 表示保留配置但跳过这台机器。

### 3. 先 dry-run

```bash
chmod +x scripts/*.sh
./scripts/apply_load_stress.sh --dry-run
```

dry-run 只解析配置并打印排班，不连接远端服务器。确认服务器、账号、端口和时间窗口都正确后再正式执行。

### 4. 正式应用

```bash
./scripts/apply_load_stress.sh --apply
```

重复执行是安全的：脚本会覆盖目标机上的受管理脚本，并先删除旧的
`/root/scripts/load_stress.sh` cron 条目，再写入新的条目。

### 5. 到目标机验证

```bash
crontab -l
ls -l /root/scripts/load_stress.sh
tail -f /var/log/load_stress.log
```

如需手动试跑：

```bash
/root/scripts/load_stress.sh
```

## 详细案例

假设要给 4 台服务器排定夜间压测，其中 3 台启用、1 台暂时跳过：

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

  # CPU 压测强度。2 表示使用 CPU 核数的一半；值越小压力越大，不能小于 1。
  cpu_divisor: 2

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
    # password: "" 表示这台机器使用 SSH key 免密登录。
    password: ""

  - name: pressure-node-04
    host: 192.0.2.14
    # enabled: false 表示保留配置但本次跳过部署。
    enabled: false
```

执行：

```bash
./scripts/apply_load_stress.sh --dry-run
```

预期排班：

```text
pressure-node-01 -> 02:00
pressure-node-02 -> 02:00
pressure-node-03 -> 02:15
```

确认无误后执行：

```bash
./scripts/apply_load_stress.sh --apply
```

部署结果：

- 每台启用服务器创建 `/root/scripts`。
- 上传并覆盖 `/root/scripts/load_stress.sh`。
- 设置脚本权限为 `700`。
- 替换受管理 cron 条目。
- 压测日志写入 `/var/log/load_stress.log`。

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
- CPU worker 默认由 `settings.cpu_divisor` 控制，最少 1 个。
- 内存 worker 和内存比例由 `settings.vm_workers`、`settings.vm_percent`、`settings.vm_min_mb`、`settings.vm_max_mb` 控制。
- 运行时长由 `settings.duration_seconds` 控制。
- 使用锁目录避免同一台机器上的任务重叠。

## 安全约定

`scripts/servers.yaml` 已被 `.gitignore` 忽略。不要把真实内网 IP、账号或密码提交到仓库。

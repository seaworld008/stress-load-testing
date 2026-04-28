# Stress Load Testing

一个用于内网 Linux 服务器批量压测排班的小工具。它的核心思路是：
在一台内网执行机上运行一个 Bash 脚本，然后把压测脚本分发到多台目标服务器，
并自动配置 root 的 cron 定时任务。

适合这类场景：

- 需要在多台服务器上做短时 CPU / 内存压力测试
- 希望从一台内网机器统一分发和管理
- 希望控制压测窗口和并发数量，避免所有机器同时打满
- 目标环境以 CentOS 7、麒麟 V10 或类似 Linux 服务器为主

## 推荐用法

优先使用单文件分发脚本：

```bash
./scripts/load_stress_distribute.sh --dry-run
./scripts/load_stress_distribute.sh
```

`--dry-run` 会只打印将要部署的服务器和排班时间，不会连接远端机器。确认无误后，
再去掉 `--dry-run` 执行真实分发。

## 脚本会做什么

- 在脚本内部维护一份服务器清单
- 自动生成远端 `/root/scripts/load_stress.sh`
- 通过 SSH 把压测脚本写入每台启用的服务器
- 为每台服务器配置一条受管理的 cron 任务
- 默认在 `01:00-03:00` 窗口内排班
- 默认每 15 分钟最多安排 2 台服务器
- 远端默认运行 `stress` 900 秒
- 远端自动根据 CPU 核数和内存大小计算压测参数
- 使用锁目录避免同一台机器上压测任务重叠运行

## 服务器清单

编辑 `scripts/load_stress_distribute.sh` 顶部的 `SERVER_INVENTORY`：

```text
name|host|user|port|password|enabled
pressure-node-01|192.0.2.11|root|22||true
pressure-node-02|192.0.2.12|root|22|CHANGE_ME|true
pressure-node-03|192.0.2.13|root|2222||false
```

字段说明：

- `name`：服务器名称，只用于日志展示
- `host`：服务器 IP 或域名
- `user`：SSH 用户，默认建议使用 `root`
- `port`：SSH 端口
- `password`：SSH 密码；留空表示使用 SSH key
- `enabled`：是否启用，支持 `true/false`

注意：清单使用 `|` 分隔，所以密码里不要包含 `|`。

## 依赖

控制机需要：

- `bash`
- `ssh`
- `sshpass`，仅在清单里填写了密码时需要

目标服务器需要：

- `bash`
- `cron` / `crontab`
- 可用的软件源，用于安装 `stress`

脚本会尝试在目标服务器上自动安装 `stress`。在 CentOS 7 和部分麒麟 V10 环境中，
`stress` 可能依赖 EPEL 或内部 yum/dnf 源；如果自动安装失败，请先在目标机器上确认
软件源是否可用。

## 系统兼容性

脚本按 Bash 编写，不是 POSIX sh。CentOS 7 自带 Bash 4.2，麒麟 V10 常见服务器环境
也满足 Bash 运行要求。

兼容性重点主要在运行环境：

- 目标机需要允许控制机 SSH 登录
- 默认路径使用 `/root/scripts` 和 `/var/log`，推荐 root 用户执行
- 如果目标机禁用了 root SSH，需要自行调整为 sudo 模式
- `stress` 包必须能从目标机软件源安装，或提前手动安装

## 旧版两脚本流程

仓库里仍保留了旧版流程：

- `scripts/deploy_load_stress.sh`
- `scripts/load_stress.sh`
- `scripts/servers.yaml.example`

旧版流程使用 YAML 作为服务器清单，适合想把配置和脚本分离的情况。
真实的 `scripts/servers.yaml` 已加入 `.gitignore`，不要把内网 IP、账号密码等敏感信息
提交到公开仓库。

## 安全提醒

这个项目是运维参考脚本，不建议直接把生产密码写进公开仓库。更推荐：

- 使用 SSH key
- 本地维护真实清单
- 用 `--dry-run` 先确认排班
- 在小批量服务器上试运行后再扩大范围

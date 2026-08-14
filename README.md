# EasyTier Linux 一键安装器

这是一个面向 Linux 服务器的 EasyTier 交互式安装脚本。它会根据当前系统和 CPU 架构选择官方 EasyTier CLI Release，检查安装环境，生成网络配置，并注册 systemd 或 OpenRC 开机服务。

## 一键使用

在目标服务器上执行：

```bash
curl -fsSL https://raw.githubusercontent.com/lssopk/easytier-/main/install-easytier.sh | sudo bash
```

如果当前已经是 root 用户，直接执行：

```bash
curl -fsSL https://raw.githubusercontent.com/lssopk/easytier-/main/install-easytier.sh | bash
```

随后按提示填写：

1. 网络名称
2. 网络密码
3. 节点模式
4. 初始节点地址、协议和端口

脚本不会把密码输出到终端，也不会把网络配置提交到这个仓库。

## 快捷启动菜单

安装完成后执行：

```bash
sudo easytier-menu
```

菜单可以启动、停止、重启 EasyTier，查看状态、节点、对等节点和实时日志，也可以进入 LAN/WAN 转发配置。

转发配置支持四个独立开关：

- EasyTier 虚拟网络 → LAN
- EasyTier 虚拟网络 → WAN
- LAN → EasyTier 虚拟网络
- WAN → EasyTier 虚拟网络

首次配置时，菜单会自动尝试识别 `easytier0`、`br-lan` 和默认路由网卡，也可以手动填写网卡名称。规则保存于 `/etc/easytier/firewall.conf`，并通过 nftables 或 iptables 应用；systemd/OpenRC 重启后会自动恢复。菜单管理的转发规则默认关闭，不会改变原有系统防火墙规则。

这些开关控制的是 Linux 内核的 `FORWARD` 防火墙流量；如果要把虚拟网络作为 LAN/WAN 网关使用，还需要另外配置 EasyTier 子网代理、退出节点或系统路由/NAT。

## 默认节点模式

默认选择“普通加入节点”。该模式会：

- 使用 `-d`/DHCP 自动分配 EasyTier 虚拟 IP；
- 通过 `tcp://初始节点:端口` 主动加入网络；
- 使用 `--no-listener` 关闭本机监听；
- 不抢占共享节点常用的 11010 端口；
- 通过独立的 `easytier-node` 服务持久运行。

这适合把一台公网 VPS 作为共享节点、其他服务器和 Windows 设备作为普通加入节点的场景。

如果当前服务器本身要作为共享/公网节点，启动时选择“共享/公网节点”。此模式会监听 TCP 和 UDP 端口，默认 11010，并尝试配置本机的 ufw 或 firewalld。VPS 面板中的云防火墙仍需要手动放行相同端口。

## 检查和兼容性

脚本会检查：

- root 权限；
- Linux 发行版和 CPU 架构；
- curl、unzip、iproute2 等依赖，缺少时使用 apt/dnf/yum/apk/pacman/zypper 安装；
- `/dev/net/tun`。没有 TUN 时会尝试加载内核模块，并在交互模式中询问是否使用无 TUN 模式；
- systemd 或 OpenRC；
- GitHub Release API 和下载连通性；
- 已有 EasyTier 服务、进程和共享节点监听端口；
- GitHub Release API 提供的 SHA-256 摘要。

当前官方 Release 支持的常见 Linux 资产包括 x86_64、aarch64、arm/armv7、mips/mipsel、riscv64 和 loongarch64。若官方 Release 新增架构，脚本会在资产不存在时明确报错，而不会下载错误二进制。

## 网络不通时使用代理

直连 GitHub 失败时，交互模式会询问是否尝试 `ghfast.top`。也可以显式指定：

```bash
sudo bash /tmp/install-easytier.sh --proxy https://ghfast.top/
```

非交互环境必须显式设置代理：

```bash
sudo env EASYTIER_GITHUB_PROXY='https://your-proxy.example/' \
  bash /tmp/install-easytier.sh --non-interactive
```

代理只是下载通道，不会改变 EasyTier 的组网地址或网络密码。

## 非交互模式

适合批量部署多台服务器。密码建议通过环境变量传入，不要直接写进命令历史：

```bash
sudo env \
  EASYTIER_NETWORK_NAME='my-network' \
  EASYTIER_NETWORK_SECRET='replace-with-your-secret' \
  EASYTIER_PEER_HOST='relay.example.com' \
  EASYTIER_PEER_PORT='11010' \
  EASYTIER_PEER_PROTOCOL='tcp' \
  bash /tmp/install-easytier.sh --non-interactive
```

强制更新已安装的 EasyTier：

```bash
sudo bash /tmp/install-easytier.sh --force-update
```

不设置初始节点：

```bash
sudo bash /tmp/install-easytier.sh --no-peer
```

## 文件和服务

| 项目 | 路径或命令 |
| --- | --- |
| 核心程序 | `/opt/easytier/easytier-core` |
| CLI | `/opt/easytier/easytier-cli` |
| 配置文件 | `/etc/easytier/easytier.conf` |
| 配置备份 | `/etc/easytier/backup/` |
| systemd 服务 | `easytier-node.service` |
| OpenRC 服务 | `easytier-node` |

systemd 管理：

```bash
systemctl status easytier-node
systemctl restart easytier-node
journalctl -u easytier-node -f
easytier-cli node
easytier-cli peer
```

OpenRC 管理：

```bash
rc-service easytier-node status
rc-service easytier-node restart
tail -f /var/log/easytier-node.log
easytier-cli node
easytier-cli peer
```

重复运行脚本不会直接删除旧配置；已有配置会先备份到 `/etc/easytier/backup/`。

## 与官方文档的关系

脚本使用 EasyTier 官方文档中的 `--network-name`、`--network-secret`、`-d`、`-p`、`--listeners` 和 `--no-listener` 配置方式，并从官方 GitHub Release 下载二进制：

- [EasyTier 官方指南](https://easytier.cn/guide)
- [下载页面](https://easytier.cn/guide/download.html)
- [快速组网](https://easytier.cn/guide/network/quick-networking.html)
- [完整配置选项](https://easytier.cn/guide/network/configurations.html)
- [官方 GitHub Releases](https://github.com/EasyTier/EasyTier/releases)

## 注意事项

- 普通节点不需要开放入站 11010，只要能主动访问初始节点即可。
- 共享节点必须同时在 VPS 云防火墙和系统防火墙放行 TCP/UDP 监听端口。
- 共享节点和普通节点应使用相同的网络名称、网络密码和初始节点设置。
- EasyTier 的网络密码保存在目标服务器的 `/etc/easytier/easytier.conf`，脚本将其权限设为 600；请不要把该文件提交到 GitHub。
- 脚本不会替你创建云厂商安全组规则，也不会自动修改未识别的 nftables/iptables 规则。

# WireGuard Home VPN

让公司电脑的所有流量经由家里的 macOS 出网。

## 架构

```
公司电脑（客户端）
    │
    │  WireGuard 隧道（UDP 51820）
    │
家里 Mac（服务端）─── 家用宽带 ─── 互联网
```

## 前置条件

- 家里的 Mac：macOS 12+，已安装 [Homebrew](https://brew.sh)
- 家用路由器：能做端口映射（port forwarding）
- 家里有固定公网 IP（或配置好 DDNS）

## 使用方法

### 第一步：在家里 Mac 上初始化服务端

```bash
sudo bash setup-server.sh
```

脚本会自动：
- 安装 `wireguard-tools`
- 生成服务端密钥对
- 配置 pfctl NAT（让 VPN 流量能访问外网）
- 注册 LaunchDaemon，开机自启

### 第二步：在家用路由器上配置端口映射

将 **UDP 51820** 端口转发到家里 Mac 的内网 IP。

具体操作因路由器品牌不同而异，通常在「虚拟服务器」或「端口映射」菜单里设置。

### 第三步：生成公司电脑的客户端配置

```bash
sudo bash add-client.sh work-macbook <家里的公网IP>
```

脚本会输出一个 `.conf` 文件路径（以及可选的二维码）。

### 第四步：在公司电脑上导入配置

| 系统 | 方式 |
|------|------|
| macOS / Windows | 安装 [WireGuard App](https://www.wireguard.com/install/)，导入 `.conf` 文件 |
| Linux | `sudo wg-quick up /path/to/client.conf` |
| iOS / Android | 用 WireGuard App 扫描二维码 |

启用后，`AllowedIPs = 0.0.0.0/0` 意味着**全部流量**都会走 VPN 隧道回家。

## 验证

连上 VPN 后，在公司电脑上检查出口 IP：

```bash
curl https://ifconfig.me
# 应该显示家里的公网 IP
```

## 常用命令

```bash
# 查看连接状态（服务端）
sudo wg show

# 重启 WireGuard（服务端）
sudo wg-quick down wg0 && sudo wg-quick up wg0

# 查看日志
tail -f /var/log/wireguard-wg0.log
```

## 安全说明

- `.gitignore` 已将所有 `*.key` 和客户端 `.conf` 排除，**不要手动 `git add` 密钥文件**
- 服务端私钥存储在 `$(brew --prefix)/etc/wireguard/`，权限为 `600`

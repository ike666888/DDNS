# Cloudflare DDNS 一键脚本

一个适用于家庭宽带动态公网 IP 的 Cloudflare DDNS 脚本集合：
- `install.sh`：一键安装（安装脚本、交互配置、写入定时任务、立即执行一次）
- `cf-ddns.sh`：核心更新脚本（支持交互配置和定时更新）

## 功能特点
- 交互式输入 Cloudflare **DNS API Token**（不是 Global API Key）
- 可选输入 Cloudflare **Zone ID（区域 API）**，留空自动按主域名查询
- 交互输入 **主域名** 与 **二级域名**（支持 `@` 根域名）
- 支持记录类型：`A` / `AAAA` / `BOTH`
- 仅 IP 变化时更新（可配置强制更新）
- 支持保持 / 开启 / 关闭 Cloudflare 代理状态（`keep/true/false`）
- 自动写入 cron，默认每 5 分钟运行一次

---

## 目录结构

```text
.
├── cf-ddns.sh   # DDNS 主脚本
├── install.sh   # 一键安装脚本（需 root）
├── README.md
└── LICENSE
```

---

## 前置准备

请先在 Cloudflare 创建一个 API Token（推荐最小权限）：
- Zone → DNS → Edit
- Zone → Zone → Read

> 必须使用 **API Token**，不要使用 **Global API Key**。
> `Zone ID` 和 `账户 ID` 不是同一个值，脚本里填写的是 `Zone ID`。

安装机需要：
- Linux 环境
- `curl` 或 `wget`
- `cron` / `crontab`
- root 权限（用于安装到 `/usr/local/bin` 和写入定时任务）

---

## 一键安装

```bash
# 写成两行执行（不要连在一行）
curl -fsSL https://raw.githubusercontent.com/ike666888/DDNS/main/install.sh -o install.sh
sudo bash install.sh
```

或一行版：

```bash
curl -fsSL https://raw.githubusercontent.com/ike666888/DDNS/main/install.sh | sudo bash
```

> 提示：首次安装最后会自动执行一次 `--run`。若当下网络到 Cloudflare 不稳定（例如偶发 HTTP/2 错误），安装不会中断；稍后手动重试即可。
>
> 管道执行时（`curl ... | sudo bash`），脚本会从 `/dev/tty` 读取交互输入。



### 依赖自动安装说明

`install.sh` 现在会自动检查并安装基础依赖（默认开启）：
- 下载工具：`curl` 或 `wget`
- 定时任务工具：`crontab`（Debian/Ubuntu 安装 `cron`，RHEL/Fedora 安装 `cronie`）

在 `apt` 系统上：
- 默认会执行 `apt-get update`（可关闭）
- 默认**不会**执行 `apt-get upgrade`（可按需开启）

可用环境变量：

```bash
# 完全关闭依赖自动安装
AUTO_INSTALL_DEPS=false sudo bash install.sh

# 关闭 apt update
AUTO_APT_UPDATE=false sudo bash install.sh

# 开启 apt upgrade（默认 false）
AUTO_APT_UPGRADE=true sudo bash install.sh
```

安装过程中会提示输入：
1. CF API Token（DNS API）
2. Zone ID（区域 ID，可选，**不要填账户 ID**）
3. 主域名（例如 `example.com`）
4. 二级域名前缀（例如 `home`，根域名请输入 `@`）
5. 记录类型（`A`/`AAAA`/`BOTH`）
6. TTL
7. 是否强制更新
8. 代理模式（`keep/true/false`）

---

## 交互配置（仅主脚本）

如果通过 `install.sh` 安装完成，也可以直接使用命令：

```bash
DDNS
```

`DDNS` 可以直接调出交互配置；也支持传参，例如 `DDNS --run`。

如果你已经有 `cf-ddns.sh`，也可以手动执行：

```bash
./cf-ddns.sh --setup
```

配置文件默认会保存到脚本同目录：
- 例如安装后为 `/usr/local/bin/cf-ddns.conf`

> ⚠️ `cf-ddns.conf` 含有敏感 token，请勿提交到 Git 仓库。

---

## 常用命令

```bash
# 查看当前配置（token 打码）
./cf-ddns.sh --print

# 使用现有配置执行更新
./cf-ddns.sh --run

# 重新进入交互配置
./cf-ddns.sh --setup
```

---

## 定时任务

`install.sh` 默认写入：

```cron
*/5 * * * * /usr/local/bin/cf-ddns.sh --run >> /var/log/cf-ddns.log 2>&1
```

查看日志：

```bash
tail -n 100 /var/log/cf-ddns.log
```

---

## 配置项说明

- `CF_API_TOKEN`：Cloudflare API Token
- `CFZONE_ID`：Cloudflare Zone ID（可选，填写后将直接使用）
- `CFZONE_NAME`：主域名（Zone 名称）
- `CFSUBDOMAIN`：二级域名前缀，`@` 表示根域名
- `CFRECORD_NAME`：完整记录名（脚本会自动根据主域名 + 二级域名生成）
- `CFRECORD_TYPE`：`A` / `AAAA` / `BOTH`
- `CFTTL`：TTL（范围 `120-86400`）
- `FORCE`：`true/false`，是否每次都更新
- `PROXIED`：`keep/true/false`，是否启用 Cloudflare 代理

---

## 故障排查

1. **提示找不到 Zone ID**
   - 检查主域名是否正确
   - 检查 token 是否具备 Zone Read 权限
   - 或直接填写 `CFZONE_ID`

2. **提示找不到 DNS Record**
   - 脚本默认更新已存在记录，请先在 Cloudflare DNS 中创建记录
   - 再执行 `--run`

3. **无公网 IPv6**
   - 若网络不支持 IPv6，请使用 `A` 或忽略 `AAAA`

4. **curl: HTTP/2 PROTOCOL_ERROR**
   - 通常是线路或中间网络设备导致的临时问题
   - 新版脚本会自动重试并回退到 HTTP/1.1
   - 如仍失败，可稍后重新执行：`/usr/local/bin/cf-ddns.sh --run`

---

## 安全建议

- API Token 请使用最小权限，不要使用全局 Key
- 配置文件建议权限 600（脚本写入时已使用 `umask 077`）
- 不要把 `cf-ddns.conf` 上传到公开仓库

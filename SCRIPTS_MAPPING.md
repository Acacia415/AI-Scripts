# 脚本与菜单映射

本文档对应 `tool.sh` 当前主菜单。`本仓库` 表示菜单会下载本仓库中的独立脚本；`第三方` 表示菜单会执行外部项目代码。

| 菜单 | 功能 | 实现/来源 | 主要系统改动 |
|---:|---|---|---|
| 1 | 系统信息查询 | `display_system_info.sh` | 只读查询，不自动安装软件 |
| 2 | 开启 root 登录 | `enable_root_login.sh` | root 密码与 SSH 配置 |
| 3 | 智能流量监控 | `traffic_monitor.sh` | iptables、ipset、systemd、日志 |
| 4 | Snell | 第三方 `xOS/Snell` | 安装代理服务 |
| 5 | Hysteria2 | 第三方 `Misaka-blog/hysteria-install` | 安装代理服务 |
| 6 | SS-Rust | 第三方 `xOS/Shadowsocks-Rust` | 安装代理服务 |
| 7 | ShadowTLS | 第三方 `Kismet0123/ShadowTLS-Manager` | 安装代理服务 |
| 8 | IPTables 转发 | `iptables.sh` | NAT 与转发规则 |
| 9 | GOST v2 转发 | 第三方 `Acacia415/Multi-EasyGost` test 分支 | GOST v2、systemd、日志轮转 |
| 10 | 3X-UI | 第三方 `mhsanaei/3x-ui` | 安装管理面板 |
| 11 | 流媒体检测 | 第三方 `xykt/IPQuality` | 网络探测 |
| 12 | Speedtest | Ookla packagecloud | 添加软件源并安装测速工具 |
| 13 | BestTrace | `git.io/besttrace` | 下载并执行网络测试脚本 |
| 14 | 开放所有端口 | `open_all_ports.sh` | 备份后清空 IPv4/IPv6 filter 规则，保留 NAT/mangle/raw |
| 15 | 时间同步 | `sync-time.sh` | 时区与时间同步服务 |
| 16 | Caddy 管理 | `caddy_manager.sh` | 软件源、Caddy 配置与服务 |
| 17 | Nginx 管理 | `nginx-manager.sh` | 软件源、Nginx 配置与服务 |
| 18 | IP 优先级 | `modify_ip_preference.sh` | gai.conf、IPv4/IPv6 sysctl |
| 19 | magicTCP | 第三方 `qiuxiuya/magicTCP` | 内核网络参数 |
| 20 | 命令行美化 | `install_shell_beautify.sh` | zsh、oh-my-zsh 与用户配置 |
| 21 | DNS 解锁 | `dns_unlock.sh` | DNS、systemd-resolved、iptables |
| 22 | Sub-Store | `install_substore.sh` | Docker 容器与配置 |
| 23 | Telegram 图床 | `install_imghub.sh` | Python 包、Bot 配置与 systemd |
| 24 | BBR + fq | `optimize_tcp_bbr.sh` | `/etc/sysctl.conf` |
| 25 | 恢复 TCP 配置 | `restore_tcp_config.sh` | 恢复 sysctl 备份 |
| 26 | Fail2Ban | `install_fail2ban.sh` | Fail2Ban 配置与服务 |
| 27 | acme.sh | 第三方 `Acacia415/acme-script` | 证书工具与计划任务 |
| 28 | GOST v3 | `gost_v3.sh` | GOST v3、systemd、滚动日志 |
| 29 | 修改主机名 | `change_hostname.sh` | hostname 与 hosts |
| 30 | 重装系统 | `reinstall_system.sh` + 第三方 `bin456789/reinstall` | 清空磁盘并重装、重启 |
| 31 | Hexo 博客 | `Hexo/hexo_manager.sh` | Node.js、博客、备份、Web 服务 |
| 32 | Butterfly 主题 | `Hexo/butterfly_setup.sh` | Hexo 主题与站点文件 |
| 33 | AnyTLS | `anytls.sh` | AnyTLS、systemd、sysctl |
| 34 | SaveAnyBot | `saveanybot-manager.sh` | Bot、OpenList、Docker、网盘凭据 |
| 98 | 卸载工具箱 | `tool.sh` 内置 | 删除快捷命令与本地副本 |
| 99 | 更新工具箱 | `tool.sh` 内置 | 下载并替换主脚本 |

## 维护约定

1. 新增或调整菜单时，同步更新本表和根目录 `README.md`。
2. 本仓库模块优先拆分为可单独执行的脚本。
3. 外部脚本保持获取上游最新版本；必须使用 HTTPS 证书校验、下载失败检测，并尽量在覆盖前备份和做语法检查。
4. 涉及 SSH、防火墙、DNS、sysctl 或重装的功能必须保留明确确认提示。

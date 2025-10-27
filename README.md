# AI-Scripts 工具箱

一个模块化的 Linux 系统管理工具集合，提供各种常用的系统配置和服务安装脚本。

## 📁 项目结构

```
AI-Scripts/
├── tool.sh                          # 主菜单脚本
├── README.md                        # 项目说明文档
├── caddy_manager.sh                 # Caddy反代管理
├── change_hostname.sh               # 主机名修改工具
├── display_system_info.sh           # 系统信息查询
├── dns_unlock.sh                    # DNS解锁脚本
├── enable_root_login.sh             # 开启root用户登录
├── fix_hostname.sh                  # 修复主机名解析错误
├── gost_v3.sh                       # 使用gostv3转发端口
├── install_fail2ban.sh              # 安装fail2ban
├── install_imghub.sh                # 安装TG图床
├── install_shell_beautify.sh        # 命令行美化
├── install_substore.sh              # 安装Sub-Store
├── install_traffic_monitor.sh       # 安装流量监控服务
├── iptables.sh                      # iptables转发
├── modify_ip_preference.sh          # IP优先级设置
├── nginx-manager.sh                 # Nginx反代管理
├── open_all_ports.sh                # 开放所有端口
├── optimize_tcp_bbr.sh              # TCP性能优化(BBR+fq)
├── reinstall_system.sh              # 系统重装工具
├── restore_tcp_config.sh            # 恢复TCP原始配置
├── sync-time.sh                     # 时间同步脚本
└── uninstall_traffic_monitor.sh     # 完全卸载流量监控
```

## 🚀 快速开始

### 安装使用

```bash
# 下载主脚本
curl -sSL https://raw.githubusercontent.com/Acacia415/AI-Scripts/main/tool.sh -o tool.sh

# 添加执行权限
chmod +x tool.sh

# 运行脚本
sudo ./tool.sh
```

### 创建快捷命令（可选）

脚本会自动创建快捷命令 `p`，之后可以直接在终端输入 `p` 来运行工具箱。

## 📋 功能列表

### 系统管理
- **系统信息查询** - 显示系统详细信息（CPU、内存、网络等）
- **开启root用户登录** - 配置SSH允许root登录
- **开放所有端口** - 清空防火墙规则并开放所有端口
- **修改主机名** - 修改系统主机名并更新相关配置
- **修复主机名解析** - 修复 "sudo: unable to resolve host" 错误
- **系统重装** - 一键重装多种Linux系统（Debian/Ubuntu/CentOS等）
- **时间同步** - 校准系统时间，修复时间戳不匹配问题

### 流量监控
- **安装流量监控服务** - 实时监控网络流量并自动封禁异常IP
- **完全卸载流量监控** - 清理所有监控组件和配置

### 网络优化
- **IP优先级设置** - 配置IPv4/IPv6优先级
- **TCP性能优化(BBR+fq)** - 启用BBR拥塞控制算法
- **恢复TCP原始配置** - 从备份恢复TCP配置

### 代理服务
- **Caddy反代管理** - 安装和管理Caddy反向代理
- **Nginx管理** - Nginx服务器管理
- **安装 Snell 协议服务** - 安装Snell代理服务
- **安装 Hysteria2 协议服务** - 安装Hysteria2代理
- **安装 SS-Rust 协议服务** - 安装Shadowsocks-Rust
- **安装 ShadowTLS** - 安装ShadowTLS服务

### 端口转发
- **一键IPTables转发** - IPTables端口转发管理
- **一键GOST转发** - GOST端口转发管理
- **安装 Gost v3** - 安装Gost v3版本

### 面板工具
- **安装 3X-UI 管理面板** - 安装3X-UI代理管理面板
- **安装Sub-Store** - 安装订阅转换工具

### 其他工具
- **流媒体解锁检测** - 检测当前IP的流媒体解锁情况
- **Speedtest网络测速** - 安装并运行网络测速工具
- **命令行美化** - 安装oh-my-zsh和Spaceship主题
- **DNS解锁服务** - DNS解锁服务管理
- **搭建TG图床** - 搭建Telegram图床服务
- **安装Fail2Ban** - 安装Fail2Ban防护服务
- **安装 acme.sh** - 安装SSL证书管理工具

## 📖 模块说明

### 独立脚本模块

所有拆分出的独立脚本都可以单独运行，无需依赖主菜单：

```bash
# 示例：单独运行系统信息查询
curl -sSL https://raw.githubusercontent.com/Acacia415/AI-Scripts/main/display_system_info.sh | bash

# 示例：单独运行TCP优化
curl -sSL https://raw.githubusercontent.com/Acacia415/AI-Scripts/main/optimize_tcp_bbr.sh | bash
```

### 脚本特点

- ✅ **模块化设计** - 每个功能独立成脚本，易于维护
- ✅ **彩色输出** - 友好的终端显示效果
- ✅ **错误处理** - 完善的错误检查和提示
- ✅ **自动清理** - 临时文件自动清理
- ✅ **权限检查** - 自动检查是否具有必要权限

## 🔧 系统要求

- **操作系统**: Debian/Ubuntu Linux
- **Shell**: Bash 4.0+
- **权限**: Root权限
- **网络**: 需要访问GitHub和其他外部资源

## 📝 开发说明

### 项目结构说明

- `tool.sh` - 主菜单脚本，负责显示菜单和调用各个模块
- `SCRIPTS_MAPPING.md` - 记录脚本拆分的详细信息和映射关系
- 独立脚本 - 各个功能模块的独立实现

### 添加新模块

1. 创建新的独立脚本文件
2. 在脚本开头添加颜色定义
3. 实现具体功能
4. 在 `tool.sh` 中添加菜单项和调用代码
5. 更新 `SCRIPTS_MAPPING.md` 文档

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

## 📄 许可证

MIT License

## ⚠️ 免责声明

本工具仅供学习和研究使用，使用本工具所产生的一切后果由使用者自行承担。


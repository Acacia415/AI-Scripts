# Hexo 博客一键管理脚本

> 🚀 为 Debian 12 (ARM) 优化的 Hexo 博客完整解决方案  
> 支持：部署 | 卸载 | 备份 | Git同步 | Caddy反代

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](../LICENSE)
[![Hexo](https://img.shields.io/badge/Hexo-6.x-0E83CD.svg)](https://hexo.io)
[![Node](https://img.shields.io/badge/Node.js-20.x-339933.svg)](https://nodejs.org)
[![Debian](https://img.shields.io/badge/Debian-12-A81D33.svg)](https://www.debian.org)

---

## 📋 目录

- [功能特性](#-功能特性)
- [快速开始](#-快速开始)
- [详细功能](#-详细功能)
- [Caddy 配置](#-caddy-配置)
- [常见问题](#-常见问题)
- [最佳实践](#-最佳实践)
- [故障排查](#-故障排查)

---

## ✨ 功能特性

### 🎯 核心功能

| 功能 | 说明 | 特性 |
|-----|------|-----|
| **🚀 一键部署** | 自动安装 Node.js 20、Hexo 及依赖 | 智能检测、自动升级 |
| **🗑️ 安全卸载** | 完全卸载或仅删除程序文件 | 卸载前自动备份 |
| **💾 智能备份** | 备份源文件、主题、配置 | 自动压缩、保留最近5个 |
| **🔄 Git 同步** | Push、Pull、Clone、Init | 完整的 Git 工作流 |
| **🔥 后台服务** | systemd、PM2、nohup 三种方案 | 开机自启、进程守护 |
| **⚙️ 服务管理** | 启动/停止/重启/查看日志 | 完整的服务管理 |
| **📊 状态监控** | 查看博客状态、文章统计 | 环境检测、版本信息 |

### 🎨 界面特性

- ✅ 彩色输出，清晰易读
- ✅ 交互式菜单，操作简便
- ✅ 智能提示，防止误操作
- ✅ 进度反馈，实时显示

---

## 🚀 快速开始

### 方式一：直接下载运行

```bash
# 下载脚本
curl -fsSL https://raw.githubusercontent.com/Acacia415/AI-Scripts/main/Hexo/hexo_manager.sh -o hexo_manager.sh

# 添加执行权限
chmod +x hexo_manager.sh

# 运行
./hexo_manager.sh
```

### 方式二：克隆仓库

```bash
# 克隆仓库
git clone https://github.com/Acacia415/AI-Scripts.git
cd AI-Scripts/Hexo

# 运行
chmod +x hexo_manager.sh
./hexo_manager.sh
```

### 方式三：一键执行（不保存）

```bash
curl -fsSL https://raw.githubusercontent.com/Acacia415/AI-Scripts/main/Hexo/hexo_manager.sh | bash
```

---

## 📖 详细功能

### 1️⃣ 部署 Hexo 博客

**功能说明：**
- 自动检测并安装/升级 Node.js 到 v20
- 安装必要的系统依赖（git、curl、build-essential）
- 初始化 Hexo 项目到 `/var/www/hexo-blog`
- 安装常用插件（hexo-server、hexo-deployer-git）
- 生成静态文件并提供测试选项

**操作流程：**
```
主菜单 → 选择 1 → 自动检测环境 → 安装依赖 → 初始化项目 → 完成
```

**首次部署预计耗时：** 3-5 分钟（取决于网络速度）

---

### 2️⃣ 卸载 Hexo 博客

**两种卸载模式：**

#### 模式 1：完全卸载
- 删除所有博客文件（包括源文件）
- 卸载前自动提示备份
- 需要输入 `YES` 确认

#### 模式 2：仅卸载程序
- 删除 node_modules、依赖缓存
- **保留源文件、配置、文章**
- 自动创建备份

**附加选项：**
- 可选择是否同时卸载 Node.js

---

### 3️⃣ 备份博客数据

**备份内容：**
```
✅ source/           # 文章和页面源文件
✅ themes/           # 主题文件
✅ _config.yml       # 全局配置
✅ _config.*.yml     # 主题配置文件
✅ package.json      # 依赖配置
✅ scripts/          # 自定义脚本
✅ *.sh              # 管理脚本
✅ db.json           # 数据库文件
```

**备份特性：**
- 自动压缩为 `.tar.gz` 格式
- 时间戳命名：`hexo_backup_20231101_153045.tar.gz`
- 保留最近 5 个备份，自动清理旧备份
- 备份位置：`/var/backups/hexo-blog/`

---

### 4️⃣ 恢复备份数据

**恢复模式：**

#### 模式 1：完全恢复
- 清空目标目录后恢复
- 恢复前可选备份现有数据
- 需要输入 `YES` 确认

#### 模式 2：合并恢复
- 保留现有文件
- 只覆盖同名文件
- 适用于部分恢复

#### 模式 3：预览备份
- 仅解压查看
- 不实际恢复
- 用于确认备份内容

**恢复特性：**
- ✅ 智能检测 Node.js，未安装自动安装
- ✅ 自动恢复 Web 服务器配置
- ✅ 自动重启 Caddy/Nginx 服务
- ✅ 自动安装依赖并生成静态文件

**操作流程：**
```bash
主菜单 → 4 → 选择备份 → 选择模式 → 确认 → 自动恢复
```

---

### 5️⃣ Git 同步

#### 🔸 推送到远程仓库 (Push)
```bash
主菜单 → 4 → 1
# 1. 查看当前状态
# 2. 输入提交信息
# 3. 自动 add、commit、push
```

#### 🔸 从远程拉取 (Pull)
```bash
主菜单 → 4 → 2
# 1. 自动暂存本地更改
# 2. 拉取远程更新
# 3. 恢复暂存内容
# 4. 重新生成静态文件
```

#### 🔸 克隆远程仓库
```bash
主菜单 → 4 → 3
# 1. 输入仓库地址
# 2. 自动克隆到 /var/www/hexo-blog
# 3. 安装依赖并生成静态文件
```

#### 🔸 初始化 Git 仓库
```bash
主菜单 → 4 → 4
# 1. 初始化本地仓库
# 2. 创建 .gitignore
# 3. 初始提交
# 4. 可选添加远程仓库并推送
```

---

### 6️⃣ 后台服务管理 ⭐

**重要：生产环境必须使用后台服务，否则关闭终端后网站就无法访问！**

提供 **3 种后台运行方案**：

---

#### 🔹 方案一：systemd 服务（推荐生产环境）

**优点：**
- ✅ 系统级服务，稳定可靠
- ✅ 开机自动启动
- ✅ 自动崩溃重启
- ✅ systemd 统一管理，日志集成

**操作流程：**
```bash
主菜单 → 5 → 1 → 1 (创建并启动服务)
```

**常用命令：**
```bash
# 启动服务
sudo systemctl start hexo-blog

# 停止服务
sudo systemctl stop hexo-blog

# 重启服务
sudo systemctl restart hexo-blog

# 查看状态
sudo systemctl status hexo-blog

# 查看日志
sudo journalctl -u hexo-blog -f

# 开机自启
sudo systemctl enable hexo-blog
```

---

#### 🔹 方案二：PM2 进程管理（推荐 Node.js 应用）

**优点：**
- ✅ 专为 Node.js 设计，功能强大
- ✅ 实时监控面板
- ✅ 自动重启、负载均衡
- ✅ 详细的日志管理

**操作流程：**
```bash
主菜单 → 5 → 2 → 1 (启动 Hexo 服务)
```

**常用命令：**
```bash
# 查看服务列表
pm2 list

# 查看日志
pm2 logs hexo-blog

# 停止服务
pm2 stop hexo-blog

# 重启服务
pm2 restart hexo-blog

# 监控面板
pm2 monit

# 设置开机自启
pm2 startup
pm2 save
```

---

#### 🔹 方案三：nohup 简单后台（临时方案）

**优点：**
- ✅ 无需安装额外软件
- ✅ 简单快捷

**缺点：**
- ❌ 不支持开机自启
- ❌ 不支持自动重启

**操作流程：**
```bash
主菜单 → 5 → 3
```

**管理命令：**
```bash
# 查看进程
pgrep -f "hexo server"

# 停止服务
pkill -f "hexo server"

# 查看日志
tail -f /var/www/hexo-blog/logs/hexo.log
```

---

**方案对比：**

| 特性 | systemd | PM2 | nohup |
|------|---------|-----|-------|
| 开机自启 | ✅ | ✅ | ❌ |
| 自动重启 | ✅ | ✅ | ❌ |
| 日志管理 | ✅ | ✅ | 基础 |
| 监控面板 | ❌ | ✅ | ❌ |
| 安装复杂度 | 无需安装 | 需要 npm | 无需安装 |
| 推荐场景 | 生产环境 | Node.js 应用 | 临时测试 |

---

### 7️⃣ 启动 Hexo 服务器（前台测试）

**访问地址：** http://localhost:4000  
**默认端口：** 4000  
**停止服务：** Ctrl + C

**⚠️ 注意：此方式仅用于本地测试，关闭终端后服务就会停止！**

适用场景：
- ✅ 本地开发调试
- ✅ 实时预览文章
- ✅ 主题测试

**生产环境请使用选项5的后台服务管理！**

---

### 8️⃣ 生成静态文件

**操作流程：**
1. 清理缓存 (`hexo clean`)
2. 生成静态文件 (`hexo generate`)
3. 输出到 `public/` 目录

**何时使用：**
- 发布前生成最新内容
- 准备部署到生产环境
- 修改配置或主题后

---

### 9️⃣ 查看博客状态

**显示信息：**
- 📁 博客目录和大小
- ⚙️ Node.js、npm、Git 版本
- 📦 Hexo 版本信息
- 📝 文章数量统计
- 🎨 已安装主题
- 🔄 Git 仓库状态
- 💾 备份记录

---

## 🦋 Butterfly 主题配置

> 💕 粉色温馨版 - 专为女儿成长记录网站设计

### 什么是 Butterfly 主题？

Butterfly 是 Hexo 中最受欢迎的主题之一，功能强大、界面美观、高度可定制。

**主要特性：**
- ✅ 响应式设计，完美支持移动端
- ✅ 内置深色/浅色模式切换
- ✅ 丰富的插件支持
- ✅ 多种布局样式
- ✅ 强大的主题配置选项

---

### 一键安装脚本

项目提供了 `butterfly_setup.sh` 一键配置脚本，自动完成所有配置。

**使用方法：**
```bash
# 1. 确保已部署 Hexo 博客
cd /var/www/hexo-blog

# 2. 上传 butterfly_setup.sh 到服务器
# 3. 运行脚本
chmod +x butterfly_setup.sh
./butterfly_setup.sh
```

**脚本功能：**

#### 🔹 步骤 1-2：备份和安装
- ✅ 自动备份现有配置
- ✅ 从 GitHub 克隆 Butterfly 主题
- ✅ 检测是否已安装，避免重复

#### 🔹 步骤 3-4：安装插件
```bash
# 核心插件
- hexo-renderer-pug          # Pug 渲染器
- hexo-renderer-stylus       # Stylus 样式表
- hexo-generator-search      # 本地搜索
- hexo-generator-feed        # RSS 订阅
- hexo-wordcount              # 字数统计
- hexo-generator-sitemap     # 网站地图
- hexo-abbrlink              # 文章链接优化

# 媒体插件
- hexo-tag-aplayer           # 音乐播放器
- hexo-tag-dplayer           # 视频播放器
- hexo-asset-image           # 图片资源管理
- hexo-lazyload-image        # 图片懒加载
```

#### 🔹 步骤 5：创建页面
自动创建以下页面：

**1️⃣ 关于页面** (`/about/`)
```markdown
---
title: 关于宝贝
type: "about"
---

## 💕 关于颜颜

### 基本信息
- 👶 姓名：颜颜
- 🎂 生日：XXXX年XX月XX日
- 💝 爱好：笑、玩、探索新事物
```

**2️⃣ 时光轴页面** (`/timeline-simple/`)
- 使用 Butterfly 内置时光轴标签
- 粉色主题配色
- 支持图片和文字说明

```markdown
{% timeline 2024年,pink %}

<!-- node 2024年1月 - 第一次笑了 -->
![第一次笑](/img/2024-01.jpg)
颜颜宝贝今天第一次对着爸爸妈妈笑了，那灿烂的笑容温暖了整个家！💕

{% endtimeline %}
```

**3️⃣ 相册页面** (`/gallery/`)
- 用于展示照片集合

**4️⃣ 分类/标签页面** (`/categories/`, `/tags/`)
- 文章组织管理

#### 🔹 步骤 6-7：配置主题

**生成粉色配置文件** `_config.butterfly.yml`

```yaml
# 主题色配置（粉色温馨版）
theme_color:
  enable: true
  main: "#FFB5C5"           # 主色调
  paginator: "#FFC0CB"      # 分页颜色
  button_hover: "#FFD1DC"   # 按钮悬停
  link_color: "#FF69B4"     # 链接颜色

# 全局背景
background: 'linear-gradient(to bottom right, #FFF0F5, #FFE4E1, #FFF5EE)'

# 首页副标题
subtitle:
  enable: true
  sub:
    - 记录宝贝成长的每一天 ❤️
    - 愿你笑容常在，快乐成长 🌟
    - 时光荥苒，珍惜当下 🌈
```

**导航菜单配置：**
```yaml
menu:
  首页: / || fas fa-home
  时光轴: /timeline-simple/ || fas fa-clock
  归档: /archives/ || fas fa-archive
  分类: /categories/ || fas fa-folder-open
  标签: /tags/ || fas fa-tags
  相册: /gallery/ || fas fa-images
  关于: /about/ || fas fa-heart
```

#### 🔹 步骤 8-10：完成部署
- ✅ 创建示例文章
- ✅ 创建图片资源目录 `source/img/`
- ✅ 清理并生成静态文件

---

### 安装后的下一步

**1️⃣ 上传照片**
```bash
# 上传到 source/img/ 目录
cd /var/www/hexo-blog/source/img/

# 需要的图片
- avatar.jpg        # 头像
- favicon.png       # 网站图标
- sy.jpg            # 首页头图
- cover1-5.jpg      # 文章封面
- 2024-01.jpg       # 时光轴照片
```

**2️⃣ 个性化配置**
```bash
# 编辑主配置
nano _config.yml

# 修改
- title: 颜颜宝贝的成长小站
- author: 颜颜的爸爸妈妈
- url: https://your-domain.com
```

**3️⃣ 编辑时光轴**
```bash
nano source/timeline-simple/index.md

# 添加宝贝的成长记录
```

**4️⃣ 重新生成**
```bash
npx hexo clean && npx hexo generate
```

---

### 主题特色功能

**🎨 粉色配色方案**
- 主色调：`#FFB5C5` (粉红)
- 渐变背景：`#FFF0F5` → `#FFE4E1` → `#FFF5EE`
- 链接颜色：`#FF69B4` (热粉)
- 按钮悬停：`#FFD1DC` (浅粉)

**📱 响应式布局**
- PC、平板、手机完美适配
- 移动端侧边栏自动收起

**🌙 暗色模式**
- 内置深色/浅色模式切换
- 一键切换按钮

**🔍 本地搜索**
- 快速搜索文章内容
- 无需第三方服务

**📊 字数统计**
- 文章字数
- 阅读时间
- 站点总字数

**🔖 时光轴功能**
- 垂直时间线布局
- 支持图片和文字
- 粉色主题风格

---

### 常见问题

**Q1: 主题安装后不生效？**
```bash
# 1. 检查主题名称
cat _config.yml | grep theme
# 应该显示: theme: butterfly

# 2. 清理缓存重新生成
npx hexo clean && npx hexo generate
```

**Q2: 时光轴页面显示异常？**
- 检查 Front-matter 中 `type: timeline`
- 确认使用了 `{% timeline %}` 标签
- 检查图片路径是否正确

**Q3: 如何修改颜色配置？**
```bash
# 编辑主题配置
nano _config.butterfly.yml

# 修改 theme_color 部分
theme_color:
  main: "#YOUR_COLOR"  # 更改为你喜欢的颜色
```

**Q4: 如何添加更多时光轴记录？**
```bash
nano source/timeline-simple/index.md

# 按格式添加
<!-- node 2024年4月 - 新记录 -->
![图片描述](/img/2024-04.jpg)
文字描述内容...
```

---

### 主题文档资源

- **官方文档：** https://butterfly.js.org/
- **GitHub：** https://github.com/jerryc127/hexo-theme-butterfly
- **示例站点：** https://butterfly.js.org/
- **配置说明：** https://butterfly.js.org/posts/21cfbf15/

---

## ⚙️ Caddy 配置

### 安装 Caddy

```bash
# 添加 Caddy 官方源
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list

# 安装
sudo apt update
sudo apt install caddy
```

### 方案一：反代 Hexo Server（开发测试）

```bash
# 编辑 Caddyfile
sudo nano /etc/caddy/Caddyfile
```

```caddy
blog.example.com {
    reverse_proxy 127.0.0.1:4000
    encode gzip zstd
}
```

**使用场景：** 开发阶段，需要实时预览

---

### 方案二：托管静态文件（生产推荐）⭐

```caddy
blog.example.com {
    root * /var/www/hexo-blog/public
    file_server
    encode gzip zstd
    
    # 404 处理
    handle_errors {
        @404 {
            expression {http.error.status_code} == 404
        }
        rewrite @404 /404.html
        file_server
    }
    
    # 静态资源缓存
    @static {
        path *.css *.js *.jpg *.jpeg *.png *.gif *.ico *.svg *.woff *.woff2
    }
    header @static Cache-Control "public, max-age=31536000, immutable"
}
```

**使用场景：** 生产环境，性能最佳

---

### 应用配置

```bash
# 测试配置
sudo caddy validate --config /etc/caddy/Caddyfile

# 重启 Caddy
sudo systemctl restart caddy

# 查看状态
sudo systemctl status caddy

# 查看日志
sudo journalctl -u caddy -f
```

### 🔒 SSL 证书

Caddy 会自动：
- ✅ 申请 Let's Encrypt 免费证书
- ✅ 自动续期证书
- ✅ 强制 HTTPS 重定向

**前提条件：**
- 域名已正确解析到服务器 IP
- 防火墙开放 80 和 443 端口

```bash
# 开放端口（如果需要）
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
```

---

## 💡 常见问题

### Q1: 脚本运行提示权限不足？

```bash
# 添加执行权限
chmod +x hexo_manager.sh

# 或使用 bash 运行
bash hexo_manager.sh
```

### Q2: Node.js 版本不符合要求？

脚本会自动检测并升级到 Node.js 20，无需手动操作。

### Q3: 端口 4000 被占用？

```bash
# 查找占用进程
sudo lsof -i :4000

# 或修改 Hexo 端口
npx hexo server -p 5000
```

### Q4: 备份文件在哪里？

```bash
# 备份目录
cd /var/backups/hexo-blog

# 查看所有备份
ls -lh hexo_backup_*.tar.gz
```

### Q5: 如何更换主题？

```bash
# 克隆主题到 themes 目录
cd /var/www/hexo-blog
git clone https://github.com/theme-author/theme-name themes/theme-name

# 修改配置
nano _config.yml
# 找到 theme: landscape
# 改为 theme: theme-name

# 重新生成
npx hexo clean && npx hexo generate
```

### Q6: Caddy 无法申请证书？

**检查项：**
1. 域名是否正确解析？`dig blog.example.com`
2. 80/443 端口是否开放？`sudo ss -tulpn | grep -E ':(80|443)'`
3. 是否有其他服务占用？`sudo systemctl stop nginx apache2`

---

## 🎯 最佳实践

### 📝 日常写作流程

```bash
# 1. 新建文章
cd /var/www/hexo-blog
npx hexo new "文章标题"

# 2. 编辑文章
nano source/_posts/文章标题.md

# 3. 本地预览
npx hexo server

# 4. 生成静态文件
npx hexo generate

# 5. Git 提交（使用脚本）
./hexo_manager.sh
# 选择 4 → 1（推送）
```

### 🔄 定期维护

```bash
# 每周备份
./hexo_manager.sh → 选择 3

# 更新依赖
cd /var/www/hexo-blog
npm update

# 清理缓存
npx hexo clean
```

### 🚀 部署前检查清单

- [ ] 已生成最新静态文件
- [ ] 已测试本地预览正常
- [ ] 已提交到 Git 仓库
- [ ] 已创建备份
- [ ] Caddy 配置正确
- [ ] SSL 证书有效

---

## 🔧 故障排查

### 问题：Hexo 命令找不到

```bash
# 检查安装
npm list hexo

# 重新安装
cd /var/www/hexo-blog
npm install hexo --save
```

### 问题：主题不生效

```bash
# 检查主题目录
ls -la themes/

# 检查配置文件
cat _config.yml | grep theme

# 清理重新生成
npx hexo clean && npx hexo generate
```

### 问题：文章不显示

```bash
# 检查文章 Front-matter
cat source/_posts/文章名.md

# 确保包含：
---
title: 标题
date: 2023-11-01
---
```

### 问题：Git 推送失败

```bash
# 检查远程仓库
git remote -v

# 重新设置
git remote set-url origin https://github.com/username/repo.git

# 强制推送（谨慎使用）
git push -f origin main
```

---

## 📂 目录结构

```
/var/www/hexo-blog/
├── _config.yml          # 全局配置
├── package.json         # 依赖配置
├── scaffolds/           # 文章模板
├── source/              # 源文件
│   ├── _posts/         # 博客文章
│   └── _drafts/        # 草稿
├── themes/              # 主题
│   └── landscape/      # 默认主题
├── public/              # 生成的静态文件（部署用）
└── node_modules/        # 依赖包

/var/backups/hexo-blog/
└── hexo_backup_*.tar.gz # 备份文件
```

---

## 🛠️ 配置文件说明

### _config.yml 主要配置

```yaml
# 网站信息
title: 我的博客
subtitle: ''
description: ''
author: Your Name
language: zh-CN
timezone: 'Asia/Shanghai'

# URL
url: https://blog.example.com
root: /
permalink: :year/:month/:day/:title/

# 主题
theme: landscape

# 部署
deploy:
  type: git
  repo: https://github.com/username/username.github.io.git
  branch: main
```

---

## 📊 性能优化

### 静态资源优化

```bash
# 安装压缩插件
npm install hexo-filter-cleanup hexo-filter-optimize --save

# 在 _config.yml 添加
filter_optimize:
  enable: true
  css: true
  js: true
  html: true
```

### CDN 加速

```yaml
# _config.yml
url: https://cdn.example.com
```

### 图片优化

```bash
# 安装图片优化插件
npm install hexo-filter-image --save
```

---

## 📜 更新日志

### v1.0.0 (2023-11-01)
- ✨ 初始版本发布
- ✅ 支持一键部署
- ✅ 支持安全卸载
- ✅ 支持智能备份
- ✅ 支持 Git 同步
- ✅ 完整的 Caddy 配置模板

---

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

### 开发指南

```bash
# Fork 项目
# 克隆你的 Fork
git clone https://github.com/Acacia415/AI-Scripts.git
cd AI-Scripts/Hexo

# 创建分支
git checkout -b feature/your-feature

# 提交更改
git commit -am 'Add some feature'

# 推送
git push origin feature/your-feature

# 创建 Pull Request
```

---

## 📄 License

MIT License - 详见 [LICENSE](../LICENSE) 文件

---

## 🙏 致谢

- [Hexo](https://hexo.io/) - 快速、简洁且高效的博客框架
- [Node.js](https://nodejs.org/) - JavaScript 运行时
- [Caddy](https://caddyserver.com/) - 现代化的 Web 服务器
- 所有贡献者和使用者

---

## 📮 联系方式

- **Author:** Iris & Cascade
- **GitHub:** [Acacia415](https://github.com/Acacia415)
- **反馈:** [GitHub Issues](https://github.com/Acacia415/AI-Scripts/issues)

---

<div align="center">

**⭐ 如果这个项目对你有帮助，请给个 Star！⭐**

Made with ❤️ by Iris & Cascade

</div>

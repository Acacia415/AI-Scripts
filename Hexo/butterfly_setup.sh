#!/bin/bash
# =====================================================
# Butterfly 主题安装配置脚本（粉色温馨版）
# 适用于女儿成长记录网站 - 颜颜宝贝的成长小站
# 包含粉色配色、时光轴、相册等完整功能
# =====================================================

set -e

# 配置变量
BLOG_DIR="/var/www/hexo-blog"
THEME_NAME="butterfly"
SITE_TITLE="颜颜宝贝的成长小站"
SITE_SUBTITLE="记录颜颜成长的每一天"
SITE_DESCRIPTION="这是记录颜颜宝贝成长的温馨小站，每一个瞬间都值得珍藏"
SITE_AUTHOR="颜颜的爸爸妈妈"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PINK='\033[1;35m'
NC='\033[0m'

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_pink() {
    echo -e "${PINK}$1${NC}"
}

echo -e "${PINK}"
echo "╔════════════════════════════════════════════════╗"
echo "║   💕 Butterfly 粉色主题 - 颜颜成长小站 💕      ║"
echo "╚════════════════════════════════════════════════╝"
echo -e "${NC}"

# 检查博客目录
if [ ! -d "$BLOG_DIR" ]; then
    print_error "博客目录不存在: $BLOG_DIR"
    print_info "请先运行 hexo_manager.sh 部署 Hexo 博客"
    exit 1
fi

cd "$BLOG_DIR"

# 步骤1：备份现有配置
print_info "步骤 1/10: 备份现有配置..."
BACKUP_DIR="$HOME/hexo-backup-$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
[ -f "_config.yml" ] && cp _config.yml "$BACKUP_DIR/"
[ -f "_config.butterfly.yml" ] && cp _config.butterfly.yml "$BACKUP_DIR/" 2>/dev/null || true
print_success "配置已备份到: $BACKUP_DIR"

# 步骤2：安装 Butterfly 主题
print_info "步骤 2/10: 安装 Butterfly 主题..."
if [ -d "themes/butterfly" ]; then
    print_warning "Butterfly 主题已存在，跳过安装"
else
    git clone -b master https://github.com/jerryc127/hexo-theme-butterfly.git themes/butterfly
    print_success "Butterfly 主题安装完成"
fi

# 步骤3：安装必需插件
print_info "步骤 3/10: 安装必需插件..."
npm install hexo-renderer-pug hexo-renderer-stylus --save
npm install hexo-generator-search --save
npm install hexo-generator-feed --save
npm install hexo-wordcount --save
npm install hexo-generator-sitemap --save
npm install hexo-abbrlink --save
print_success "核心插件安装完成"

# 步骤4：安装图片和视频插件
print_info "步骤 4/10: 安装媒体插件..."
npm install hexo-tag-aplayer --save
npm install hexo-tag-dplayer --save
npm install hexo-asset-image --save
npm install hexo-lazyload-image --save
print_success "媒体插件安装完成"

# 步骤5：创建必要的页面
print_info "步骤 5/10: 创建页面..."

# 创建关于页面
if [ ! -d "source/about" ]; then
    npx hexo new page about
    cat > source/about/index.md << 'EOF'
---
title: 关于宝贝
date: 2024-01-01 00:00:00
type: "about"
comments: false
---

## 💕 关于颜颜

这是一个记录宝贝成长的温馨小站。

### 基本信息
- 👶 姓名：颜颜
- 🎂 生日：XXXX年XX月XX日
- 💝 爱好：笑、玩、探索新事物

### 成长里程碑
- ✨ 第一次笑：X个月
- 🌟 会翻身：X个月
- 💫 第一次叫妈妈：X个月
- ⭐ 会爬行：X个月

---

> 💕 愿你健康快乐成长，永远保持这份纯真与可爱
EOF
    print_success "创建 关于 页面"
fi

# 创建时光轴页面（使用主题内置标签）
if [ ! -d "source/timeline-simple" ]; then
    mkdir -p source/timeline-simple
    cat > source/timeline-simple/index.md << 'EOF'
---
title: 成长时光轴
date: 2024-01-01 00:00:00
type: timeline
comments: false
---

{% timeline 2024年,pink %}

<!-- node 2024年1月 - 第一次笑了 -->
![第一次笑](/img/2024-01.jpg)

颜颜宝贝今天第一次对着爸爸妈妈笑了，那灿烂的笑容温暖了整个家！💕

<!-- node 2024年2月 - 会翻身啦 -->
![会翻身](/img/2024-02.jpg)

宝贝学会翻身了，开始探索这个世界，越来越厉害！🌟

<!-- node 2024年3月 - 第一次叫妈妈 -->
![叫妈妈](/img/2024-03.jpg)

今天叫妈妈了，那一声"妈妈"让我感动得热泪盈眶！❤️

{% endtimeline %}

<div style="text-align: center; padding: 20px; background: linear-gradient(135deg, #FFE4E1, #FFF0F5); border-radius: 15px; margin: 20px 0;">
  <h3 style="color: #FF69B4; margin-bottom: 10px;">💕 成长的每一刻都值得铭记 💕</h3>
  <p style="color: #666;">愿颜颜健康快乐成长，永远保持这份纯真与可爱</p>
</div>
EOF
    print_success "创建 时光轴 页面"
fi

# 创建相册页面
if [ ! -d "source/gallery" ]; then
    npx hexo new page gallery
    cat > source/gallery/index.md << 'EOF'
---
title: 成长相册
date: 2024-01-01 00:00:00
type: "gallery"
comments: false
---
EOF
    print_success "创建 相册 页面"
fi

# 创建分类页面
if [ ! -d "source/categories" ]; then
    npx hexo new page categories
    cat > source/categories/index.md << 'EOF'
---
title: 分类
date: 2024-01-01 00:00:00
type: "categories"
comments: false
---
EOF
    print_success "创建 分类 页面"
fi

# 创建标签页面
if [ ! -d "source/tags" ]; then
    npx hexo new page tags
    cat > source/tags/index.md << 'EOF'
---
title: 标签
date: 2024-01-01 00:00:00
type: "tags"
comments: false
---
EOF
    print_success "创建 标签 页面"
fi

# 步骤6：配置主题为 Butterfly
print_info "步骤 6/10: 配置主题..."
if grep -q "^theme: butterfly" _config.yml; then
    print_warning "主题已设置为 butterfly"
else
    sed -i 's/^theme:.*/theme: butterfly/' _config.yml
    print_success "已设置主题为 butterfly"
fi

# 步骤7：生成完整配置文件
print_info "步骤 7/10: 生成博客配置文件..."

# 修改 _config.yml
print_info "配置主配置文件 _config.yml..."
sed -i 's|^sitemap:$|sitemap:|' _config.yml 2>/dev/null || true
sed -i '/sitemap:/,/rel: false/c\sitemap:\n  path: sitemap.xml\n  rel: false' _config.yml 2>/dev/null || true

print_success "主配置文件已优化"

# 生成完整的 Butterfly 主题配置文件（粉色版）
print_info "生成粉色主题配置文件..."
cat > _config.butterfly.yml << 'EOFBUTTERFLY'
# Butterfly 主题配置 - 女儿成长记录网站
# 文档: https://butterfly.js.org/

# 导航菜单
menu:
  首页: / || fas fa-home
  时光轴: /timeline-simple/ || fas fa-clock
  归档: /archives/ || fas fa-archive
  分类: /categories/ || fas fa-folder-open
  标签: /tags/ || fas fa-tags
  相册: /gallery/ || fas fa-images
  关于: /about/ || fas fa-heart

# 头像设置
avatar:
  img: /img/avatar.jpg
  effect: true

# 网站图标
favicon: /img/favicon.png

# 页面头图设置
index_img: /img/sy.jpg
archive_img: /img/cover2.jpg
tag_img: /img/cover3.jpg
category_img: /img/cover4.jpg
gallery_img: /img/cover5.jpg

# 首页设置
index_top_img: true

# 首页副标题
subtitle:
  enable: true
  effect: true
  loop: true
  source: false
  sub:
    - 记录宝贝成长的每一天 ❤️
    - 愿你笑容常在，快乐成长 🌟
    - 时光荏苒，珍惜当下 🌈
    - 每一个瞬间都值得珍藏 📸
    - 陪你慢慢长大 🌱

# 文章设置
post:
  meta:
    date_type: both
    date_format: YYYY-MM-DD
    categories: true
    tags: true
  cover:
    index_enable: true
    aside_enable: true
    archives_enable: true
    position: both
    default_cover:
      - /img/cover1.jpg
      - /img/cover2.jpg
      - /img/cover3.jpg
      - /img/cover4.jpg
      - /img/cover5.jpg
  copyright:
    enable: true
    decode: false
    license: CC BY-NC-SA 4.0
    license_url: https://creativecommons.org/licenses/by-nc-sa/4.0/
  toc:
    post: true
    page: true
    number: true
    expand: true
  related_post:
    enable: true
    limit: 6

# 首页文章布局
index_layout: card
index_post_count: 3

# 归档页设置
archive:
  type: year
  format: YYYY年MM月
  order: -1
  limit: false

# 标签和分类页
tag_per_img: /img/tag-default.jpg
category_per_img: /img/category-default.jpg

# 侧边栏
aside:
  enable: true
  hide: false
  button: true
  mobile: true
  position: right
  display:
    archive: true
    tag: true
    category: true
  card_author:
    enable: true
    description: 记录宝贝成长的温馨小站 💕
    button:
      enable: false
  card_announcement:
    enable: true
    content: 欢迎来到宝贝的成长空间！这里记录着每一个珍贵的瞬间 ❤️
  card_recent_post:
    enable: true
    limit: 5
    sort: date
    sort_order: -1
  card_categories:
    enable: true
    limit: 8
    expand: all
  card_tags:
    enable: true
    limit: 40
    color: true
  card_archives:
    enable: true
    type: monthly
    format: YYYY年MM月
    order: -1
    limit: 8
  card_webinfo:
    enable: true
    post_count: true
    last_push_date: true

# 底部设置
footer:
  owner:
    enable: true
    since: 2024
  custom_text: 💕 用爱记录成长 💕
  copyright: true

footer_bg: true

# 背景效果
bubble: 
  enable: true

# 本地搜索
local_search:
  enable: true
  preload: false
  CDN:

# 图片查看器
medium_zoom: true
fancybox: false

# 图片懒加载
lazyload:
  enable: true
  field: site
  placeholder:
  blur: false

# Pjax
pjax:
  enable: false

# 深色模式
darkmode:
  enable: true
  button: true
  autoChangeMode: false

# 阅读模式
readmode: true

# 字数统计
wordcount:
  enable: true
  post_wordcount: true
  min2read: true
  total_wordcount: true

# 访问统计
busuanzi:
  site_uv: true
  site_pv: true
  page_pv: true

# 运行时间
runtimeshow:
  enable: true
  publish_date: 2024/01/01 00:00:00

# 美化配置
beautify:
  enable: true
  field: post
  title-prefix-icon: '\f0c1'
  title-prefix-icon-color: '#F47466'

# 全局字体
font:
  global-font-size:
  code-font-size:
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "Helvetica Neue", Lato, Roboto, "PingFang SC", "Microsoft YaHei", sans-serif
  code-font-family: consolas, Menlo, "PingFang SC", "Microsoft YaHei", sans-serif

# 侧边栏按钮
rightside:
  enable: true
  hide: false
  show_percent: true
  layout:
    - readmode
    - darkmode
    - hideAside
    - toc

# 评论系统
comments:
  use:
  text: true
  lazyload: false
  count: false

# 主题色配置（粉色温馨版）
theme_color:
  enable: true
  main: "#FFB5C5"
  paginator: "#FFC0CB"
  button_hover: "#FFD1DC"
  text_selection: "#FFE4E1"
  link_color: "#FF69B4"
  meta_color: "#B0B0B0"
  hr_color: "#FFD1DC"
  code_foreground: "#FF91A4"
  code_background: "rgba(255, 228, 225, 0.3)"
  toc_color: "#FFB5C5"
  blockquote_color: "#FFB5C5"
  blockquote_padding_color: "#FFD1DC"
  blockquote_background_color: "rgba(255, 192, 203, 0.1)"

# 全局背景
background: 'linear-gradient(to bottom right, #FFF0F5, #FFE4E1, #FFF5EE)'

# 公告
announcement:
  content: 🎈 欢迎来到宝贝的成长空间！这里记录着每一个美好瞬间 ❤️

# 404页面
error_404:
  enable: true
  subtitle: '页面没有找到'
  background: /img/404.jpg

# CDN配置
CDN:
  internal_provider: jsdelivr
  third_party_provider: jsdelivr

# 自定义CSS
inject:
  head:
  bottom:

# PWA
pwa:
  enable: false

# Open Graph
Open_Graph_meta:
  enable: true
  option:

# ==========================================
# 全局音乐播放器 (需要先在VPS安装插件)
# ==========================================
aplayer:
  meting: true
  asset_inject: true

# 全局吸底播放器配置
aplayer_global:
  enable: true
  fixed: true
  autoplay: true
  theme: '#FFB5C5'
  loop: 'all'
  order: 'list'
  preload: 'auto'
  volume: 0.5
  mutex: true
  lrcType: 3
  listFolded: false
  listMaxHeight: 250
  audio:
    - name: '宝贝'
      artist: '张悬'
      url: 'https://music.163.com/song/media/outer/url?id=254597.mp3'
      cover: 'https://p1.music.126.net/8KFcF4NxfGhtOy6z3K-MrA==/109951163067842896.jpg'
    - name: '童年'
      artist: '罗大佑'
      url: 'https://music.163.com/song/media/outer/url?id=5264843.mp3'
      cover: 'https://p1.music.126.net/g-xHd7P9P8vmBrid2W_e9g==/109951163635259885.jpg'
    - name: '小幸运'
      artist: '田馥甄'
      url: 'https://music.163.com/song/media/outer/url?id=34341360.mp3'
      cover: 'https://p1.music.126.net/3Pl_z1ca39xF5sH7pYrG1Q==/109951163558401904.jpg'
EOFBUTTERFLY

print_success "粉色主题配置文件已生成"

# 步骤8：创建示例文章
print_info "步骤 8/10: 创建示例文章..."
cat > source/_posts/welcome.md << 'EOF'
---
title: 💕 欢迎来到颜颜的成长空间
date: 2024-01-01 10:00:00
categories: 
  - 日常记录
tags:
  - 开始
  - 成长
cover: /img/cover1.jpg
---

## 💕 写在前面

这是一个记录宝贝成长点滴的温馨小站。

在这里，我们会记录：
- 🎂 每一个重要的时刻
- 📸 每一张珍贵的照片
- 🎥 每一段有趣的视频
- 💭 每一句可爱的话语

<!-- more -->

### 🌟 网站功能

#### 📅 时光轴
按时间顺序记录每一个成长瞬间，见证宝贝的点滴变化

#### 🖼️ 相册
精心整理的照片集合，珍藏每一个美好瞬间

#### 🏷️ 标签分类
方便查找特定类型的记录，快速回顾美好回忆

---

<div style="text-align: center; padding: 20px; background: linear-gradient(135deg, #FFE4E1, #FFF0F5); border-radius: 15px;">
  <p style="color: #FF69B4; font-size: 1.2em;">💕 愿时光温柔，岁月静好 💕</p>
  <p style="color: #666;">记录每一个珍贵瞬间，陪你慢慢长大</p>
</div>
EOF
print_success "示例文章已创建"

# 步骤9：创建图片目录
print_info "步骤 9/10: 创建资源目录..."
mkdir -p source/img
print_info "提示：请上传宝贝的照片到 source/img/ 目录"
print_info "需要的图片：cover1.jpg ~ cover5.jpg, 2024-01.jpg 等"
print_success "资源目录已创建"

# 步骤10：清理并生成
print_info "步骤 10/10: 生成静态文件..."
npx hexo clean
npx hexo generate
print_success "静态文件生成完成"

echo ""
print_pink "╔════════════════════════════════════════════════╗"
print_pink "║      💕 Butterfly 粉色主题安装完成！💕        ║"
print_pink "╚════════════════════════════════════════════════╝"
echo ""
print_info "✨ 配置完成项："
echo "  ✅ Butterfly 主题 + 粉色配色"
echo "  ✅ 时光轴页面 (垂直布局)"
echo "  ✅ 关于、相册、分类、标签页面"
echo "  ✅ 必要插件（搜索、订阅、字数统计等）"
echo ""
print_info "📝 下一步操作："
echo "1. 上传宝贝的照片到 $BLOG_DIR/source/img/"
echo "2. 编辑 _config.yml 和 _config.butterfly.yml 个性化配置"
echo "3. 编辑 source/timeline-simple/index.md 添加成长记录"
echo "4. 重新生成：npx hexo clean && npx hexo generate"
echo ""
print_info "📂 配置文件备份位置: $BACKUP_DIR"
print_info "🌐 访问网站查看效果！"
echo ""

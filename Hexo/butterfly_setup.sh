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
top_img: /img/about.jpg
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
top_img: /img/timeline.jpg
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
top_img: /img/gallery.jpg
---
EOF
    print_success "创建 相册 页面"
fi

# 创建视频页面
if [ ! -d "source/video" ]; then
    npx hexo new page video
    cat > source/video/index.md << 'EOF'
---
title: 🎬 颜颜的成长视频
date: 2024-01-01 00:00:00
type: "video"
comments: false
top_img: /img/video.jpg
---

<div style="text-align: center; padding: 20px;">
  <h2 style="color: #FF69B4;">🎀 宝贝的成长视频 🎀</h2>
  <p style="color: #999;">记录每一个珍贵的动态瞬间</p>
</div>

---

<div style="max-width: 1000px; margin: 0 auto;">

<a href="/video/2025/" style="text-decoration: none;">
  <div style="background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); padding: 30px; border-radius: 15px; text-align: center; color: white; transition: transform 0.3s; box-shadow: 0 4px 6px rgba(0,0,0,0.1);">
    <h2 style="margin: 0; font-size: 2em; color: white;">2025年</h2>
    <p style="margin: 10px 0 0 0; opacity: 0.9; color: white;">宝贝的第一年</p>
    <p style="margin: 10px 0 0 0; font-size: 0.9em; opacity: 0.8; color: white;">🎬 {% count_videos %}个视频</p>
  </div>
</a>

</div>
EOF
    print_success "创建 视频 页面"
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
top_img: /img/cover4.jpg
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
top_img: /img/cover3.jpg
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
    - <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/aplayer@latest/dist/APlayer.min.css">
  bottom:
    - <script src="https://cdn.jsdelivr.net/npm/aplayer@latest/dist/APlayer.min.js"></script>
    - <script src="https://cdn.jsdelivr.net/npm/meting@2/dist/Meting.min.js"></script>
    # ========== 全局吸底播放器配置 ==========
    
    # 方案1: 使用 QQ 音乐歌单（当前启用）
    # 你的歌单链接: https://y.qq.com/n/ryqq/playlist/1878671155
    # 修改歌单ID: 替换下面的 id="1878671155" 为你的新歌单ID
    - <meting-js server="tencent" type="playlist" id="1878671155" fixed="true" autoplay="false" theme="#FFB5C5" loop="all" volume="0.7" list-folded="false" list-max-height="250px"></meting-js>
    
    # 方案2: 使用网易云音乐歌单（备选）
    # 获取歌单ID: 打开网易云音乐 -> 我的歌单 -> 复制歌单链接，从 URL 中提取 ID
    # 例如: https://music.163.com/#/playlist?id=8539325585 -> ID 就是 8539325585
    # - <meting-js server="netease" type="playlist" id="8539325585" fixed="true" autoplay="false" theme="#FFB5C5" loop="all" volume="0.7" list-folded="false" list-max-height="250px"></meting-js>
    
    # 方案3: 使用本地音乐文件（不受外链限制）
    # 将音乐文件上传到 source/music/ 目录，然后使用以下配置：
    # - <div id="aplayer-global"></div>
    # - <script>var ap=new APlayer({container:document.getElementById('aplayer-global'),fixed:true,autoplay:false,theme:'#FFB5C5',loop:'all',order:'list',preload:'auto',volume:0.7,mutex:true,listFolded:false,listMaxHeight:'250px',audio:[{name:'宝贝',artist:'张悬',url:'/music/baobei.mp3',cover:'/img/cover1.jpg'},{name:'童年',artist:'罗大佑',url:'/music/tongnian.mp3',cover:'/img/cover2.jpg'},{name:'小幸运',artist:'田馥甄',url:'/music/xiaoxingyun.mp3',cover:'/img/cover3.jpg'}]});</script>

# PWA
pwa:
  enable: false

# Open Graph
Open_Graph_meta:
  enable: true
  option:

# ==========================================
# APlayer 音乐播放器（使用主题内置支持）
# ==========================================
aplayerInject:
  enable: true
  per_page: false
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

# 步骤9：创建资源目录和完整结构
print_info "步骤 9/10: 创建资源目录和完整结构..."

# 创建基本资源目录
mkdir -p source/img
mkdir -p source/videos
mkdir -p source/music

# 安装统计脚本
print_info "安装媒体统计脚本..."
mkdir -p scripts
cat > scripts/count-media.js << 'EOFSCRIPT'
const fs = require('fs');
const path = require('path');

function countFiles(dir, extensions, prefix = null, excludePattern = null) {
  if (!fs.existsSync(dir)) return 0;
  
  try {
    const files = fs.readdirSync(dir);
    return files.filter(file => {
      const ext = path.extname(file).toLowerCase();
      if (!extensions.includes(ext)) return false;
      if (prefix && !file.startsWith(prefix)) return false;
      if (excludePattern && file.includes(excludePattern)) return false;
      return true;
    }).length;
  } catch (err) {
    return 0;
  }
}

hexo.extend.tag.register('count_videos', function(args) {
  const videoDir = path.join(hexo.source_dir, 'videos');
  const videoExts = ['.mp4', '.mov', '.avi', '.mkv', '.webm', '.flv'];
  
  const year = args[0] ? parseInt(args[0]) : null;
  const month = args[1] ? parseInt(args[1]) : null;
  
  if (!year) {
    return countFiles(videoDir, videoExts);
  }
  
  if (year && !month) {
    return countFiles(videoDir, videoExts, year.toString());
  }
  
  const prefix = `${year}-${month.toString().padStart(2, '0')}`;
  return countFiles(videoDir, videoExts, prefix);
});

hexo.extend.tag.register('count_photos', function(args) {
  const imgDir = path.join(hexo.source_dir, 'img');
  const photoExts = ['.jpg', '.jpeg', '.png', '.gif', '.webp'];
  
  const year = args[0] ? parseInt(args[0]) : null;
  const month = args[1] ? parseInt(args[1]) : null;
  
  if (!year) {
    return countFiles(imgDir, photoExts, null, 'cover');
  }
  
  if (year && !month) {
    return countFiles(imgDir, photoExts, year.toString(), 'cover');
  }
  
  const prefix = `${year}-${month.toString().padStart(2, '0')}`;
  return countFiles(imgDir, photoExts, prefix, 'cover');
});
EOFSCRIPT
print_success "统计脚本已安装"

# 创建视频年份和月份目录结构
print_info "创建视频目录结构..."
mkdir -p source/video/2025

for month in {2..12}; do
    MONTH_DIR="source/video/2025/$(printf "%02d" $month)"
    mkdir -p "$MONTH_DIR"
    
    cat > "$MONTH_DIR/index.md" << EOFMONTH
---
title: 🎬 2025年${month}月视频
date: 2025-$(printf "%02d" $month)-01 00:00:00
type: video
comments: false
top_img: /img/video.jpg
---

<div style="text-align: center; padding: 20px;">
  <h2 style="color: #FF69B4;">🎀 2025年${month}月 · 宝贝的视频</h2>
  <p style="color: #999;">记录这个月的每个精彩瞬间</p>
</div>

<div style="text-align: center; margin: 20px 0;">
  <a href="/video/" style="color: #FF69B4; text-decoration: none;">← 返回视频首页</a> | 
  <a href="/video/2025/" style="color: #FF69B4; text-decoration: none;">← 返回2025年</a>
</div>

---

<div style="max-width: 800px; margin: 0 auto;">

<!-- 视频嵌入示例（取消注释后使用）
{% dplayer "url=/videos/2025-$(printf "%02d" $month)-01-01.mp4" %}
-->

</div>

---

<div style="text-align: center; padding: 20px; background: linear-gradient(135deg, #FFF5F5 0%, #FFE4E1 100%); border-radius: 15px; margin: 20px 0;">
  <p style="color: #FF69B4; font-size: 16px; margin: 0;">💕 2025年${month}月 · 共{% count_videos 2025 $month %}个视频</p>
</div>
EOFMONTH
done

# 创建视频年份页
cat > source/video/2025/index.md << 'EOFYEAR'
---
title: 🎬 2025年视频
date: 2025-02-18 00:00:00
type: video
comments: false
top_img: /img/video.jpg
---

<div style="text-align: center; padding: 20px;">
  <h2 style="color: #FF69B4;">🎀 2025年 · 宝贝的第一年</h2>
  <p style="color: #999;">记录每一个成长瞬间</p>
</div>

<div style="text-align: center; margin: 20px 0;">
  <a href="/video/" style="color: #FF69B4; text-decoration: none;">← 返回视频首页</a>
</div>

---

<div style="max-width: 1000px; margin: 0 auto;">

<div style="display: grid; grid-template-columns: repeat(auto-fill, minmax(200px, 1fr)); gap: 15px; margin: 30px 0;">

<a href="/video/2025/02/" style="text-decoration: none;">
  <div style="background: linear-gradient(135deg, #FFB6C1 0%, #FFC0CB 100%); padding: 20px; border-radius: 10px; text-align: center; transition: transform 0.3s; box-shadow: 0 2px 4px rgba(0,0,0,0.1);">
    <div style="font-size: 2em; margin-bottom: 5px;">🌸</div>
    <h3 style="margin: 5px 0; color: #333;">2月</h3>
    <p style="margin: 5px 0; color: #666; font-size: 0.9em;">{% count_videos 2025 2 %}个视频</p>
  </div>
</a>
EOFYEAR

# 添加3-12月卡片
for month in {3..12}; do
    EMOJI=("🌼" "🌺" "🌻" "🌈" "☀️" "🍉" "🍂" "🍁" "🎄" "⛄")
    COLOR1=("#98D8C8" "#FFB7D5" "#FFE66D" "#A8E6CF" "#FFD93D" "#FF8AAE" "#F9A825" "#EF6C00" "#8E24AA" "#1976D2")
    COLOR2=("#A8E6CF" "#FFC0E5" "#FFF176" "#B8F0D8" "#FFEB99" "#FFABCC" "#FBC02D" "#F57C00" "#AB47BC" "#42A5F5")
    INDEX=$((month-3))
    
    cat >> source/video/2025/index.md << EOFCARD

<a href="/video/2025/$(printf "%02d" $month)/" style="text-decoration: none;">
  <div style="background: linear-gradient(135deg, ${COLOR1[$INDEX]} 0%, ${COLOR2[$INDEX]} 100%); padding: 20px; border-radius: 10px; text-align: center; transition: transform 0.3s; box-shadow: 0 2px 4px rgba(0,0,0,0.1);">
    <div style="font-size: 2em; margin-bottom: 5px;">${EMOJI[$INDEX]}</div>
    <h3 style="margin: 5px 0; color: #333;">${month}月</h3>
    <p style="margin: 5px 0; color: #666; font-size: 0.9em;">{% count_videos 2025 $month %}个视频</p>
  </div>
</a>
EOFCARD
done

# 添加底部统计
cat >> source/video/2025/index.md << 'EOFBOTTOM'

</div>

</div>

---

<div style="text-align: center; padding: 20px; background: linear-gradient(135deg, #FFF5F5 0%, #FFE4E1 100%); border-radius: 15px; margin: 20px 0;">
  <p style="color: #FF69B4; font-size: 16px; margin: 0;">💕 2025年 · 宝贝的第一年 · 共{% count_videos 2025 %}个视频</p>
</div>
EOFBOTTOM

# 创建相册目录结构
print_info "创建相册目录结构..."
mkdir -p source/gallery/2025

for month in {2..10}; do
    MONTH_DIR="source/gallery/2025/$(printf "%02d" $month)"
    mkdir -p "$MONTH_DIR"
    
    cat > "$MONTH_DIR/index.md" << EOFGALLERY
---
title: 📸 2025年${month}月相册
date: 2025-$(printf "%02d" $month)-01 00:00:00
type: gallery
comments: false
top_img: /img/gallery.jpg
---

<div style="text-align: center; padding: 20px;">
  <h2 style="color: #FF69B4;">🎀 2025年${month}月 · 宝贝的相册</h2>
  <p style="color: #999;">珍藏这个月的美好瞬间</p>
</div>

<div style="text-align: center; margin: 20px 0;">
  <a href="/gallery/" style="color: #FF69B4; text-decoration: none;">← 返回相册首页</a> | 
  <a href="/gallery/2025/" style="color: #FF69B4; text-decoration: none;">← 返回2025年</a>
</div>

---

<!-- 照片展示区域 -->

<div style="text-align: center; padding: 20px; background: linear-gradient(135deg, #FFF5F5 0%, #FFE4E1 100%); border-radius: 15px; margin: 20px 0;">
  <p style="color: #FF69B4; font-size: 16px; margin: 0;">💕 2025年${month}月 · 共{% count_photos 2025 $month %}张照片</p>
</div>
EOFGALLERY
done

print_info "已创建以下目录："
echo "  ✓ source/img/      - 图片资源"
echo "  ✓ source/videos/   - 视频资源"
echo "  ✓ source/music/    - 音乐资源"
echo "  ✓ source/video/    - 视频页面结构 (2025/02-12)"
echo "  ✓ source/gallery/  - 相册页面结构 (2025/02-10)"
echo "  ✓ scripts/         - 统计脚本 (count-media.js)"
print_success "完整目录结构已创建"

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
echo "  ✅ 时光轴页面 (垂直布局，含 top_img)"
echo "  ✅ 全局吸底音乐播放器 (QQ音乐歌单)"
echo "  ✅ 关于、相册、视频、分类、标签页面 (所有页面含 top_img)"
echo "  ✅ 必要插件（搜索、订阅、字数统计、视频播放器等）"
echo "  ✅ 视频目录结构（2025年2-12月，共11个月份）"
echo "  ✅ 相册目录结构（2025年2-10月，共9个月份）"
echo "  ✅ 媒体统计脚本（自动统计视频和照片数量）"
echo ""
print_info "📝 下一步操作："
echo "1. 上传宝贝的照片到 $BLOG_DIR/source/img/"
echo "   - 照片命名格式：2025-05-09-01.jpg"
echo "   - 封面命名格式：2025-05-09-01-cover.jpg"
echo "2. 上传宝贝的视频到 $BLOG_DIR/source/videos/"
echo "   - 视频命名格式：2025-05-09-01.mp4"
echo "3. 上传页面顶图到 $BLOG_DIR/source/img/"
echo "   - video.jpg (视频页顶图)"
echo "   - gallery.jpg (相册页顶图)"
echo "   - timeline.jpg (时光轴顶图)"
echo "   - about.jpg (关于页顶图)"
echo "4. 编辑 _config.yml 和 _config.butterfly.yml 个性化配置"
echo "5. 编辑各月份 index.md 添加视频和照片内容"
echo "6. 重新生成：npx hexo clean && npx hexo generate"
echo ""
print_info "📊 统计脚本用法："
echo "  {% count_videos %}              - 统计所有视频"
echo "  {% count_videos 2025 %}         - 统计2025年视频"
echo "  {% count_videos 2025 5 %}       - 统计2025年5月视频"
echo "  {% count_photos %}              - 统计所有照片"
echo "  {% count_photos 2025 5 %}       - 统计2025年5月照片"
echo ""
print_info "📂 配置文件备份位置: $BACKUP_DIR"
print_info "🌐 访问网站查看效果！"
echo ""

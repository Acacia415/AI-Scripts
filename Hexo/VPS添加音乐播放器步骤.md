# VPS博客添加音乐播放器 - 完整步骤

## 📋 架构说明
- **Windows本地**: `d:\com\BLOG` - 配置文件管理
- **VPS服务器**: `/var/www/hexo-blog` - 博客运行环境

## ✅ 第1步：上传配置文件到VPS（Windows执行）

在Windows PowerShell中执行：

```powershell
# 上传更新后的配置文件到VPS
scp d:\com\BLOG\_config.butterfly.yml root@你的VPS_IP:/var/www/hexo-blog/

# 如果使用密钥登录
scp -i C:\path\to\your-key.pem d:\com\BLOG\_config.butterfly.yml root@你的VPS_IP:/var/www/hexo-blog/
```

**或者使用WinSCP图形化工具上传**

## ✅ 第2步：SSH连接到VPS并安装插件

```bash
# SSH连接到VPS
ssh root@你的VPS_IP

# 进入博客目录
cd /var/www/hexo-blog

# 安装音乐播放器插件
npm install hexo-tag-aplayer --save
```

## ✅ 第3步：重新生成和部署（VPS执行）

### 方式一：使用管理脚本（推荐）

```bash
cd /var/www/hexo-blog
./hexo_manager.sh
```

然后选择：
- 输入 `10` - 生成静态文件
- 或输入 `7` - 重启后台服务（如果使用systemd/PM2）

### 方式二：手动执行

```bash
cd /var/www/hexo-blog

# 清理缓存
npx hexo clean

# 重新生成
npx hexo generate

# 如果使用systemd服务
sudo systemctl restart hexo-blog

# 如果使用PM2
pm2 restart hexo-blog

# 如果使用Caddy托管静态文件（无需重启服务）
# 直接访问网站即可看到更新
```

## 🎉 完成！

访问你的博客网站，页面底部会出现粉色的音乐播放器，自动播放。

## 🎼 自定义歌曲列表

如果想更换歌曲：

1. **在Windows本地修改** `d:\com\BLOG\_config.butterfly.yml`
2. 找到 `aplayer_global.audio` 部分
3. 修改或添加歌曲信息
4. **重新上传到VPS**（重复第1步）
5. **在VPS重新生成**（重复第3步）

### 获取网易云音乐外链

```
歌曲页面: https://music.163.com/#/song?id=254597
外链地址: https://music.163.com/song/media/outer/url?id=254597.mp3
```

## 🔧 常见问题

### Q1: 上传配置文件失败？
- 检查VPS IP地址是否正确
- 检查SSH权限
- 确认目标路径 `/var/www/hexo-blog/` 存在

### Q2: 插件安装失败？
```bash
# 切换到淘宝镜像
npm config set registry https://registry.npmmirror.com
npm install hexo-tag-aplayer --save
```

### Q3: 音乐播放器不显示？
```bash
# 检查插件是否安装
cd /var/www/hexo-blog
npm list hexo-tag-aplayer

# 完全清理重新生成
npx hexo clean
rm -rf public
npx hexo generate
```

### Q4: 音乐无法播放？
- 网易云音乐外链可能失效，尝试更换其他歌曲
- 使用本地音乐文件：上传mp3到 `source/music/` 目录

## 💡 配置说明

配置文件中的关键设置：

```yaml
aplayer_global:
  enable: true        # 启用播放器
  fixed: true         # 吸底固定
  autoplay: true      # 自动播放（浏览器可能限制）
  theme: '#FFB5C5'    # 粉色主题
  volume: 0.5         # 音量50%
  loop: 'all'         # 全部循环
```

**注意**：现代浏览器限制自动播放，用户首次访问需要手动点击播放，之后会自动播放。

## 📱 测试检查

1. ✅ 页面底部是否显示播放器
2. ✅ 点击播放按钮是否能播放
3. ✅ 切换歌曲是否正常
4. ✅ 手机端是否正常显示

---

**完成后你的博客就有温馨的背景音乐啦！🎵**

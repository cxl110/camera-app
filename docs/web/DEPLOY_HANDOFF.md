# 交接单：发布 SQ Cam 的两个静态页面

> 这份文档是给**执行上传的 Agent**看的。目标只有一个：把 `privacy.html` 和 `support.html`
> 发布到公网，并把两个最终 URL 回报给负责人。App Store 提交时这两个 URL 是必填项。

## 一、输入

| 项 | 说明 |
|---|---|
| 文件 | `sqcam_web_pages.zip`，内含 `privacy.html`、`support.html`、`README.txt` |
| 托管目标 | 腾讯云（对象存储 COS 静态网站，或已有 CVM/虚拟主机的站点目录） |
| 域名 | 由负责人提供（如果有） |

## 二、发布前必须做的两处替换

两个 HTML 里各有一处占位符，**不替换就发布会导致 App Store 审核信息与页面内容不一致**：

| 占位符 | 替换为 | 出现位置 |
|---|---|---|
| `support@example.com` | 负责人提供的真实支持邮箱 | privacy.html（联系方式）、support.html（顶部卡片 + FAQ + 页首说明） |
| `COMPANY NAME` | 公司法定名称 | 两个文件的页脚 `© 2026 COMPANY NAME` |

替换方式：

```bash
sed -i '' 's/support@example.com/真实邮箱/g; s/COMPANY NAME/公司名称/g' privacy.html support.html   # macOS
sed -i    's/support@example.com/真实邮箱/g; s/COMPANY NAME/公司名称/g' privacy.html support.html   # Linux
```

替换后自检：

```bash
grep -c 'example.com' privacy.html support.html      # 期望 0
grep -c 'COMPANY NAME' privacy.html support.html     # 期望 0
```

## 三、部署方式 A：已有网站服务器（CVM / 虚拟主机）

把两个文件放到站点根目录下的同一子目录，例如 `/www/wwwroot/<站点>/sqcam/`：

```bash
scp privacy.html support.html <user>@<host>:/www/wwwroot/<站点>/sqcam/
```

Nginx 默认即可正确返回 `text/html`。如果站点开了强制 HTTPS，确认 http 会跳转到 https。

最终 URL：

```
https://<域名>/sqcam/privacy.html
https://<域名>/sqcam/support.html
```

## 四、部署方式 B：腾讯云 COS 静态网站

1. 创建存储桶：地域就近，**访问权限选「公有读私有写」**（私有读会导致审核员打不开）。
2. 上传 `privacy.html`、`support.html` 到桶根目录（或 `sqcam/` 前缀下）。
3. 桶设置 → 基础配置 → **静态网站** → 开启，索引文档填 `index.html`（可后补）。
4. 记下访问域名：
   `https://<桶名>-<APPID>.cos-website.<地域>.myqcloud.com`
5. 最终 URL 为：
   ```
   https://<桶名>-<APPID>.cos-website.<地域>.myqcloud.com/privacy.html
   https://<桶名>-<APPID>.cos-website.<地域>.myqcloud.com/support.html
   ```

如有 `coscli`：

```bash
coscli cp privacy.html cos://<桶名>/privacy.html
coscli cp support.html cos://<桶名>/support.html
```

**不要绑定自有域名**，除非该域名已备案 —— 绑定未备案域名在国内会被拦，审核员在境外也可能打不开。COS 默认域名可直接使用。

## 五、发布后必须验证（把输出贴回负责人）

```bash
for u in privacy support; do
  curl -sS -o /dev/null -w "%{http_code} %{content_type}  %{url_effective}\n" "https://<最终域名>/<路径>/$u.html"
done
```

期望：两行都是 `200 text/html`。

再抓一次正文确认内容真的发布上去了（不是错误页）：

```bash
curl -sS https://<最终域名>/<路径>/privacy.html | grep -c 'SQ Cam'
curl -sS https://<最终域名>/<路径>/support.html | grep -c 'Try without a camera'
```

两个计数都应 ≥ 1。

手动确认（重要）：

- [ ] 浏览器**无痕窗口**打开两个链接，不需要登录
- [ ] 中文正常显示（页面声明了 UTF-8）
- [ ] support.html 里「隐私政策」链接能跳到 privacy.html（两文件同目录才行）
- [ ] 页面在手机上打开排版正常

## 六、回报格式

```
隐私政策 URL: https://...
支持 URL    : https://...
校验输出    :
  200 text/html https://.../privacy.html
  200 text/html https://.../support.html
替换确认    : example.com 出现 0 次；COMPANY NAME 出现 0 次
```

## 七、边界（不要做的事）

- **不要**修改页面里的隐私表述。当前文案对应 App 的实际行为：不收集任何数据、不联网上传、
  仅使用本地网络与相册权限。App Store 的「App 隐私」问卷会按此填写「不收集数据」，
  两边必须一致。若负责人要求改动实质内容，先回到开 App 的人确认，不要自行改。
- **不要**给页面加访问控制、验证码、反爬拦截，也不要放在需要登录的目录下。
- **不要**把这两个页面和其他业务页面混在一个需要 Cookie/JS 渲染的框架里；必须是纯静态、
  直接返回 HTML 的地址。

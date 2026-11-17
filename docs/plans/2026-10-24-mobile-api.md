# 移动端客户端 API

- 日期：2026-10-24
- 相关：dsh-go（Android 上的 DSH 客户端）的 Bot 页；[桌面应用](2026-10-16-desktop-app.md)「界面」、[群聊](2026-10-07-group-chat.md)

## 为什么

网页版和桌面应用的界面都是 DSH 网页前端加 `ds-bot` 插件：群聊的历史靠插件在浏览器里拆 `group_relay` 的结果，进行中的一轮靠每秒轮询 `room-progress`，别的状态靠轮询 `state`。手机不一样：

1. **自己画界面。** 手机客户端（dsh-go）用原生控件画 Bot、群聊和详情，不跑 DSH 网页前端，也不跑插件的界面代码。群聊怎么从会话里拆出发言人，这条规则只能有一份，放在服务端。
2. **会断线、会被挂到后台。** SSE 连接在后台会被系统掐断，回来时要知道错过了什么：哪个 Bot 说了话、群里谁交了活、哪张卡在等人。
3. **两边各自升级。** 手机上的 App、手机里装的 `ds-bot`、NAS 上 Docker 里的 `ds-bot` 版本不会一致，需要一个握手说清楚彼此会什么。
4. **流量和体积。** Bot 的头像照片是 data URL，每次 `state` 都带全部照片，手机远程连接时太重。

取舍：

- **传输与 Remote 方法。** 本地 / LAN / SSH 仍走 `POST api/bot` 和 `GET api/bot/feed`，使用 DSH 会话 cookie 鉴权，和桌面应用的窗口一样。当客户端只能经由转发 DSH Typert Gateway Remote 方法的链路到达主机时，插件额外以源码模式注册两个 Gateway Remote 方法复用同一通道与事件流（纯 JS 插件不带 Typert 生成器）：`dsBot/call { endpoint, payload }` 返回与 `POST api/bot` 相同的 `{ ok, value | error }`（和手机配对链路一样，拒绝仅限电脑本机执行的 `phone-*` 配对管理与 `folder-pick` 原生弹窗，`bot/refused`），`dsBot/feed {}` 以流的形式推送 `{ event, data }`（首条为 `hello`）。代价：若中继自身带有接口允许列表（如 `ds-harness-remote`），需同时放行 `dsBot/call` 与 `dsBot/feed`，见「已知限制」。
- **显示用的条目，不是原始事件。** 群聊和 Bot 私聊都给「谁、说了什么、什么时候」的条目，客户端不需要懂 DSH 的会话事件和 DS Bot 的内部来源标记。
- **提醒放内存。** 提醒只是「回来时补上」的索引，不是记录本身；真正的内容还在会话和 `state.json` 里。所以不落盘，重启后从头计数（`boot` 变了），客户端重新读一遍团队即可。

## 已定的行为

### 版本和握手

- `hello`：`{ client?: { name, version, platform }, api?: [1] }` → `{ api, apiMin, apiMax, plugin: { name, version }, capabilities, boot, seq, revision, readOnly, memory, feed, rpc? }`。
  - `api` 是双方都会的最高版本；客户端不传时是服务端当前版本；没有交集时是 `null`，客户端提示更新。
  - `capabilities` 列出服务端会的东西（`room-chat`、`notices`、`avatar`、`memory-edit`、`usage-summary`，挂载 Gateway Remote 时含 `rpc` 等）。
  - 当宿主挂载 DSH Typert Gateway 且 `dsBot/call`、`dsBot/feed` 就绪时，带 `rpc: { call: 'dsBot/call', feed: 'dsBot/feed' }`；未挂载时不返回 `rpc` 与 `rpc` 能力。
  - `boot` 每次 DSH 启动都换；`seq` 是最新一条提醒的序号。
- 版本规则：
  - 只加东西（新接口、新字段、新的条目或提醒种类、新的 feed 事件）不升 `api`，写进 `capabilities`。客户端跳过不认识的字段、种类和事件。
  - 旧客户端会读错的改动才升 `api`；服务端在 `apiMin..apiMax` 之间都照常回答。
- 没有 `hello` 的旧 `ds-bot` 回 `bot/not-found`，客户端据此判断版本太旧。

### 团队和头像

- `state` 照旧。加 `avatars: 'ref'` 时，每张照片换成 `avatar.imageRef`（照片内容的 SHA-256 前 16 位），其他不变。
- 手机经 link 的 `bot` 调用（`{ endpoint, payload }`）可以再带一个 `state` 字段，内容就是发给 `state` 接口的请求体：写入成功且团队版本变了时，回包里多一个 `state`，等于当场问一遍 `state` 的回答。读取、版本没变的写入、失败的写入都不带。
- `avatar`：`{ botId }` → `{ botId, ref, image }`，没有照片时 `ref` 和 `image` 都是 `null`。客户端按 `ref` 缓存，`ref` 变了再取。
- 角色形象（`avatar.shape`）和默认颜色照旧由客户端按 Bot id 算（`characters.js` 的 `defaultColor`）。

### 私聊

- `chat`、`send`、feed 的 `message` 和 `stream` 照旧（见 `feed.js`）。`chat` 的用户消息同样带 `images` / `imageRefs`。
- `image`：`{ sessionId, attachmentId }` → `{ mime, data }`，`data` 是图片字节的 base64。`sessionId` 只认团队的会话（Bot 自己的私聊段、群的会话、换段留下的旧段），其它回 `bot/not-found`；附件不在会话里也是 `bot/not-found`。需要 `images` 能力。加 `preview: true` 时，长边超过 512 像素、文件超过 100 KB 的 JPEG 和 PNG 换成长边 512 的 JPEG 预览，回 `{ mime: 'image/jpeg', data, preview: true }`；其它照旧回原图。聊天里用预览，点开再取原图。需要 `image-preview` 能力。

### Bot 浏览器

- `state.browserHolds`：每个 Bot 的浏览器现在被谁拿着（`holdSnapshot()` 的形状）：Bot 请用户接手（带 `callId`、`reason`、`note`），或用户接管。
- `browser-frame`：`{ botId }` → `{ mime, data, url, title }`，Bot 浏览器当前页的截图（JPEG，base64）。这台机器不开 Bot 浏览器回 `bot/browser-off`，这个 Bot 没有打开的浏览器回 `bot/not-found`。
- 接管、交还、停下照旧用 `browser-takeover`、`browser-give-back`、`browser-stop`。

### 群聊

- `room-chat`：`{ roomId, cursor? }` → `{ roomId, items, cursor, running, speaking }`，从新到旧分页，每页最多 60 条消息，页内从旧到新。
- 条目：
  - `{ id, kind: 'user', text, images?, imageRefs?, time }`：用户的消息，包括一轮进行中插进来的。`images` 是图片张数，`imageRefs` 是每张的 `{ attachmentId, mime?, name? }`，用 `image` 取内容。
  - `{ id, kind: 'bot', botId, name, color?, text, time, duration?, whole?, live? }`：成员的发言，或 Bot 从群外发进来的帖子。`whole: { length, file }` 表示帖子太长、转成了文件，用 `file-text` 读全文。
  - `{ id, kind: 'event', event, botId?, name?, text?, code?, time }`：一轮里的事件，`event` 是 `working`、`approval`、`done`、`stopped`、`failed`、`missed`、`lookup`、`resumed`、`cut`，或定时任务的 `schedule`。
- 一轮进行中时，最新一页在这轮的位置放上目前为止的发言（`live: true`），`running` 为真，`speaking` 是正在说话的成员。这轮结束后，同一条发言的 `id` 不变（`<callId>:<序号>`），客户端可以直接替换。
- 发消息照旧用 `send`（`sessionId` 是群的 id）；停下成员的活照旧用 `stop-member-work`；群里成员的审批照旧用 `approval-answer`。

### 提醒

- 种类：
  - `message`：Bot 在自己的私聊里说了话（Bot 之间的隐藏回合和换段时的固定回复不算）。
  - `group`：成员在群里发言。
  - `done`：成员做完了派给它的活。
  - `question`、`view`：Bot 的私聊里有提问卡、视图卡在等用户。
  - `approval`：Bot 在等用户批准（在群里时带群）。
- 每条：`{ seq, kind, botId, name, roomId?, title?, sessionId?, text, time }`。`name` 是 Bot 现在的名字，`title` 是群名，`text` 最多 300 字、压成一行。
- `notices`：`{ boot?, since? }` → `{ boot, seq, reset, notices }`。`boot` 不一致（重启过）或者 `since` 之后的提醒已经被挤掉时，`reset` 为真，客户端重读团队。内存里最多留 200 条。
- 提醒只说「有事」，不记已读。已读和通知怎么弹由客户端决定。

### 直播（feed）

- `hello` 多带 `api`、`boot`、`seq`，重连后客户端先用 `notices` 补上。
- 新事件 `notice`：一条提醒，内容同上。
- 新事件 `room`：`{ roomId }`，群里有了新的一行、一轮开始或结束，150 毫秒内的合并成一条。客户端重新读这个群的第一页。
- `dsBot/feed` 流每次订阅先送一条 `hello`，随后转发所有实时事件；插件卸载重载或单条订阅积压满 512 条未消费事件时当即结束订阅（不排空旧积压），由客户端重连后用 `hello` 与 `notices` 补齐。

### 记忆

- `memory-add`：`{ botId | roomId, scope?, topic?, text }`，`memory-edit`：`{ botId | roomId, scope?, topic?, text, next }`。用户自己写的条目，不经模型；检查和工具一样（长度、像密钥的内容拒绝，`bot/invalid`）。都返回和 `memory-view` 一样的结果。删除照旧用 `memory-forget`。

### 用量

- `usage-summary`：`{ botId, timeZone? }` → `{ botId, day, week, month, models, scanning }`。`day`、`week`、`month` 是最近 24 小时、7 天、30 天的 `{ input, cacheRead, cacheWrite, output, calls }`；`models` 是最近 30 天按模型分的同样数字。

### 只读的 DSH

- `hello`、`notices`、`avatar`、`room-chat`、`usage-summary` 在只读的 DSH 上也回答；`memory-add`、`memory-edit` 和其他改动一样拒绝（`bot/read-only`）。

## 不做什么

- 不把已读状态存在服务端：每台设备各看各的。
- 不推送到手机系统（FCM 之类）：客户端连着时才收得到，后台靠客户端自己的保活。
- 不给群聊单独算用量：成员在群里的用量记在成员自己名下。
- 不改网页版和桌面应用用的接口和事件。

## 已知限制

- 若远程中继（如 `ds-harness-remote`）维护自身的 Remote 接口允许列表，需该中继允许列表包含 `dsBot/call` 与 `dsBot/feed` 后才能通过中继使用；SSH 隧道、局域网直连和本机不受此限制。
- 旧群（PTC 预设下建的）一轮跑在 `run_code` 里，`room-chat` 认不出这种轮次的发言。
- 提醒不落盘：DSH 重启前没送到的提醒就丢了，客户端只能重读团队。

## 变更


## File download chunks

`file-download` accepts an `offset` in bytes. It returns at most 512 KiB of file
content as base64, with `nextOffset`, `done`, `size`, and `version`. Subsequent
requests repeat the returned version so a changed presented file cannot be spliced
into an earlier download. Presented-file coordinates require their exact Session
part; a Bot id never searches matching sequence numbers in other parts.

New clients request one chunk at a time. Android and iOS write each chunk through an
Expo file handle before requesting the next; the browser collects Blob parts. There
is no total-file limit for chunk clients. Older clients that omit `offset` retain
the existing whole-file response and its 16 MiB compatibility limit.

## 手机补充接口（2026-11-15）

这四个接口只加不改，写进 `capabilities`，旧客户端不受影响：

- `file-upload`：`stage-file { name, size, offset, uploadId?, data }` 分块上传一个文件（每块最多 768 KiB 的 base64，整个文件最多 32 MiB，在内存里拼好后存进附件服务），最后一块返回 `{ id, done: true }`。`send` 多一个 `files: [id]`。DSH 的 `prompt` 只接受浏览器上传的回执，所以带文件的消息按 Bot 之间传文件的方式（`delivery.js`）以附件引用排进队列。照片和文件要分两条消息发。
- `message-search`：`{ botId, query }` 在这个 Bot 自己的聊天（所有分段）里按词搜索，返回 `{ results: [{ sessionId, seq, time, role: 'user'|'bot', text }] }`，最新的在前，最多 20 条。复用 `read_own_chat` 的聊天索引。
- `step-detail`：`{ sessionId, turn, index }` 返回这一轮步骤行里第 `index` 个工具调用的 `{ name, arguments, output, ok?, done, truncated }`，参数和输出各截到 8000 字。
- `thinking-text`：`thinking` 多一个 `text: true`，同时返回这一轮的思考内容 `{ ms, text, truncated? }`，最多 20000 字。

## 团队动作条目（2026-11-16）

能力 `chat-acts`。`chat`、`earlier` 和 feed 的 `message` 多一种条目 `{ kind: 'act', act, state, callId, seq, turn, time, … }`，就是桌面聊天里画成事件行的那些调用（`cells.js` 的 `renderCall`），名字在主机上解析成 id，手机点开就能跳过去。其他工具调用照旧不出现。

- `act`：`message`、`stop`（`bot`、`from`，`from` 是发出的 Bot，两人的往来用 `exchange { a: from, b: bot.id }` 读）；`create-bot`、`update-bot`（`bot`，改的是自己时 `self: true`）；`group`（`verb` 是 `created`、`updated`、`deleted`、`posted`，`room`）；`read-group`（`room`）；`memory`（`tool`、`outcome` 是 `saved`、`already`、`unchanged`、`failed`，`whose` 是 `self`、`team`、`bot`，`open` 是能打开的记忆 `{ botId }` 或 `{ roomId }`，`code`）；`computer`（`method`、`app?`、`shot?: { attachmentId, mime? }`）。
- `bot`、`room` 是 `{ id?, name }`：已经不在的 Bot 或删掉的群只有名字。
- `state` 是 `running`、`done`、`failed`。发消息、叫停和电脑步骤从调用开始就有；其余的等结果出来才有，结果说明什么都没发生时不出条目。
- 条目放在调用的位置，`seq` 是调用的 seq，所以结果到了同一行原地更新。feed 一次只送一个事件：结果单独到达时，主机按记下的调用补出完整条目。
- `run_code` 程序里派发的同类调用（`tool/ptc-dispatch`）也算。隐藏的 Bot 间对话轮次不出条目。
- `image` 也认工具结果里的图片，电脑步骤的截图用它取，和聊天照片一样有预览。
- 手机把相连的电脑步骤合成一张卡片，列出步骤和截图；其余条目是居中的事件行，点开对应的聊天、往来记录、Bot 详情或记忆。

## 回复里展示的图片（2026-11-16）

能力 `shown-images`。`image` 多两种取法，读的都是电脑上的文件：

- `{ sessionId, path }`：Bot 回复里 Markdown 图片 `![说明](路径)` 的目标，按回复写的原样传，可以带尖括号或百分号转义。相对路径按 `sessionId` 这个聊天的文件夹解析，和 DSH 的聊天一样。`sessionId` 要是团队的会话，和 `file-download` 认的一样。
- `{ sessionId, seq, index }`：一轮用 `present` 交付的文件，坐标和 `file-download` 相同，`sessionId` 用文件条目自带的那一段。
- 只认 png、jpg、jpeg、gif、webp，其它回 `bot/invalid`。不存在的文件、DSH 或团队数据目录里的文件回 `bot/not-found`。
- `preview: true` 和照片一样给长边 512 的 JPEG 预览。不带 `preview` 时，超过 2 MiB 的图片换成长边最多 2048 的 JPEG：手机连接一条消息最多 4 MiB（base64 之后）。缩不了的（大的 GIF、WebP）回 `bot/refused`。
- 手机上，回复里的 Markdown 图片按原比例画在气泡里，http(s) 的网页图片由手机直接加载；`present` 交付的图片画成图，点开全屏，全屏里能保存原文件；其它交付的文件仍是文件卡片，点卡片就保存。电脑没有 `shown-images` 时手机照旧显示说明文字和文件卡片。

## 撤回消息（2026-11-16）

能力 `recall`。行为见[撤回消息](2026-11-16-message-recall.md)。

- `recall-check`：`{ botId, sessionId, seq, time? }` → `{ files, count, maybe }`。`files` 是这条消息之后 Bot 改过的文件（最多 8 个），`count` 是总数，`maybe` 表示有还没结束或摘要已经不在的轮次写过文件、说不出是哪些。`count` 为 0 且 `maybe` 为假时不用问用户。
- `recall`：参数同上 → `{ text, images, until }`。`text` 是被撤回的消息原文，放回输入框；`images` 是它带的图片张数（图片不放回）。
- `sessionId` 是聊天页的 `sessionId`（Bot 的当前分段），`seq`、`time` 是这条用户条目自带的。`time` 不一致回 `bot/stale`：列表里更早分段的条目不会撤回当前分段里同一个 `seq` 的消息。手机只给最后一条分段线（`divider`）之后的用户条目显示撤回。
- 失败：不是用户自己的消息 `bot/invalid`；更早的分段、已经撤回、已经压缩进上下文摘要 `bot/stale`；本地 Agent CLI 上的 Bot `bot/refused`；同一个聊天正在撤回 `bot/busy`。
- `chat` 和 `earlier` 在被撤回的消息处多一种条目 `{ kind: 'recalled', seq, turn, time }`，它之后被撤回的条目不再出现。
- feed 新事件 `recall`：`{ botId, sessionId, seq, until }`，客户端从最新一页重新读这个 Bot 的聊天。

## 失败的轮次（2026-11-17）

能力 `turn-failures`。网页上 Bot 私聊里一轮失败时有修复卡片（`turn-error.js`），手机以前什么都看不到，也没法重试。

- `chat`、`earlier` 和 feed 的 `message` 多一种条目 `{ kind: 'failed', code, status?, requestId?, message?, provider?, asked?, seq, turn, time }`，放在这一轮的 `turn/end` 处。出条目的结束方式和 DSH 自己的失败行（ui-chat `turn-error`）相同：出错、因退出 DeepSeek 账号被停下（`ACCOUNT_SIGNED_OUT`）、重启时没做完被关掉（`INTERRUPTED`）。用户叫停、输出到上限、正常结束都没有条目。
- `code` 是 DSH 的失败代码，DS Bot 修正过的照修正后的（403 内容审核是 `CONTENT_POLICY`）。`message` 是服务商的原文，隐藏了密钥，`AUTH` 永远不带。`provider` 是失败路由的服务商，主机记下这次失败后才有，所以 feed 先到的条目可能没有，下一次读 `chat` 会补上。`asked` 表示这一轮是在答另一个 Bot（隐藏轮次），那个 Bot 已经被告知了。
- 提醒多一种 `{ kind: 'failed', botId, sessionId, code, status?, text }`：Bot 自己私聊里用户能看到的一轮失败了（隐藏轮次不发）。`text` 是给旧客户端看的英文，不含服务商原文；新客户端按 `code` 用自己的话。
- 手机上，聊天里最新的一条（后面没有别的条目、Bot 没在干活、不是 `asked`）画成卡片：按 `code` 说清楚出了什么事，给「重试」（调 `resume`，和网页一样不重发消息）和能在手机上做的修复（填 Key、换模型、充值）；凭据类失败在 `blocked` 还在时不给重试。Bot 身上有同一个代码的 `blocked` 时，输入框上方已有修复卡片，聊天里只留一行。更早的失败只是一行字，点开看技术详情（代码、HTTP 状态码、请求 ID、原文），可以复制。

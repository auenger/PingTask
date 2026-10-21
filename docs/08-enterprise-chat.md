# 飞书与钉钉 Ping 来源接入

## 当前实现

- 按下 Ping 时固定鼠标位置对应的窗口与进程；用精确 Bundle ID 分流：微信 `com.tencent.xinWeChat`，本机飞书/Lark `com.electron.lark`、`com.larksuite.larkApp`，钉钉 `com.alibaba.DingTalkMac`。
- 单次读取辅助功能命中元素的 role。明确为文本输入控件时禁止自动查询。未知 role 不表示消息区域已验证；不使用固定左右比例猜测聊天区。
- 飞书设置支持 lark-cli 路径和 profile。留空 profile 时只接受唯一 active profile，之后固定该 profile，并在每次消息请求前后检查 appId、brand、user openId。
- 飞书群名通过 `im +chat-search` 精确匹配；歧义、候选截断、未知协议均停止。私聊暂需填写实际 `oc_...` chat_id。
- 使用 `im +chat-messages-list --as user --order desc --page-size 50 --no-reactions`，显式指定不超过 31 天的开始/结束时间。只读单页，不下载附件或展开话题。页面倒序获取后按时间正序展示。
- 用户选择消息后，以平台/profile/应用/用户/会话/消息生成稳定来源，附带此页前后各最多 5 条、每条最多 2000 字上下文。消息正文显示和保存最多 12000 字。分页截断始终标明。
- 意图的自动上下文开关可启动飞书查询，但飞书始终要求手动确认消息，再在任务记录提交；自动提交开关仍仅作用于已实现的微信流程。
- 钉钉目前完成窗口识别和 dws 路径配置。常见安装目录未发现 dws，尚未校验当前可执行 CLI 的消息输出契约，因此未启用消息查询，明确保留截图草稿。不能把它称为完整钉钉接入。

## 验证及限制

CLI 契约参考本机 lark-cli 1.0.63 help 和随附 lark-im 技能。当前用户登录已过期，未读取真实聊天消息；解析与身份检查使用隔离的合成 CLI fixture 验证。真实消息返回格式及用户权限仍需登录后验收，未知格式会安全停止。

窗口识别不等于消息区域识别。尚未实现完整 AX 控件树会话解析、可靠的聊天区分割、单聊名称解析、消息分页 UI、企业聊天附件导入。查询失败不会派发任务，不自动登录、不切换全局 profile、不安装或启动后台服务。

下一步：确认 dws 路径后读取 `chat +chat-search`、`chat +chat-messages` 的窄 schema，固定组织 profile，补充真实返回契约与合成测试，再启用钉钉消息候选和上下文预览。

## 来源核对面板预览

![飞书来源核对（合成消息，非真实查询结果）](images/enterprise-chat.png)

预览通过 `--render-desktop 10` 生成，使用虚构 profile、会话和消息；当前不模拟用户提交操作。

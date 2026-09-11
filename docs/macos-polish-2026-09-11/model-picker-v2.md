# 模型菜单参考对照与动画恢复

本次使用电脑工具读取独立离线原生预览，用内置 imagegen 生成目标稿，再修改 Flutter 自有输入区。生成稿不是实际运行截图。

- [调整前实装](before/28-model-reference.png)
- [ImageGen 目标稿](references/model-picker-v2.png)
- [调整后实装](after/28-model-reference.png)
- 恢复动画的两个时间点：[帧 A](after/29-animation-a.png)、[帧 B](after/29-animation-b.png)

## 调整依据

参考模型菜单约为 2 倍屏幕截图：约 255 点宽、16 点圆角、13 点常规文字、28 点单行节奏。实装使用 256 点宽、16 点圆角、13 点常规文字和 28 点最小行高，保留中性无描边 hover、浅细边与轻阴影；入口胶囊改为 28 点高，减小箭头并降低字重。模型选项直接展示，取消额外的 Model 子菜单。模型标题和底部强度入口保留清晰层级，弹层右边与入口对齐。

恢复原有 1800ms 循环粒子动画，包括速度、波动、透明度和粒子大小；保留拖动吸附与触觉反馈。图中的模型数量和文字由 Agent 能力决定，不虚构默认模型集或麦克风功能。实际模型内容与参考不同，因此没有以整张图的像素差宣称一致；检查重点为菜单形状、字体比例、留白、状态和入口层级。

验证：输入区 71 项通过，其中新增粒子随时间发出重绘通知的断言；应用模型、强度、权限选择 3 项通过。原生截图确认直接模型列表和恢复的动画。应用级强度测试直接调用菜单动作以隔离菜单关闭动画，真实点击已在原生预览复核。

## 内置 ImageGen 提示词

Use case: ui-mockup. Create a precise implementation target for the bottom right composer/model picker of image 1 using image 2 as the visual reference. Image 1 is current implementation; image 2 is the desired reference. Crop to this UI region for legible detail. Replace the unnecessary nested Model menu with a direct model list above the neutral pill. Match reference closely: white popup, thin pale gray outline, soft shadow, 16pt corner radius, 13pt regular model labels, 28pt row rhythm, inset neutral hover without outline, gray header Select model, checkmark right. Keep actual two model choices GPT-5 Codex and GPT-5, no fake models or default recommendation option. Keep a bottom separate Reasoning effort row with Medium and chevron so existing animated strength slider remains accessible. Keep actual app plus/shield/send functions, no microphone. Create a single crisp faithful target mockup, no explanatory arrows, no unrelated changes. Only minor stylistic differences from reference allowed.

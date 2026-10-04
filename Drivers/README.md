# Drivers

把要注入镜像的驱动放这个目录，然后在 Actions 里勾选 `drivers` 开关（AddDrivers）。

转换器会按这个结构找 `.inf`（目录不存在的分支会被跳过）：

```
Drivers/
├── ALL/     # 注入到所有镜像（install.wim + boot.wim）
├── OS/      # 只注入系统镜像（install.wim）
└── WinPE/   # 只注入 WinPE（boot.wim，装机阶段用，常见：存储/网卡驱动）
```

- 递归搜索 `.inf`，所以子目录层级随意
- 只放官方/可信来源的 `.inf`（厂商解压出来的 `Drivers` 目录整体拷进来即可）
- 不需要驱动就别勾这个开关；空目录勾了也没影响

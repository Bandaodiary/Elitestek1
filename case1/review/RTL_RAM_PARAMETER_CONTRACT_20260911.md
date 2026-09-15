# 公共同步 RAM 参数契约加固

`c1_ram_sdp_read_first` 被 resize、参数/配置银行、CNN 行缓存复用。
此前没有参数断言；零深度或不足的地址宽度可通过部分仿真器的 elaboration，
但不能表达预期存储空间。新增负测试在原代码上实际失败：DEPTH=0 未产生
预期诊断，测试输出 `C1_RAM_INVALID_PARAMETER_UNDETECTED`。

## 修改

- 在 `ifndef SYNTHESIS` 内检查 DATA_WIDTH、DEPTH 为正。
- 检查 ADDR_WIDTH 至少为 1，并不小于 `$clog2(DEPTH)`。
- 不限制深度为二次幂，保留深度 1；不修改 RAM 的读写时序或综合逻辑。
- 新增独立 testbench 及全量 runner 条目。非法参数的测试侧强制使用
  正数 cast 宽度，避免 testbench 自身先产生编译错误、掩盖 DUT 诊断。

## 结果

定向 7 配置通过：深度 1/3/8 的同址读写读旧值、下一拍读取新值、禁用读
时保持输出；深度 0、数据宽度 0、地址宽度 0/不足四项要求非零退出和
精确诊断。实际消费者 `tb_c1_s8_window3x3_same_c8` 1 配置通过，14 帧、
3325 输入、2330 输出及输入/输出背压检查通过。

尝试使用公共 runner 调用 parameter_bank 时返回 Unknown test top，没有
执行该测试；不将此视为参数银行验证通过。未执行其它消费者、全量回归、
整机或综合。本改动是仿真期 fail-fast，不是综合器参数合法性保证。
合法宽度仍允许表达非二次幂深度之外的地址；运行时越界访问仍由调用者
约束，本轮未新增运行时地址保护。

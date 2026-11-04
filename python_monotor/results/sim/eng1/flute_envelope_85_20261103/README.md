# 长笛轻起音、85%保持包络试听

A_STEP=248551，D_STEP=55924，S_LEVEL=1825361100，R_STEP=380283。
48kHz 下约180ms起音、120ms回落至85%、从85%约100ms释放。
不添加峰值停留阶段，保留原ADSR结构。气息关闭、腔体直通、混响NONE。
使用原ENG1定点模型完整重渲染，非在旧WAV上套曲线；生产RTL未修改。

- gentle_85.wav：新包络。
- original.wav：旧包络，首个长音0.8..1.5秒稳定段响度与新版对齐。
- comparison_original_then_gentle.wav：先旧后新，中间600ms静音。

固定增益，无压缩、EQ或逐段自动增益。短音可能在起音尚未完成时松键。
逐阶段时间、静音、轨限、WAV峰值和响度匹配检查见results.json。

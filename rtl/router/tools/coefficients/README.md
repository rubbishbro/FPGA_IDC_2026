# ENG0 系数源

- `eng0_piano.bin`：原钢琴矩阵系数，65536 字节。
- `eng0_guitar.bin`：原吉他矩阵及调制系数，131072 字节；前 65536 字节是原布局保留的擦除前缀，吉他数据从偏移 65536 开始。

这是当前六音色生成器仍读取的离线系数源，不是完整板级烧录镜像。本次只移动并重命名，未改字节。完整矩阵浮点源见 sythsound 的 piano_coeff_scaled.txt、guitar_coeff_scaled.txt 和 guitar_param.txt；旧打包脚本已删除。32音资源由 matrix_resources.py 优先保留已有量化记录，再从完整浮点源量化或对缺失低钢琴音做离线极点移调。完整板级镜像由上一级 performance_resources.py 生成。

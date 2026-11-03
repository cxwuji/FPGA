# 第4课验证用坏图：由 doc/test_bmp/test_2.bmp 派生，输出到 doc/test_bmp_bad/
#   test_2_badsig.bmp   签名 BM 改成 XX           -> 扫描时就不认，相当于卡上只有 3 张
#   test_2_800x600.bmp  宽高字段改成 800x600      -> 扫描跳过（2.3 整文件跳过）
#   test_2_badhdr.bmp   planes 改成 2             -> 扫描跳过（2.1 新增校验项）
# 用法（仓库根目录）：python -I tools/make_bad_bmp.py
import os
import struct

src = 'doc/test_bmp/test_2.bmp'
out = 'doc/test_bmp_bad'
os.makedirs(out, exist_ok=True)
b = bytearray(open(src, 'rb').read())


def save(name, data):
    open(os.path.join(out, name), 'wb').write(data)
    print('写入', name)


d = bytearray(b); d[0:2] = b'XX'; save('test_2_badsig.bmp', d)
d = bytearray(b); d[18:26] = struct.pack('<ii', 800, 600); save('test_2_800x600.bmp', d)
d = bytearray(b); d[26:28] = struct.pack('<H', 2); save('test_2_badhdr.bmp', d)

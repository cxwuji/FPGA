# 按 FPGA 的方式扫描 TF 卡物理扇区：列出前 64MB 内所有以 "BM" 开头的扇区（包括已删除文件的残留）
# 用法：python -I tools/scan_tf_raw.py G      （需要管理员权限才能读原始卷时会报错）
import struct
import sys

drive = sys.argv[1].rstrip(':') if len(sys.argv) > 1 else 'G'
f = open('\\\\.\\' + drive + ':', 'rb')
PART_OFFSET = 64            # 分区起始物理扇区（本卡 MBR 第一个分区从 64 开始）
for vs in range(0, 131072 - PART_OFFSET):
    b = f.read(512)
    if b[:2] == b'BM':
        w, h = struct.unpack('<ii', b[18:26])
        planes = struct.unpack('<H', b[26:28])[0]
        bpp = struct.unpack('<H', b[28:30])[0]
        print('物理扇区 %6d：%dx%d planes=%d bpp=%d 像素开头 %s' % (vs + PART_OFFSET, w, h, planes, bpp, b[54:60].hex()))

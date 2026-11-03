# 编辑后恢复换行符：未改动的行保留 HEAD 中原来的换行符（官方源文件 CRLF/LF 混用），
# 新增/修改的行统一用 CRLF。这样 git diff 只显示真正改动的行。
# 用法：python -I tools/keep_eol.py <文件> [<文件> ...]   （在仓库根目录运行）
import difflib
import subprocess
import sys


def main():
    for path in sys.argv[1:]:
        try:
            old_b = subprocess.run(['git', 'show', 'HEAD:' + path], check=True,
                                   capture_output=True).stdout
        except subprocess.CalledProcessError:
            old_b = b''  # 新文件：全部用 CRLF
        old = old_b.splitlines(keepends=True)
        new = open(path, 'rb').read().splitlines(keepends=True)
        strip = lambda l: l.rstrip(b'\r\n')
        sm = difflib.SequenceMatcher(None, [strip(l) for l in old],
                                     [strip(l) for l in new], autojunk=False)
        out = []
        for tag, i1, i2, j1, j2 in sm.get_opcodes():
            if tag == 'equal':
                out += old[i1:i2]
            else:
                out += [strip(l) + b'\r\n' for l in new[j1:j2]]
        open(path, 'wb').write(b''.join(out))
        print('eol ok:', path)


if __name__ == '__main__':
    main()

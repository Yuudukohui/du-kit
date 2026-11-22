"""
清理 DSH 桌面客户端堆积的 dsh-auth-* cookie（2026-11-17）

为什么要清：桌面端每次启动都用随机端口，Electron 会留一条
dsh-auth-<hash(host:port)> 的 cookie，30 天有效。攒到约 70 条时，
请求头超过上限 → 启动报 `desktop welcome: Web authentication failed`（HTTP 431）。

关键约束：客户端运行时 Cookies 库被 Chromium 独占，打不开。
所以这个脚本必须在 **DSH 完全退出后** 运行。

用法（在 DSH 关闭状态下）：
    python clean-cookies.py --check     只看有多少条，不删
    python clean-cookies.py --clean     删掉 dsh-auth-* 里过期的那些
    python clean-cookies.py --clean --all   全删 dsh-auth-*（会要求重新登录一次，没有别的损失）

它只动 name 以 dsh-auth- 开头的行，别的 cookie 一律不碰。
"""
import sqlite3
import sys
import os
import shutil
import time

DB = os.path.expandvars(r"%APPDATA%\@deepseek-ai\dsh-desktop\Network\Cookies")


def 打开():
    if not os.path.exists(DB):
        print(f"找不到 cookie 库：{DB}")
        sys.exit(2)
    # 先复制一份再打开，避免直接写原库（客户端可能只读占用）
    tmp = os.path.join(os.environ.get("TEMP", "."), f"cookies-{int(time.time())}.db")
    shutil.copy2(DB, tmp)
    return sqlite3.connect(tmp), tmp


def main():
    check = "--check" in sys.argv
    clean = "--clean" in sys.argv
    all_ = "--all" in sys.argv
    if not (check or clean):
        print(__doc__)
        return

    try:
        con, tmp = 打开()
    except PermissionError:
        print("打不开：客户端还开着。请先完全退出 DSH（含托盘），再跑一次。")
        sys.exit(3)

    rows = con.execute("select count(*), coalesce(sum(length(encrypted_value)),0) from cookies where name like 'dsh-auth-%'").fetchone()
    total = con.execute("select count(*) from cookies").fetchone()[0]
    条数, 字节 = rows
    print(f"cookie 总数: {total}")
    print(f"dsh-auth-* : {条数} 条，加密值合计 {字节} 字节")
    print(f"粗估请求头占用: {字节} 字节（上限约 16KB，接近就该清了）")
    if 条数 >= 60:
        print("⚠ 已经接近 431 的临界，建议清理")
    elif 条数 >= 30:
        print("提示: 有条目堆积，但还没到危险区")
    else:
        print("还早，暂时不用清")

    if clean:
        if all_:
            n = con.execute("delete from cookies where name like 'dsh-auth-%'").rowcount
        else:
            now = (time.time() + 11644473600) * 1000000  # 转 Chrome 的微秒时间
            n = con.execute("delete from cookies where name like 'dsh-auth-%' and expires_utc < ?", (int(now),)).rowcount
        con.commit()
        con.close()
        shutil.copy2(tmp, DB)  # 写回原库（此时客户端没开）
        os.remove(tmp)
        print(f"已删除 {n} 条")
    else:
        con.close()
        try:
            os.remove(tmp)
        except OSError:
            pass


if __name__ == "__main__":
    main()

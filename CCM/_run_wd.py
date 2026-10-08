"""VVP watchdog runner: hard limits on wall time and RSS, per project rule
(memory incident 22.6GB). Usage: python _run_wd.py <cmd...>"""
import subprocess, sys, time

MEM_LIMIT_MB = 2048
TIME_LIMIT_S = 300

def rss_mb_windows(pid):
    # fallback without psutil: parse tasklist output
    try:
        out = subprocess.run(['tasklist', '/FI', f'PID eq {pid}', '/FO', 'CSV', '/NH'],
                             capture_output=True, text=True, timeout=10).stdout
        parts = out.strip().split('","')
        if len(parts) >= 5:
            return float(parts[-1].replace('"', '').replace(',', '').replace(' K', '')) / 1024.0
    except Exception:
        pass
    return 0.0

def main():
    cmd = sys.argv[1:]
    log = open('sim_log.txt', 'w', encoding='utf-8', errors='replace')
    p = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT)
    try:
        import psutil
        proc = psutil.Process(p.pid)
    except Exception:
        proc = None
    t0 = time.time()
    killed = None
    while p.poll() is None:
        if time.time() - t0 > TIME_LIMIT_S:
            killed = 'TIME'
            break
        m = 0.0
        try:
            m = proc.memory_info().rss / 1048576.0 if proc else rss_mb_windows(p.pid)
        except Exception:
            m = 0.0
        if m > MEM_LIMIT_MB:
            killed = f'MEM {m:.0f}MB'
            break
        time.sleep(0.2)
    if killed:
        p.kill()
        print(f'[WATCHDOG] killed: {killed}')
    p.wait()
    log.close()
    print('exit =', p.returncode)

if __name__ == '__main__':
    main()

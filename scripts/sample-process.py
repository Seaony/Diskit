#!/usr/bin/env python3
"""只读采样指定进程的累计 CPU 时间与 RSS；不启动应用或操作界面。"""
import argparse
import json
from pathlib import Path
import subprocess
import time


def cpu_seconds(value):
    days, clock = value.split('-', 1) if '-' in value else ('0', value)
    fields = [float(item) for item in clock.split(':')]
    if len(fields) == 2:
        minutes, seconds = fields
        return int(days) * 86400 + minutes * 60 + seconds
    if len(fields) == 3:
        hours, minutes, seconds = fields
        return int(days) * 86400 + hours * 3600 + minutes * 60 + seconds
    raise ValueError('无法解析 ps 累计 CPU 时间')


def sample(pid):
    result = subprocess.run(['ps', '-p', str(pid), '-o', 'pid=,time=,rss='],
                            text=True, capture_output=True, check=False)
    fields = result.stdout.split()
    if result.returncode != 0 or len(fields) != 3 or int(fields[0]) != pid:
        raise RuntimeError('目标进程已退出，保留已采集样本')
    return {'monotonic_seconds': time.monotonic(), 'cpu_seconds': cpu_seconds(fields[1]),
            'rss_bytes': int(fields[2]) * 1024}


def summarize(samples):
    first, last = samples[0], samples[-1]
    elapsed = last['monotonic_seconds'] - first['monotonic_seconds']
    return {'duration_seconds': elapsed,
            'average_cpu_percent_one_core': (last['cpu_seconds'] - first['cpu_seconds']) / elapsed * 100 if elapsed > 0 else None,
            'rss_first_bytes': first['rss_bytes'], 'rss_last_bytes': last['rss_bytes'],
            'rss_delta_bytes': last['rss_bytes'] - first['rss_bytes'],
            'rss_peak_bytes': max(item['rss_bytes'] for item in samples)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--seconds', type=float, default=300)
    parser.add_argument('--interval', type=float, default=1)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.pid <= 0 or args.seconds <= 0 or args.interval <= 0:
        parser.error('PID、持续秒数和间隔必须为正数')
    samples = [sample(args.pid)]
    deadline = samples[0]['monotonic_seconds'] + args.seconds
    failure = None
    try:
        while time.monotonic() < deadline:
            time.sleep(min(args.interval, max(0, deadline - time.monotonic())))
            samples.append(sample(args.pid))
    except (RuntimeError, KeyboardInterrupt) as error:
        failure = str(error) or '采样被中断'
    report = {'pid': args.pid, 'source': 'ps cumulative CPU time and RSS; CPU 100% means one core',
              'requested_seconds': args.seconds, 'failure': failure,
              'summary': summarize(samples), 'samples': samples}
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report['summary'], ensure_ascii=False))
    if failure:
        raise SystemExit(failure)


if __name__ == '__main__':
    main()

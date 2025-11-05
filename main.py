import requests
import threading
import time
import random

BASE_URL = "http://alb-db-labs-1688413274.eu-north-1.elb.amazonaws.com"
ENDPOINTS = ["/health", "/docs", "/animators", "/agencies", "/events"]
CONCURRENCY = 8
DURATION = 300
TIMEOUT = 20

stop_flag = False
lock = threading.Lock()
ok = 0
err = 0


def worker(thread_id):
    global ok, err
    session = requests.Session()

    while not stop_flag:
        ep = random.choice(ENDPOINTS)
        url = BASE_URL + ep
        started = time.time()

        try:
            resp = session.get(url, timeout=TIMEOUT)
            elapsed = time.time() - started

            with lock:
                if resp.status_code == 200:
                    ok += 1
                    print(f"[Thread-{thread_id}]  {url} ({resp.status_code}) {elapsed*1000:.1f}ms")
                else:
                    err += 1
                    print(f"[Thread-{thread_id}] ⚠ {url} ({resp.status_code}) {elapsed*1000:.1f}ms")

        except Exception as e:
            elapsed = time.time() - started
            with lock:
                err += 1
                print(f"[Thread-{thread_id}]  {url} ERROR after {elapsed*1000:.1f}ms ({e})")


threads = []
print(f"Start load test for {DURATION}s with {CONCURRENCY} threads")
start = time.time()
print("...")

for i in range(CONCURRENCY):
    t = threading.Thread(target=worker, args=(i + 1,))
    t.start()
    threads.append(t)

time.sleep(DURATION)
stop_flag = True

for t in threads:
    t.join()

total = ok + err
elapsed = time.time() - start
print(f"\nDone in {elapsed:.1f}s")
print(f"Total requests: {total}")
print(f"OK: {ok}")
print(f"ERR: {err}")
print(f"RPS: {total / elapsed:.1f}")

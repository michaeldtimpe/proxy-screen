import socket, json, sys, time, os

sock_path = sys.argv[1]
out_png   = sys.argv[2]

def recv_json(f):
    line = f.readline()
    if not line:
        return None
    return json.loads(line)

def send(s, f, obj):
    s.sendall((json.dumps(obj) + "\n").encode())
    return recv_json(f)

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sock_path)
f = s.makefile("r")

greeting = recv_json(f)              # QMP greeting banner
print("GREETING:", json.dumps(greeting.get("QMP", {}).get("version", {})))

print("CAPS_REPLY:", json.dumps(send(s, f, {"execute": "qmp_capabilities"})))

t0 = time.time()
r = send(s, f, {"execute": "screendump",
                "arguments": {"filename": out_png, "format": "png"}})
t1 = time.time()
print("SCREENDUMP_REPLY:", json.dumps(r))
print("SCREENDUMP_LATENCY_MS: %.1f" % ((t1 - t0) * 1000.0))

# quit cleanly
try:
    s.sendall((json.dumps({"execute": "quit"}) + "\n").encode())
    time.sleep(0.3)
except Exception as e:
    print("QUIT_ERR:", e)
s.close()

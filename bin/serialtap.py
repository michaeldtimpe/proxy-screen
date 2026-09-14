import socket, sys, time
sock=sys.argv[1]; dur=float(sys.argv[2]) if len(sys.argv)>2 else 10.0
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.connect(sock); s.setblocking(False)
s.sendall(b"\n")
buf=b""; end=time.time()+dur
while time.time()<end:
    try:
        d=s.recv(65536)
        if d: buf+=d
    except BlockingIOError: time.sleep(0.2)
    except Exception: time.sleep(0.2)
sys.stdout.write(buf.decode("utf-8","replace"))
s.close()

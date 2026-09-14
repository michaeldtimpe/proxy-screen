import socket, sys, time
sock=sys.argv[1]; outf=sys.argv[2]; dur=float(sys.argv[3]) if len(sys.argv)>3 else 300.0
# retry connect until socket exists
end=time.time()+dur
s=None
while time.time()<end and s is None:
    try:
        s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.connect(sock)
    except Exception:
        s=None; time.sleep(0.5)
if s is None:
    open(outf,"a").write("[seriallog] could not connect\n"); sys.exit(1)
s.setblocking(False)
with open(outf,"ab",buffering=0) as fo:
    while time.time()<end:
        try:
            d=s.recv(65536)
            if d: fo.write(d)
        except BlockingIOError: time.sleep(0.2)
        except Exception: time.sleep(0.2)
s.close()

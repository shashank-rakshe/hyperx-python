"""run any script with the network blocked: python offline.py script.py args..."""
import socket, sys, runpy
def _blocked(*a, **k): raise RuntimeError('NETWORK ACCESS ATTEMPTED')
socket.socket.connect = _blocked; socket.create_connection = _blocked; socket.getaddrinfo = _blocked
sys.argv = sys.argv[1:]
runpy.run_path(sys.argv[0], run_name='__main__')

import socket
import struct
import os

DEST_IP = '10.0.6.3'
DEST_PORT = 54320

def build_default_msg():
    padding = '\x00\x00\x00\x00\x00\x00'
    data1_high = struct.pack('!I', 1)
    data1_low  = struct.pack('!I', 1)
    data2_high = struct.pack('!I', 1)
    data2_low  = struct.pack('!I', 1)
    return padding + data1_high + data1_low + data2_high + data2_low

def load_msg_from_file(file_path):
    f = None
    try:
        f = open(file_path, 'r')
        msg = ''

        for line in f:
            line = line.strip()
            if line == '' or line.startswith('#'):
                continue

            if len(line) != 16:
                raise ValueError("Invalid line length: %s" % line)

            hi = int(line[0:8], 16)
            lo = int(line[8:16], 16)

            msg = msg + struct.pack('!II', hi, lo)

        f.close()

        padding = '\x00\x00\x00\x00\x00\x00'
        return padding + msg

    except Exception, e:
        print "Failed to read file: %s" % e
        try:
            if f:
                f.close()
        except:
            pass
        return None

def main(use_file=1, file_path='data.txt'):
    if use_file and os.path.exists(file_path):
        msg = load_msg_from_file(file_path)
        if msg is None:
            print "Falling back to default message."
            msg = build_default_msg()
    else:
        msg = build_default_msg()

    #print("msg :", msg)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    try:
        sock.setsockopt(socket.SOL_SOCKET, 11, struct.pack('I', 1))
    except Exception, e:
        print "setsockopt failed (may not be supported): %s" % e

    sock.sendto(msg, (DEST_IP, DEST_PORT))
    print "Data sent."

if __name__ == '__main__':
    import sys as _sys
    if len(_sys.argv) > 1:
        main(use_file=1, file_path=_sys.argv[1])
    else:
        main(use_file=1, file_path='data.txt')

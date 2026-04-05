import socket
import struct

PORT = 54320
OUTFILE = 'received_data.txt'

def dump_payload_to_file(data, outfile):
    padding_len = 6
    if len(data) <= padding_len:
        return

    payload = data[padding_len:]
    f = open(outfile, 'w')

    i = 0
    while i + 8 <= len(payload):
        chunk = payload[i:i+8]
        high, low = struct.unpack('!II', chunk)
        f.write('%08x%08x\n' % (high, low))
        i = i + 8

    f.close()

def main():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(('', PORT))

    print 'Waiting for packet on port %d...' % PORT

    data, addr = sock.recvfrom(1024)
    print 'Received packet from %s:%d' % (addr[0], addr[1])

    dump_payload_to_file(data, OUTFILE)
    print 'Payload written to %s' % OUTFILE

    sock.close()

if __name__ == '__main__':
    main()

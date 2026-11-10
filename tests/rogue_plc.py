#!/usr/bin/env python3
"""
rogue_plc.py - loopback ISO-on-TCP / S7 test server for the snap7 client.

Regression test for the bounds checks of the snap7 client. It answers the
requests of a snap7 client (COTP connect, S7 negotiate, ReadArea, WriteArea,
SZL read) and, depending on the mode, deliberately sends malformed answers.
Run the client against it with an AddressSanitizer build and check that the
client reports an error code instead of corrupting memory.

Only client-side malformed answers are implemented. There is no server-side
or partner-side test here.

Usage:
    python rogue_plc.py --mode read_big [--port 102] [--host 127.0.0.1]
    python rogue_plc.py --sequence read_big,seq,normal    # one mode per connection

Modes (issue numbers refer to github.com/davenardella/snap7):
    normal          everything answered correctly (recovery check)
    read_big        ReadArea answer carries more data than requested (#31)
    read_claim      ReadArea answer claims more data than the telegram holds
    read_short      successful ReadArea answer with less data than requested
    neg_big         negotiate reply with PDU length 65535 (#17)
    neg_short       negotiate reply shorter than 20 bytes (no upstream issue)
    neg_long        negotiate reply longer than 20 bytes (no upstream issue)
    frag            one answer split into many small ISO fragments (#33)
    frag3           a correct answer in three ISO fragments (reassembly check, #33)
    seq             wrong Sequence in every answer
    szl_big         SZL answer slices that claim 32 KiB each (#11)
    szl_endless     SZL "not done" forever, 16 bytes per slice (no upstream issue)
    szl_endless0    SZL "not done" forever, no data per slice (no upstream issue)
"""
import argparse
import socket
import struct
import sys
import threading

MODES = ["normal", "read_big", "read_claim", "read_short", "neg_big",
         "neg_short", "neg_long", "frag", "frag3", "seq", "szl_big", "szl_endless",
         "szl_endless0"]

# S7 transport size (request) -> bytes per element
ELEM_SIZE = {0x01: 1, 0x02: 1, 0x03: 1, 0x04: 2, 0x05: 2, 0x06: 4,
             0x07: 4, 0x08: 4, 0x1C: 2, 0x1D: 2, 0x1E: 2}


def log(msg):
    print(msg, flush=True)


def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("peer closed")
        buf += chunk
    return buf


def recv_tpkt(sock):
    """Receive one TPKT frame, return the bytes after the 4 byte TPKT header."""
    hdr = recv_exact(sock, 4)
    if hdr[0] != 3:
        raise ConnectionError("not a TPKT header")
    length = struct.unpack(">H", hdr[2:4])[0]
    return recv_exact(sock, length - 4)


def tpkt(body):
    return struct.pack(">BBH", 3, 0, len(body) + 4) + body


def send_dt(sock, payload, eot=True):
    """One COTP DT telegram: length 2, type 0xF0, EoT flag in the last byte."""
    sock.sendall(tpkt(bytes([0x02, 0xF0, 0x80 if eot else 0x00]) + payload))


def send_fragments(sock, payload, size):
    """The same payload in many small ISO fragments (all but the last without EoT)."""
    parts = [payload[i:i + size] for i in range(0, len(payload), size)]
    for i, part in enumerate(parts):
        send_dt(sock, part, eot=(i == len(parts) - 1))


# ---------------------------------------------------------------- S7 answers

def s7_ack(seq, params, data=b"", err=0, ptype=3):
    """Ack-data header (12 bytes) + params + data. seq is passed through as 2 raw bytes."""
    return (bytes([0x32, ptype, 0, 0]) + seq +
            struct.pack(">HHH", len(params), len(data), err) + params + data)


def answer_negotiate(seq, mode):
    pdu = 65535 if mode == "neg_big" else 480
    params = bytes([0xF0, 0x00, 0x00, 0x01, 0x00, 0x01]) + struct.pack(">H", pdu)
    pkt = s7_ack(seq, params)
    if mode == "neg_short":
        pkt = pkt[:14]                  # header + 2 bytes of params
    elif mode == "neg_long":
        pkt = pkt + b"\x00\x00"
    return pkt


def pattern(start, n):
    return bytes((start + i) & 0xFF for i in range(n))


def answer_read(seq, req, mode):
    # item: 12 0A 10 ts len(2) db(2) area addr(3) at offset 12
    ts = req[15]
    amount = struct.unpack(">H", req[16:18])[0]
    addr = int.from_bytes(req[21:24], "big") >> 3
    n = amount * ELEM_SIZE.get(ts, 1)
    data = pattern(addr, n)
    claimed = n
    if mode == "read_big":
        claimed = n + 1000              # more data than requested, really sent
        data = pattern(addr, claimed)
    elif mode == "read_claim":
        claimed = n + 1000              # claims more than the telegram holds
    elif mode == "read_short":
        claimed = n // 2
        data = data[:claimed]
    # return code 0xFF (ok), transport size 4 = byte (length in bits)
    item = bytes([0xFF, 0x04]) + struct.pack(">H", claimed * 8) + data
    return s7_ack(seq, bytes([0x04, 0x01]), item)


def answer_write(seq):
    return s7_ack(seq, bytes([0x05, 0x01]), bytes([0xFF]))


def szl_params(seq_in, last):
    # 00 01 12 | plen 8 | 12 | 84 = response/SZL | subfunction | seq | 0, last-unit flag | err 0
    return bytes([0x00, 0x01, 0x12, 0x08, 0x12, 0x84, 0x01, seq_in,
                  0x00, 0x00 if last else 0x01, 0x00, 0x00])


def s7_userdata(seq, params, data):
    return (bytes([0x32, 0x07, 0, 0]) + seq +
            struct.pack(">HH", len(params), len(data)) + params + data)


def szl_content(szl_id):
    """A plausible SZL body (header LENTHDR, N_DR, then records)."""
    body = bytearray(214)
    if szl_id == 0x001C:                # CPU info: names at the offsets snap7 reads
        body[6:6 + 24] = b"ROGUE-PLC".ljust(24, b"\0")
        body[40:40 + 24] = b"Rogue module".ljust(24, b"\0")
        body[142:142 + 24] = b"S C-ROGUE0000001".ljust(24, b"\0")
        body[176:176 + 32] = b"CPU 000-0AA00".ljust(32, b"\0")
    elif szl_id == 0x0424:              # CPU status: opData[7] = 8 -> RUN
        body[7] = 0x08
    struct.pack_into(">HH", body, 0, 34, 6)
    return bytes(body)


def answer_szl(seq, req, state, mode):
    first = req[13] == 0x04                 # params length 4 = first request, 8 = next
    seq_in = state.get("szl_seq", 0)
    if first:
        state["szl_id"] = struct.unpack(">H", req[22:24])[0]
    state["szl_seq"] = (seq_in + 1) & 0xFF

    if mode in ("szl_big", "szl_endless", "szl_endless0"):
        # never "done"; the slice length is what the mode is about
        if mode == "szl_big":
            dlen, body = 0x8000, b"\x00" * 16   # claims 32 KiB, holds 16 bytes
        elif mode == "szl_endless":
            dlen, body = 16, b"\x00" * 16
        else:
            dlen, body = 0, b""
        if first:
            # Ret, TS, DLen (incl. the 4 bytes ID/Index), ID, Index, body
            data = bytes([0xFF, 0x09]) + struct.pack(">HHH", dlen + 4, state["szl_id"], 0) + body
        else:
            data = bytes([0xFF, 0x09]) + struct.pack(">H", dlen) + body
        return s7_userdata(seq, szl_params(state["szl_seq"], False), data)

    body = szl_content(state["szl_id"])
    data = bytes([0xFF, 0x09]) + struct.pack(">HHH", len(body) + 4, state["szl_id"], 0) + body
    return s7_userdata(seq, szl_params(state["szl_seq"], True), data)


# ------------------------------------------------------------- connection

def serve_connection(sock, mode, peer):
    state = {}
    log("[%s] connection, mode=%s" % (peer, mode))
    try:
        while True:
            body = recv_tpkt(sock)
            ptype = body[1]
            if ptype == 0xE0:                   # connection request -> confirm
                cc = bytes.fromhex("11d00001000100c0010ac1020100c2020102")
                sock.sendall(tpkt(cc))
                log("[%s] COTP connect" % peer)
                continue
            if ptype == 0x80:                   # disconnect request
                return
            if ptype != 0xF0:
                log("[%s] unexpected COTP type %02x" % (peer, ptype))
                return
            req = body[3:]                      # S7 payload
            seq = req[4:6]
            kind = req[1]
            reply = None
            what = "?"
            if kind == 0x01 and req[10] == 0xF0:
                what = "negotiate"
                reply = answer_negotiate(seq, mode)
            elif kind == 0x01 and req[10] == 0x04:
                what = "read"
                reply = answer_read(seq, req, mode)
            elif kind == 0x01 and req[10] == 0x05:
                what = "write"
                reply = answer_write(seq)
            elif kind == 0x07:
                what = "szl"
                reply = answer_szl(seq, req, state, mode)
            if reply is None:
                log("[%s] unhandled request %s" % (peer, req[:12].hex()))
                return
            if mode == "seq" and what in ("read", "write", "szl"):
                # wrong sequence: flip all bits of the echoed value
                reply = reply[:4] + bytes(b ^ 0xFF for b in seq) + reply[6:]
            log("[%s] %s -> %d bytes" % (peer, what, len(reply)))
            if mode == "frag" and what == "read":
                # 60 fragments of 64 bytes: a valid S7 header, then filler. The client
                # reassembles them into one telegram of 3840 bytes.
                send_fragments(sock, reply[:12] + b"\x00" * (3840 - 12), 64)
            elif mode == "frag3" and what == "read":
                # a correct answer in three ISO fragments: must be reassembled intact
                send_fragments(sock, reply, (len(reply) + 2) // 3)
            else:
                send_dt(sock, reply)
    except (ConnectionError, OSError) as e:
        log("[%s] closed (%s)" % (peer, e))
    finally:
        sock.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=102)
    ap.add_argument("--mode", choices=MODES, default="normal")
    ap.add_argument("--sequence", help="comma separated modes, one per accepted connection; "
                                       "the last one stays for all later connections")
    args = ap.parse_args()
    modes = args.sequence.split(",") if args.sequence else [args.mode]
    for m in modes:
        if m not in MODES:
            ap.error("unknown mode " + m)

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((args.host, args.port))
    srv.listen(5)
    log("rogue_plc listening on %s:%d, modes=%s" % (args.host, args.port, ",".join(modes)))
    count = 0
    while True:
        conn, addr = srv.accept()
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        mode = modes[min(count, len(modes) - 1)]
        count += 1
        threading.Thread(target=serve_connection, args=(conn, mode, "%s:%d" % addr),
                         daemon=True).start()


if __name__ == "__main__":
    sys.exit(main())

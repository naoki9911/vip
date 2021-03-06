module main

import rand
import time
import net.unix

const (
    tcp_fin = 0b000001
    tcp_syn = 0b000010
    tcp_rst = 0b000100
    tcp_psh = 0b001000
    tcp_ack = 0b010000
    tcp_urg = 0b100000
)
struct TcpHdr {
mut:
    src_port u16
    dst_port u16
    seq_num u32
    ack_num u32
    data_offset int
    control_flags u8
    window_size u16
    chksum u16
    urg_ptr u16
    options []TcpOptionInterface = []TcpOptionInterface{}
}

interface TcpOptionInterface {
    kind byte
    length byte
    to_string() string
}
enum TcpOptionKind {
    nop = 0x1
    mss = 0x2
    window_scale = 0x3
    sack_permitted = 0x4
    timestamp = 0x8
}

struct TcpOptionBase {
    kind byte
mut:
    length byte
}

struct TcpOptionNop {
    TcpOptionBase
}

struct TcpOptionMss {
    TcpOptionBase
    mss u16
}

struct TcpOptionWindowScale {
    TcpOptionBase
    window_scale byte
}

struct TcpOptionSackPermitted {
    TcpOptionBase
}

struct TcpOptionTimestamp {
    TcpOptionBase
    timestamp u32
    timestamp_echo_reply u32
}

fn parse_tcp_hdr(buf []byte) ?TcpHdr {
    assert buf.len >=  20
    mut tcp_hdr := TcpHdr {
        src_port : be16(buf[0..2])
        dst_port : be16(buf[2..4])
        seq_num : be_bytes_to_u32(buf[4..8]) ?
        ack_num : be_bytes_to_u32(buf[8..12]) ?
        data_offset: (buf[12] >> 4) * 4
        control_flags : (buf[13])
        window_size : be16(buf[14..16])
        chksum : be16(buf[16..18])
        urg_ptr : be16(buf[18..20])
    }
    assert buf.len >= tcp_hdr.data_offset
    for i := 20; i < tcp_hdr.data_offset; {
        if buf[i] == 0 {
            break
        }
        if buf[i] == byte(TcpOptionKind.nop) {
            i += 1
            continue
        }
        tcp_option := parse_tcp_option(buf[i..]) ?
        tcp_hdr.options << tcp_option  
        i += tcp_option.length
    }

    return tcp_hdr
}

fn parse_tcp_option(buf []byte) ?TcpOptionInterface {
    assert buf.len >= 1
    mut base := TcpOptionBase {
        kind: buf[0]
    }
    if base.kind == byte(TcpOptionKind.nop) {
        return TcpOptionNop {
            kind: byte(TcpOptionKind.nop)
            length: 1
        }
    }
    base.length = buf[1]
    if base.kind == byte(TcpOptionKind.mss) {
        assert buf.len >= 4
        return TcpOptionMss {
            TcpOptionBase: base
            mss: be16(buf[2..4])
        }
    }
    if base.kind == byte(TcpOptionKind.window_scale) {
        assert buf.len >= 3
        return TcpOptionWindowScale {
            TcpOptionBase: base
            window_scale: buf[2]
        }
    }
    if base.kind == byte(TcpOptionKind.sack_permitted) {
        assert buf.len >= 2
        return TcpOptionSackPermitted {
            TcpOptionBase: base
        }
    }
    if base.kind == byte(TcpOptionKind.timestamp) {
        assert buf.len >= 10
        return TcpOptionTimestamp {
            TcpOptionBase: base
            timestamp: be_bytes_to_u32(buf[2..6]) ?
            timestamp_echo_reply: be_bytes_to_u32(buf[6..10]) ?
        }
    }
    return base
}

fn (th &TcpHdr) to_bytes() []byte {
    mut buf := []byte{len:th.data_offset}

    copy(buf[0..2], be_u16_to_bytes(th.src_port))
    copy(buf[2..4], be_u16_to_bytes(th.dst_port))
    copy(buf[4..8], be_u32_to_bytes(th.seq_num))
    copy(buf[8..12], be_u32_to_bytes(th.ack_num))
    buf[12] = byte((th.data_offset / 4) << 4)
    buf[13] = th.control_flags
    copy(buf[14..16], be_u16_to_bytes(th.window_size))
    copy(buf[16..18], be_u16_to_bytes(th.chksum))
    copy(buf[18..20], be_u16_to_bytes(th.urg_ptr))

    return buf
}

fn (th &TcpHdr) control_flag_to_string() string {
    mut s := "["
    mut flag := th.control_flags
    if flag & tcp_fin > 0 {
        s += "FIN,"
        flag &= ~(tcp_fin)
    }
    if flag & tcp_syn > 0 {
        s += "SYN,"
        flag &= ~(tcp_syn)
    }
    if flag & tcp_rst > 0 {
        s += "RST,"
        flag &= ~(tcp_rst)
    }
    if flag & tcp_psh > 0 {
        s += "PSH,"
        flag &= ~(tcp_psh)
    }
    if flag & tcp_ack > 0 {
        s += "ACK,"
        flag &= ~(tcp_ack)
    }
    if flag & tcp_urg > 0 {
        s += "URG,"
        flag &= ~(tcp_urg)
    }
    if flag > 0 {
        s += "0b${flag:06b},"
    }
    if s.len != 1 {
        s = s[..s.len-1]
    }
    s += "]"
    return s
}

fn (th &TcpHdr) to_string() string {
    mut s := "src_port:${th.src_port} "
    s += "dst_port:${th.dst_port} "
    s += "seq_num:0x${th.seq_num:04X} "
    s += "ack_num:0x${th.ack_num:04X} "
    s += "data_offset:${th.data_offset} "
    s += "control_flags:${th.control_flag_to_string()} "
    s += "window_size:${th.window_size} "
    s += "chksum:0x${th.chksum:04X} "
    s += "urg_ptr:0x${th.urg_ptr:04X} "
    s += "options:["
    for option in th.options {
        s += option.to_string() + ","
    }
    s = s[..s.len-1] + "]"

    return s
}

fn (to &TcpOptionBase) to_string() string {
    return "kind:${to.kind} len:${to.length}"
}

fn (to &TcpOptionNop) to_string() string {
    return to.TcpOptionBase.to_string()
}

fn (to &TcpOptionMss) to_string() string {
    return to.TcpOptionBase.to_string() + " mss:${to.mss}"
}

fn (to &TcpOptionWindowScale) to_string() string {
    return to.TcpOptionBase.to_string() + " window scale:${to.window_scale}"
}

fn (to &TcpOptionTimestamp) to_string() string {
    mut s := to.TcpOptionBase.to_string() + " "
    s += "timestamp:${to.timestamp} "
    s += "timestamp_echo_reply:${to.timestamp_echo_reply}"
    return s
}

fn (to &TcpOptionSackPermitted) to_string() string {
    return to.TcpOptionBase.to_string()
}

enum TcpState {
    syn_sent
    closed
    established
    close_wait
    last_ack
    fin_wait_1
    fin_wait_2
    closing
    time_out
}

struct TcpOps {
    msg IpcMsg
mut:
    ipc_sock unix.StreamConn
}

struct TcpSession {
mut:
    state TcpState
    peer_addr AddrInfo
    seq_num u32
    ack_num u32
    mss int = 1400
    recv_ring TcpRingBuffer
    send_data []byte
    send_data_base_num u32
    last_send_pkt Packet
    retransmit bool
    retransmit_num int
    read_request_is_pending bool
    read_ops TcpOps
    ack_is_pending bool
}

struct TcpRingBuffer {
mut:
    data []byte
    bitmap []bool
    base_seq_num u32
    read_idx_base int
}

fn new_tcp_ring_buffer(buffer_size int, init_seq_num u32) TcpRingBuffer {
    return TcpRingBuffer {
        data: []byte{len:buffer_size}
        bitmap: []bool{len:buffer_size}
        base_seq_num: init_seq_num
    }
} 

fn (mut r TcpRingBuffer) write(seq_num u32, write_data []byte) ? {
    if write_data.len >= r.data.len {
        return error("write data over buffer length")
    }
    mut write_idx := int(0)
    if seq_num > r.base_seq_num {
        write_idx = int(seq_num - r.base_seq_num)
    } else {
        write_idx = int(u64(0x100000000) - u64(r.base_seq_num - seq_num))
    }
    write_idx = (write_idx + r.read_idx_base) % r.data.len
    println("Write seq ${seq_num} at ${write_idx} size ${write_data.len}")

    mut init := true
    for d in write_data {
        if !init && write_idx == r.read_idx_base {
            return error("buffer is full!!")
        }
        r.data[write_idx] = d
        r.bitmap[write_idx] = true
        write_idx = (write_idx + 1) % r.data.len
        init = false
    }
}

fn (mut r TcpRingBuffer) read(max_size int) []byte {
    mut buf := []byte{}
    read_idx_base := r.read_idx_base
    for i := 0; i < max_size; i += 1 {
        idx := (i + read_idx_base) % r.data.len
        if r.bitmap[idx] {
            r.bitmap[idx] = false
            r.read_idx_base = (idx + 1) % r.data.len
            r.base_seq_num += 1
            buf << r.data[idx]
        } else {
            break
        }
    }

    return buf
}

fn (r &TcpRingBuffer) get_ack_num() u32 {
    return r.base_seq_num + u32(r.get_readable_size())
}

fn (r &TcpRingBuffer) get_readable_size() int {
    mut readable_size := 0
    for i := 0; i < r.data.len; i += 1 {
        read_idx := (r.read_idx_base + i) % r.data.len
        if !r.bitmap[read_idx] {
            break
        }
        readable_size += 1
    }
    return readable_size
}

fn (r &TcpRingBuffer) is_partially_lost() bool {
    mut continuous := true
    mut lost_start_idx := 0
    for i := 0; i < r.data.len; i += 1 {
        read_idx := (r.read_idx_base + i) % r.data.len
        if !r.bitmap[read_idx] && continuous {
            continuous = false
            lost_start_idx = read_idx
        }

        if r.bitmap[read_idx] && !continuous {
            println("[TCP RING] partially lost (start:${lost_start_idx} end:${read_idx})")
            return true
        }
    }

    return false
}

fn (r &TcpRingBuffer) get_used_size() int {
    mut used_size := 0
    for i := 0; i < r.data.len; i += 1 {
        read_idx := (r.read_idx_base + i) % r.data.len
        if r.bitmap[read_idx] {
            used_size += 1
        }
    }

    return used_size
}

fn (r &TcpRingBuffer) get_free_size() int {
    return r.data.len - r.get_used_size()
}

fn (nd &NetDevice) handle_tcp_sock(shared sock Socket) {
    mut sock_chan := TcpSocketChans{}
    mut fd := 0
    rlock {
        sock_chan = sock.tcp_chans
    }
    mut session := TcpSession{
        state: TcpState.closed
    }
    mut pkt := Packet{}
    for {
        mut port := u16(0)
        mut ttl := 0
        mut nodelay := false
        mut nonblock := false
        mut domain := 0
        rlock sock {
            port = sock.port
            ttl = sock.ttl
            nodelay = sock.option_tcp_nodelay
            nonblock = sock.option_fd_nonblock
            domain = sock.domain
        }
        select {
            pkt = <- sock_chan.read_chan {
                if domain == C.AF_INET {
                    recv_ipv4_hdr := pkt.l3_hdr.get_ipv4_hdr() or {continue}
                    if recv_ipv4_hdr.src_addr != session.peer_addr.ipv4 {
                        continue
                    }
                } else if domain == C.AF_INET6 {
                    recv_ipv6_hdr := pkt.l3_hdr.get_ipv6_hdr() or {continue}
                    if recv_ipv6_hdr.src_addr != session.peer_addr.ipv6 {
                        continue
                    }
                }

                recv_tcp_hdr := pkt.l4_hdr.get_tcp_hdr() or {continue}
                if recv_tcp_hdr.src_port != session.peer_addr.port {
                    continue
                }
                if session.state == TcpState.syn_sent {
                    if recv_tcp_hdr.control_flags ^ (tcp_syn|tcp_ack) != 0 {
                        continue
                    }
                    if recv_tcp_hdr.ack_num != session.seq_num + 1 {
                        continue
                    }
                    println("[TCP $fd] SYNACK received(SEQ_NUM:${recv_tcp_hdr.seq_num} ACK_NUM:${recv_tcp_hdr.ack_num})")
                    session.seq_num = recv_tcp_hdr.ack_num
                    session.ack_num = recv_tcp_hdr.seq_num + 1
                    session.recv_ring = new_tcp_ring_buffer(20000, session.ack_num)
                    mut tcp_hdr := TcpHdr {
                        src_port : port
                        dst_port : session.peer_addr.port
                        seq_num : session.seq_num
                        ack_num : session.ack_num
                        data_offset : 20
                        control_flags : u8(tcp_ack)
                        window_size: u16(session.recv_ring.get_free_size())
                    }
                    mut send_pkt := Packet{}
                    send_pkt.l4_hdr = tcp_hdr
                    if domain == C.AF_INET {
                        nd.send_ipv4(mut send_pkt, &session.peer_addr, ttl) or {println("failed to send ack")}
                    } else if domain == C.AF_INET6 {
                        nd.send_ipv6(mut send_pkt, &session.peer_addr, 255) or {println("failed to send ack")}
                    }
                    session.last_send_pkt = pkt
                    session.send_data_base_num = session.seq_num
                    session.state = TcpState.established
                    println("[TCP $fd] Session established")
                    rlock sock {
                        if !sock.option_fd_nonblock {
                            sock_chan.control_chan <- TcpOps{}
                        }
                    }
                } else if session.state == TcpState.established {
                    if recv_tcp_hdr.control_flags & tcp_ack > 0 && session.seq_num != recv_tcp_hdr.ack_num {
                        session.seq_num = recv_tcp_hdr.ack_num
                        mut buf_idx := int(0)
                        if session.seq_num > session.send_data_base_num {
                            buf_idx = int(session.seq_num - session.send_data_base_num)
                        } else {
                            buf_idx = int(u64(0x100000000) - u64(session.send_data_base_num - session.seq_num))
                        }
                        session.send_data = session.send_data[buf_idx..]
                        session.send_data_base_num = session.seq_num
                        println("[TCP $fd] Recv ack for send data(size:${buf_idx})")
                    }
                    mut seq_diff := recv_tcp_hdr.seq_num - session.recv_ring.base_seq_num
                    if session.recv_ring.base_seq_num  > recv_tcp_hdr.seq_num {
                        seq_diff = u32(u64(0x100000000) - u64(session.recv_ring.base_seq_num - recv_tcp_hdr.seq_num))
                    }

                    if seq_diff < 0x7FFFFFFFFFFFFFFF {
                        session.recv_ring.write(recv_tcp_hdr.seq_num, pkt.payload) or {println("buffer corrupt!")}
                        println("[TCP $fd] Recv data(size:${pkt.payload.len})")
                        println("[TCP $fd] Readable size:${session.recv_ring.get_readable_size()}")
                    }
                    if session.read_request_is_pending && session.recv_ring.get_readable_size() > 0 {
                        msg := session.read_ops.msg.msg
                        match msg {
                            IpcMsgRead {
                                println("HOGEHOGE")
                                nd.tcp_read(msg, mut session, mut session.read_ops.ipc_sock, shared sock) or {println("[TCP $fd] failed to read")}
                                println("[TCP $fd] Read success")
                                sock_chan.control_chan <- session.read_ops
                                session.read_request_is_pending = false
                                println("[TCP $fd] Pended read request is done.")
                            }
                            else {}
                        }
                    }
                    session.ack_num = session.recv_ring.get_ack_num()

                    if recv_tcp_hdr.control_flags & tcp_fin > 0 {
                        session.state = TcpState.close_wait
                        session.ack_num += 1
                    }
                    mut tcp_hdr := TcpHdr {
                        src_port : port
                        dst_port : session.peer_addr.port
                        seq_num : session.seq_num
                        ack_num : session.ack_num
                        data_offset : 20
                        control_flags : u8(tcp_ack)
                        window_size: u16(session.recv_ring.get_free_size())
                    }
                    mut send_pkt := Packet{}
                    send_pkt.l4_hdr = tcp_hdr
                    session.last_send_pkt = send_pkt
                    session.retransmit = session.recv_ring.is_partially_lost()
                    if ((recv_tcp_hdr.control_flags & tcp_psh > 0 || nodelay) && (pkt.payload.len > 0)) || session.ack_is_pending {
                        if sock_chan.read_chan.len == 0 {
                            if domain == C.AF_INET {
                                nd.send_ipv4(mut send_pkt, &session.peer_addr, ttl) or {println("failed to send ack")}
                            } else if domain == C.AF_INET6 {
                                nd.send_ipv6(mut send_pkt, &session.peer_addr, 255) or {println("failed to send ack")}
                            }
                            session.ack_is_pending = false
                        } else {
                            session.ack_is_pending = true
                        }
                    } 
                }
            }
            mut op := <- sock_chan.control_chan {
                msg := op.msg.msg
                match msg {
                    IpcMsgSocket {
                        rlock {
                            fd = sock.fd
                        }
                        session = TcpSession {
                            state: TcpState.closed
                        }
                    }
                    IpcMsgConnect {
                        println("[TCP $fd] Connect")
                        rlock sock {
                            if sock.option_fd_nonblock {
                                sock_chan.control_chan <- op
                            }
                        }
                        nd.tcp_connect(msg, mut session, shared sock) or {println("[TCP $fd] failed to connect")}
                    }
                    IpcMsgPoll {
                        println("[TCP $fd] Poll")
                        nd.tcp_poll(msg, session, mut op.ipc_sock, shared sock) or {println("[TCP $fd] failed to poll")}
                        println("[TCP $fd] Poll success")
                        sock_chan.control_chan <- op
                    }
                    IpcMsgSockopt {
                        if msg.msg_type == C.IPC_GETSOCKOPT {
                            println("[TCP $fd] Getsockopt")
                            nd.tcp_getsockopt(msg, session, mut op.ipc_sock, shared sock) or {println("[TCP $fd] failed to getsockopt")}
                            println("[TCP $fd] Getsockopt success")
                            sock_chan.control_chan <- op
                        }
                    }
                    IpcMsgSockname {
                        if msg.msg_type == C.IPC_GETPEERNAME {
                            println("[TCP $fd] Getpeername")
                            nd.tcp_getpeername(msg, session, mut op.ipc_sock, shared sock) or {println("[TCP $fd] failed to getpeername")}
                            println("[TCP $fd] Getpeername success")
                            sock_chan.control_chan <- op
                        }
                    }
                    IpcMsgSendto {
                        println("[TCP $fd] Sendto")
                        nd.tcp_sendto(msg, mut session, shared sock) or {println("[TCP $fd] failed to sendto")}
                        println("[TCP $fd] Sendto success")
                        sock_chan.control_chan <- op
                    }
                    IpcMsgRead {
                        println("[TCP $fd] Read")
                        if session.recv_ring.get_readable_size() == 0 && !nonblock {
                            println("[TCP $fd] No readable data. Read request is pended")
                            session.read_request_is_pending = true
                            session.read_ops = op
                        } else {
                            nd.tcp_read(msg, mut session, mut op.ipc_sock, shared sock) or {println("[TCP $fd] failed to read")}
                            println("[TCP $fd] Read success")
                            sock_chan.control_chan <- op
                        }
                    }
                    IpcMsgClose {
                        println("[TCP $fd] Close")
                        nd.tcp_close(msg, mut session, &sock_chan, shared sock) or {println("[TCP $fd] failed to close")}
                        println("[TCP $fd] Close success")
                        sock_chan.control_chan <- op
                    }
                    IpcMsgWrite {
                        println("[TCP $fd] Write")
                        nd.tcp_write(msg, mut session, shared sock) or {println("[TCP $fd] failed to write")}
                        println("[TCP $fd] Write success")
                        sock_chan.control_chan <- op
                    }
                    else {}
                }
            }
            100 * time.millisecond {
                if session.retransmit && session.state != TcpState.closed {
                    if session.state == TcpState.established && session.retransmit_num < 10 {
                        println("[TCP $fd] Retransmission")
                        if domain == C.AF_INET {
                            nd.send_ipv4(mut session.last_send_pkt, &session.peer_addr, ttl) or {println("failed to send ack")}
                        } else if domain == C.AF_INET6 {
                            nd.send_ipv6(mut session.last_send_pkt, &session.peer_addr, 255) or {println("failed to send ack")}
                        }
                        session.retransmit = session.recv_ring.is_partially_lost() || session.send_data.len != 0
                        println("[TCP $fd] IsPartiallyLost:${session.recv_ring.is_partially_lost()}")
                        println("[TCP $fd] send_data.len:${session.send_data.len}")
                        session.retransmit_num += 1
                    } else {
                        session.retransmit = false
                        session.retransmit_num = 0
                    }
                }
            }
        }
    }
}

fn (nd &NetDevice) tcp_connect(msg &IpcMsgConnect, mut session TcpSession, shared sock Socket) ? {
    mut port := u16(0)
    mut ttl := 0
    mut domain := 0
    rlock sock {
        port = sock.port
        ttl = sock.ttl
        domain = sock.domain
    }
    mut dst_addr := AddrInfo{}
    session.seq_num = u16(rand.u32())
    mut tcp_hdr := TcpHdr {
        src_port : port
        dst_port : dst_addr.port
        seq_num : session.seq_num
        ack_num : 0
        data_offset : 20
        control_flags : u8(tcp_syn)
        window_size: 4000
    }
    mut pkt := Packet{}
    addr := msg.addr.addr
    match addr {
        SockAddrIn {
            dst_addr.ipv4 = addr.sin_addr
            dst_addr.port = addr.sin_port
            tcp_hdr.dst_port = dst_addr.port
            pkt.l4_hdr = tcp_hdr
            nd.send_ipv4(mut pkt, &dst_addr, ttl)?
        } 
        SockAddrIn6 {
            dst_addr.ipv6 = addr.sin6_addr
            dst_addr.port = addr.sin6_port
            tcp_hdr.dst_port = dst_addr.port
            pkt.l4_hdr = tcp_hdr
            nd.send_ipv6(mut pkt, &dst_addr, 255)?
        }
        else {}
    }
    session.state = TcpState.syn_sent
    session.peer_addr = dst_addr
    session.last_send_pkt = pkt
}

fn (nd &NetDevice) tcp_poll(msg &IpcMsgPoll, session &TcpSession, mut ipc_sock unix.StreamConn,  shared sock Socket) ? {
    mut res := *msg
    mut rc := 0
    for mut fd in res.fds {
        fd.revents = 0
        if fd.events & u16(C.POLLOUT | C.POLLWRNORM) > 0 {
            if session.state == TcpState.established {
                fd.revents |= fd.events & u16(C.POLLOUT | C.POLLWRNORM)
            }
        }
        if fd.events & u16(C.POLLIN) > 0 {
            if session.state != TcpState.closed && (session.recv_ring.get_readable_size() > 0){
                fd.revents |= fd.events & u16(C.POLLIN)
            }
        }
    }

    for fd in res.fds {
        if fd.revents > 0 {
            rc += 1
        }
    }
    res_msg := IpcMsgError {
        IpcMsgBase : msg.IpcMsgBase
        rc : rc
        err : 0
        data : res.to_bytes()[msg.IpcMsgBase.len+12..]
    }
    println("[IPC Poll] return ${res.to_string()}")
    ipc_sock.write(res_msg.to_bytes()) ?
}

fn (nd &NetDevice) tcp_getsockopt(msg &IpcMsgSockopt, session &TcpSession, mut ipc_sock unix.StreamConn, shared sock Socket) ? {
    mut res_sockopt := IpcMsgSockopt {
        IpcMsgBase : msg.IpcMsgBase
        fd : msg.fd
        level : msg.level
        optname : msg.optname
        optlen : msg.optlen
    }
    if msg.level == C.SOL_IP {

    } else if msg.level == C.SOL_SOCKET {
        if msg.optname == C.SO_ERROR {
            error_code := 0
            mut optval := []byte{len:4}
            copy(optval, int_to_bytes(error_code))
            res_sockopt.optval = optval
            res_msg := IpcMsgError {
                IpcMsgBase : msg.IpcMsgBase
                rc : 0
                err : 0
                data : res_sockopt.to_bytes()[msg.IpcMsgBase.len..]
            }
            ipc_sock.write(res_msg.to_bytes()) ?
            return
        }
    }
    res_msg := IpcMsgError {
        IpcMsgBase : msg.IpcMsgBase
        rc : -1
        err : C.ENOPROTOOPT
    }
    println("[IPC Getsockopt] not supported option ${msg.to_string()}")
    ipc_sock.write(res_msg.to_bytes()) ?
}

fn (nd &NetDevice) tcp_getpeername(msg &IpcMsgSockname, session &TcpSession, mut ipc_sock unix.StreamConn, shared sock Socket) ? {

    mut res_sockname := IpcMsgSockname {
        IpcMsgBase : msg.IpcMsgBase
        socket: msg.socket
    }

    mut domain := 0
    rlock sock {
        domain = sock.domain
    }

    if domain == C.AF_INET {
        mut sockaddr := SockAddrIn {
            family: u16(C.AF_INET)
            sin_addr: session.peer_addr.ipv4
            sin_port: session.peer_addr.port
        }
        res_sockname.address_len = u32(sockaddr.len)
        res_sockname.data = sockaddr.to_bytes()
    } else if domain == C.AF_INET6 {
        mut sockaddr := SockAddrIn6 {
            sin6_family: u16(C.AF_INET6)
            sin6_addr: session.peer_addr.ipv6
            sin6_port: session.peer_addr.port
        }
        res_sockname.address_len = u32(sockaddr.len)
        res_sockname.data = sockaddr.to_bytes()
    }

    mut res_msg := IpcMsgError {
        IpcMsgBase : msg.IpcMsgBase
        rc : 0
        err : 0
        data : res_sockname.to_bytes()[msg.IpcMsgBase.len..]
    }

    println("[IPC Sockname] response addr")
    ipc_sock.write(res_msg.to_bytes()) ?
}

fn (nd &NetDevice) tcp_sendto(msg &IpcMsgSendto, mut session &TcpSession, shared sock Socket) ? {
    mut port := u16(0)
    mut ttl := 0
    mut domain := 0
    rlock sock {
        port = sock.port
        ttl = sock.ttl
        domain = sock.domain
    }
    for i := 0; i < msg.buf.len; i += session.mss {
        mut tcp_hdr := TcpHdr {
            src_port : port
            dst_port : session.peer_addr.port
            seq_num : u32(session.send_data_base_num + u32(session.send_data.len))
            ack_num : session.ack_num
            data_offset : 20
            control_flags : u8(tcp_psh|tcp_ack)
            window_size: 4000
        }
        mut send_pkt := Packet{}
        send_pkt.l4_hdr = tcp_hdr
        mut data_size := session.mss
        if i + data_size > msg.buf.len {
            data_size = msg.buf.len - i
        }
        send_pkt.payload = msg.buf[i..i+data_size]
        session.send_data << msg.buf[i..i+data_size]
        if domain == C.AF_INET {
            nd.send_ipv4(mut send_pkt, &session.peer_addr, ttl)?
        } else if domain == C.AF_INET6 {
            nd.send_ipv6(mut send_pkt, &session.peer_addr, 255)?
        }
        session.last_send_pkt = send_pkt
        session.retransmit = true
    }
}

fn (nd &NetDevice) tcp_write(msg &IpcMsgWrite, mut session &TcpSession, shared sock Socket) ? {
    mut port := u16(0)
    mut ttl := 0
    mut domain := 0
    rlock sock {
        port = sock.port
        ttl = sock.ttl
        domain = sock.domain
    }
    for i := 0; i < msg.buf.len; i += session.mss {
        mut tcp_hdr := TcpHdr {
            src_port : port
            dst_port : session.peer_addr.port
            seq_num : u32(session.send_data_base_num + u32(session.send_data.len))
            ack_num : session.ack_num
            data_offset : 20
            control_flags : u8(tcp_psh|tcp_ack)
            window_size: 4000
        }
        mut send_pkt := Packet{}
        send_pkt.l4_hdr = tcp_hdr
        mut data_size := session.mss
        if i + data_size > msg.buf.len {
            data_size = msg.buf.len - i
        }
        send_pkt.payload = msg.buf[i..i+data_size]
        session.send_data << msg.buf[i..i+data_size]
        if domain == C.AF_INET {
            nd.send_ipv4(mut send_pkt, &session.peer_addr, ttl)?
        } else if domain == C.AF_INET6 {
            nd.send_ipv6(mut send_pkt, &session.peer_addr, 255)?
        }
        session.last_send_pkt = send_pkt
        session.retransmit = true
    }
}

fn (nd &NetDevice) tcp_read(msg &IpcMsgRead, mut session TcpSession, mut ipc_sock unix.StreamConn, shared sock Socket) ? {
    mut res := *msg

    res.buf = session.recv_ring.read(int(msg.len))
    res.len = u64(res.buf.len)
    res_msg := IpcMsgError {
        IpcMsgBase : msg.IpcMsgBase
        rc : res.buf.len
        err : 0
        data : res.to_bytes()[msg.IpcMsgBase.len..]
    }
    ipc_sock.write(res_msg.to_bytes()) ?
    println("[TCP] Read len:${res.buf.len}")
}

fn (nd &NetDevice) tcp_close(msg &IpcMsgClose, mut session TcpSession, sock_chan &TcpSocketChans, shared sock Socket) ? {
    mut port := u16(0)
    mut ttl := 0
    mut domain := 0
    rlock sock {
        port = sock.port
        ttl = sock.ttl
        domain = sock.domain
    }

    mut tcp_hdr := TcpHdr {
        src_port : port
        dst_port : session.peer_addr.port
        seq_num : session.seq_num
        ack_num : session.ack_num
        data_offset : 20
        control_flags : u8(tcp_ack|tcp_fin)
        window_size: 4000
    }
    mut pkt := Packet{}
    pkt.l4_hdr = tcp_hdr
    if domain == C.AF_INET {
        nd.send_ipv4(mut pkt, &session.peer_addr, ttl)?
    } else if domain == C.AF_INET6 {
        nd.send_ipv6(mut pkt, &session.peer_addr, 255)?
    }
    session.last_send_pkt = pkt
    if session.state == TcpState.close_wait {
        session.state = TcpState.last_ack
    } else if session.state == TcpState.established {
        session.state = TcpState.fin_wait_1
    }

    for {
        select {
            pkt_recv := <- sock_chan.read_chan {
                recv_tcp_hdr := pkt_recv.l4_hdr.get_tcp_hdr() ?
                if session.state == TcpState.last_ack {
                    if recv_tcp_hdr.ack_num != session.seq_num + 1 {
                        continue
                    }
                    if recv_tcp_hdr.seq_num != session.ack_num {
                        continue
                    }
                    if recv_tcp_hdr.control_flags & (tcp_ack) != tcp_ack {
                        continue
                    }

                    println("[TCP $msg.sockfd] Connection closed")
                    session.state = TcpState.closed
                    return
                }
                if session.state == TcpState.fin_wait_1 {
                    if recv_tcp_hdr.ack_num != session.seq_num + 1 {
                        continue
                    }
                    session.seq_num = recv_tcp_hdr.ack_num
                    if recv_tcp_hdr.seq_num != session.ack_num {
                        continue
                    }
                    if recv_tcp_hdr.control_flags & (tcp_ack) != tcp_ack {
                        continue
                    }
                    if recv_tcp_hdr.control_flags & (tcp_fin) != tcp_fin {
                        session.state = TcpState.fin_wait_2
                    }

                    session.state = TcpState.closing
                    session.ack_num += 1
                    tcp_hdr.seq_num = session.seq_num
                    tcp_hdr.ack_num = session.ack_num
                    tcp_hdr.control_flags = u8(tcp_ack)
                    pkt.l4_hdr = tcp_hdr
                    if domain == C.AF_INET {
                        nd.send_ipv4(mut pkt, &session.peer_addr, ttl)?
                    } else if domain == C.AF_INET6 {
                        nd.send_ipv6(mut pkt, &session.peer_addr, 255)?
                    }
                    session.last_send_pkt = pkt
                    session.state = TcpState.closed
                    return
                }
            }   
            3 * time.second {
                if domain == C.AF_INET {
                    nd.send_ipv4(mut pkt, &session.peer_addr, ttl)?
                } else if domain == C.AF_INET6 {
                    nd.send_ipv6(mut pkt, &session.peer_addr, 255)?
                }
                session.last_send_pkt = pkt
            }
        }
    }
}
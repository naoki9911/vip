module main

import time
import net.unix

#include "@VMODROOT/liblevelip/ipc.h"

struct Socket {
mut:
    pid int
    fd int
    domain int
    sock_type int
    protocol int
    port u16
    sock_chans SocketChans
}

struct IpcSocket {
mut:
    stream unix.StreamConn
}

struct SocketChans {
    read_chan chan Packet
}

fn new_socket_chans() SocketChans {
    return SocketChans {
        read_chan : chan Packet{cap: 10}
    }
}

type IpcMsgType = IpcMsgBase | IpcMsgSocket | IpcMsgConnect | IpcMsgSockname | IpcMsgClose | IpcMsgSockopt | IpcMsgWrite | IpcMsgSendto | IpcMsgRecvmsg | IpcMsgPoll

struct IpcMsg {
    msg IpcMsgType
}

struct IpcMsgBase {
    len int = 6
    msg_type u16
    pid int
}

struct IpcMsgSocket {
    IpcMsgBase
    domain int
    sock_type int
    protocol int
}

struct IpcMsgError {
    IpcMsgBase
mut:
    rc int
    err int
    data []byte
}

struct IpcMsgConnect {
    IpcMsgBase
    sockfd int
    addr SockAddr
    addrlen u32
}

struct IpcMsgSockname {
    IpcMsgBase
    socket int
    address_len u32
    data []byte
}

struct IpcMsgClose {
    IpcMsgBase
    sockfd int
}

struct IpcMsgSockopt {
    IpcMsgBase
    fd int
    level int
    optname int
    optlen u32
mut:
    optval []byte
}

struct IpcMsgWrite {
    IpcMsgBase
    sockfd int
    len u64
mut:
    buf []byte
}

struct IpcMsgSendto {
    IpcMsgBase
    sockfd int
    flags int
    addrlen u32
mut:
    addr SockAddr
    len u64
    buf []byte
}

struct IpcMsgRecvmsg {
    IpcMsgBase
    sockfd int
    flags int
    msg_flags int
    msg_controllen u64
    msg_iovlen u64
mut:
    msg_namelen u32
    msg_iovs_len []u64
    addr SockAddr
    recvmsg_cmsghdr []byte
    iov_data [][]byte
}

struct IpcMsgPollfd {
    fd int
    events u16
mut:
    revents u16
}

struct IpcMsgPoll {
    IpcMsgBase
    nfds u64
    timeout int
mut:
    fds []IpcMsgPollfd
}

fn bytes_to_u16(buf []byte) ?u16 {
    assert buf.len == 2
    return buf[0] | buf[1] << 8
}

fn bytes_to_int(buf []byte) ?int {
    assert buf.len == 4
    return buf[0] | buf[1] << 8 | buf[2] << 16 | buf[3] << 24
}

fn bytes_to_u32(buf []byte) ?u32 {
    assert buf.len == 4
    return buf[0] | buf[1] << 8 | buf[2] << 16 | buf[3] << 24
}

fn bytes_to_u64(buf []byte) ?u64 {
    assert buf.len == 8
    mut tmp := u64(0)
    tmp |= buf[0] | buf[1] << 8 | buf[2] << 16 | buf[3] << 24
    tmp |= buf[4] << 32 | buf[5] << 40 | buf[6] << 48 | buf[7] << 56
    return tmp
}

fn parse_ipc_msg(buf []byte) ?IpcMsg {
    assert buf.len >= 6
    base := IpcMsgBase {
        msg_type : buf[0] | buf[1] << 8
        pid : bytes_to_int(buf[2..6]) ?
    }
    println("PARSED msg_type:${base.msg_type:04X}")

    if base.msg_type == C.IPC_SOCKET {
        assert buf.len >= 18
        return IpcMsg {
            msg: IpcMsgSocket {
                IpcMsgBase : base
                domain : bytes_to_int(buf[6..10]) ?
                sock_type : bytes_to_int(buf[10..14]) ?
                protocol : bytes_to_int(buf[14..18]) ?
            }
        }
    }
    if base.msg_type == C.IPC_CONNECT {
        assert buf.len >= 30
        return IpcMsg {
            msg: IpcMsgConnect {
                IpcMsgBase: base
                sockfd : bytes_to_int(buf[6..10]) ?
                addr : parse_sockaddr(buf[10..26]) ?
                addrlen: bytes_to_u32(buf[26..30]) ?
            }
        }
    }

    if base.msg_type == C.IPC_GETSOCKNAME {
        assert buf.len >= 142
        return IpcMsg {
            msg: IpcMsgSockname {
                IpcMsgBase: base
                socket: bytes_to_int(buf[6..10]) ?
                address_len : bytes_to_u32(buf[10..14]) ?
                data : buf[14..142]
            }
        }
    }

    if base.msg_type == C.IPC_CLOSE {
        assert buf.len >= 10
        return IpcMsg {
            msg: IpcMsgClose {
                IpcMsgBase: base
                sockfd: bytes_to_int(buf[6..10]) ?
            }
        }
    }

    if base.msg_type == C.IPC_GETSOCKOPT {
        assert buf.len >= 22
        return IpcMsg {
            msg: IpcMsgSockopt{
                IpcMsgBase: base
                fd: bytes_to_int(buf[6..10]) ?
                level: bytes_to_int(buf[10..14]) ?
                optname: bytes_to_int(buf[14..18]) ?
                optlen: bytes_to_u32(buf[18..22]) ?
                optval: buf[22..]
            }
        }
    }

    if base.msg_type == C.IPC_WRITE {
        assert buf.len >= 14
        mut msg := IpcMsgWrite {
            IpcMsgBase : base
            sockfd : bytes_to_int(buf[6..10]) ?
            len : bytes_to_u64(buf[10..18]) ?
        }
        msg.buf = buf[18..18 + msg.len]
        return IpcMsg {
            msg : msg
        }
    }

    if base.msg_type == C.IPC_SENDTO {
        mut msg := IpcMsgSendto {
            IpcMsgBase : base
            sockfd : bytes_to_int(buf[6..10]) ?
            flags : bytes_to_int(buf[10..14]) ?
            addrlen : bytes_to_u32(buf[14..18]) ?
        }
        msg.addr = parse_sockaddr(buf[18..18 + int(msg.addrlen)]) ?
        mut offset := 18 + int(msg.addrlen)
        msg.len = bytes_to_u64(buf[offset..offset+8]) ?
        offset += 8
        msg.buf = buf[offset..u64(offset) + msg.len]
        return IpcMsg {
            msg: msg
        }
    }

    if base.msg_type == C.IPC_RECVMSG {
        mut msg := IpcMsgRecvmsg {
            IpcMsgBase : base
            sockfd : bytes_to_int(buf[6..10]) ?
            flags : bytes_to_int(buf[10..14]) ?
            msg_flags : bytes_to_int(buf[14..18]) ?
            msg_namelen : bytes_to_u32(buf[18..22]) ?
            msg_controllen : bytes_to_u64(buf[22..30]) ?
            msg_iovlen : bytes_to_u64(buf[30..38]) ?
        }
        for i := 0; i < msg.msg_iovlen; i += 1 {
            msg.msg_iovs_len << bytes_to_u64(buf[38 + i*8..46 + i*8]) ?
        }
        return IpcMsg {
            msg: msg
        }
    }

    if base.msg_type == C.IPC_POLL {
        mut msg := IpcMsgPoll {
            IpcMsgBase: base
            nfds : bytes_to_u64(buf[6..14]) ?
            timeout: bytes_to_int(buf[14..18]) ?
            fds : []IpcMsgPollfd{}
        }
        for i := 0; i < msg.nfds; i += 1 {
            offset := 18 + i*8
            poolfd := IpcMsgPollfd {
                fd : bytes_to_int(buf[offset..offset+4]) ?
                events : bytes_to_u16(buf[offset+4..offset+6]) ?
                revents : bytes_to_u16(buf[offset+6..offset+8]) ?
            }
            msg.fds << poolfd
        }

        return IpcMsg {
            msg : msg
        }
    }

    return IpcMsg {
        msg : base
    }
}

fn (im IpcMsgBase) to_bytes() []byte {
    mut buf := []byte{len: 6}
    buf[0] = byte(im.msg_type)
    buf[1] = byte(im.msg_type >> 8)
    buf[2] = byte(im.pid)
    buf[3] = byte(im.pid >> 8)
    buf[4] = byte(im.pid >> 16)
    buf[5] = byte(im.pid >> 24)
    
    return buf
}

fn (im IpcMsgError) to_bytes() []byte {
    mut base_bytes := im.IpcMsgBase.to_bytes()
    mut buf := []byte{len: 8}
    buf[0] = byte(im.rc)
    buf[1] = byte(im.rc >> 8)
    buf[2] = byte(im.rc >> 16)
    buf[3] = byte(im.rc >> 24)
    buf[4] = byte(im.err)
    buf[5] = byte(im.err >> 8)
    buf[6] = byte(im.err >> 16)
    buf[7] = byte(im.err >> 24)

    base_bytes << buf
    base_bytes << im.data

    return base_bytes
}

fn (im IpcMsgSockname) to_bytes() []byte {
    mut base_bytes := im.IpcMsgBase.to_bytes()
    mut buf := []byte{len: 136}
    buf[0] = byte(im.socket)
    buf[1] = byte(im.socket >> 8)
    buf[2] = byte(im.socket >> 16)
    buf[3] = byte(im.socket >> 24)
    buf[4] = byte(im.address_len)
    buf[5] = byte(im.address_len >> 8)
    buf[6] = byte(im.address_len >> 16)
    buf[7] = byte(im.address_len >> 24)

    mut data_size := im.data.len
    if data_size >= 128 {
        data_size = 128
    }
    for i := 0; i < data_size; i += 1 {
        buf[i+8] = im.data[i]
    }

    base_bytes << buf
    return  base_bytes
}

fn (im IpcMsgSockopt) to_bytes() []byte {
    mut base_bytes := im.IpcMsgBase.to_bytes()
    mut buf := []byte{len:16 + int(im.optlen)}
    buf[0] = byte(im.fd)
    buf[1] = byte(im.fd >> 8)
    buf[2] = byte(im.fd >> 16)
    buf[3] = byte(im.fd >> 24)
    buf[4] = byte(im.level)
    buf[5] = byte(im.level >> 8)
    buf[6] = byte(im.level >> 16)
    buf[7] = byte(im.level >> 24)
    buf[8] = byte(im.optname)
    buf[9] = byte(im.optname >> 8)
    buf[10] = byte(im.optname >> 16)
    buf[11] = byte(im.optname >> 24)
    buf[12] = byte(im.optlen)
    buf[13] = byte(im.optlen >> 8)
    buf[14] = byte(im.optlen >> 16)
    buf[15] = byte(im.optlen >> 24)

    mut data_size := im.optval.len
    if data_size > im.optlen {
        data_size = int(im.optlen)
    }
    for i := 0; i < data_size; i += 1 {
        buf[i+16] = im.optval[i]
    }

    base_bytes << buf
    return base_bytes
}

fn (im IpcMsgRecvmsg) to_bytes() ?[]byte {
    mut base_bytes := im.IpcMsgBase.to_bytes()
    mut iov_len_sum := u64(0)
    for iov_len in im.msg_iovs_len {
        iov_len_sum += iov_len
    }

    mut buf := []byte{len:32 + int(im.msg_iovs_len.len*8) + int(im.msg_namelen) + int(im.msg_controllen) + int(iov_len_sum)}
    for i := 0; i < 4; i += 1 {
        buf[i] = byte(im.sockfd >> i*8)
    }
    for i := 0; i < 4; i += 1 {
        buf[i+4] = byte(im.flags >> i*8)
    }
    for i := 0; i < 4; i += 1 {
        buf[i+8] = byte(im.msg_flags >> i*8)
    }
    for i := 0; i < 4; i += 1 {
        buf[i+12] = byte(im.msg_namelen >> i*8)
    }
    for i := 0; i < 8; i += 1 {
        buf[i+16] = byte(im.msg_controllen >> i*8)
    }
    for i := 0; i < 8; i += 1 {
        buf[i+24] = byte(im.msg_iovlen >> i*8)
    }
    for j := 0; j < im.msg_iovs_len.len; j += 1 {
        for i := 0; i < 8; i += 1 {
            buf[32+j*8+i] = byte(im.msg_iovs_len[j] >> i*8)
        }
    }
    mut offset := 32 + im.msg_iovs_len.len*8
    sockaddr := im.addr.addr
    match sockaddr {
        SockAddrIn {
            sockaddr_bytes := sockaddr.to_bytes()
            assert sockaddr_bytes.len == 16
            for i := 0; i < 16; i += 1 {
                buf[offset+i] = sockaddr_bytes[i]
            }
            offset += int(im.msg_namelen)
        }
        else { return error("not expected sockaddr")}
    }
    mut cmsghdr_size := im.recvmsg_cmsghdr.len
    if cmsghdr_size > im.msg_controllen {
        cmsghdr_size = int(im.msg_controllen)
    }
    for i := 0; i < cmsghdr_size; i += 1 {
        buf[offset+i] = im.recvmsg_cmsghdr[i]
    }
    offset += int(im.msg_controllen)
    mut iov_num := im.iov_data.len
    if iov_num > im.msg_iovlen {
        iov_num = int(im.msg_iovlen)
    }
    for j := 0; j < iov_num; j += 1 {
        iov_buf := im.iov_data[j]
        mut iov_buf_len := iov_buf.len
        if iov_buf_len > im.msg_iovs_len[j] {
            iov_buf_len = int(im.msg_iovs_len[j])
        }
        for i := 0; i < iov_buf_len; i += 1 {
            buf[offset+i] = iov_buf[i]
        }
        offset += int(im.msg_iovs_len[j])
    }

    base_bytes << buf
    return base_bytes
}

fn (im IpcMsgPoll) to_bytes() []byte {
    mut base_bytes := im.IpcMsgBase.to_bytes()
    mut buf := []byte{len:12 + int(im.nfds*8)}

    for i := 0; i < 8; i += 1 {
        buf[i] = byte(im.nfds >> i*8)
    }
    for i := 0; i < 4; i += 1 {
        buf[i+8] = byte(im.timeout >> i*8)
    }
    mut offset := 12
    for j := 0; j < im.fds.len; j += 1 {
        fd := im.fds[j]
        for i := 0; i < 4; i += 1 {
            buf[offset+i] = byte(fd.fd >> i*8)
        }
        buf[offset+4] = byte(fd.events)
        buf[offset+5] = byte(fd.events >> 8)
        buf[offset+6] = byte(fd.revents)
        buf[offset+7] = byte(fd.revents >> 8)
        offset += 8
    }
    
    base_bytes << buf
    return base_bytes
}

fn (im IpcMsgBase) to_string() string {
    mut s := "type:0x${im.msg_type:04X} "
    s += "pid:${im.pid}"

    return s
}

fn (im IpcMsgSocket) to_string() string {
    mut s := im.IpcMsgBase.to_string() + " "
    s += "domain:${domain_to_string(im.domain)} "
    s += "type:${type_to_string(im.sock_type)} "
    s += "protocol:${protocol_to_string(im.protocol)}"

    return s
}

fn (im IpcMsgConnect) to_string() string {
    mut s := im.IpcMsgBase.to_string() + " "
    s += "sockfd:${im.sockfd} "
    s += "addr:${im.addr.to_string()} "
    s += "addrlen:${im.addrlen}"

    return s
}

fn (im IpcMsgSockopt) to_string() string {
    mut s := im.IpcMsgBase.to_string() + " "
    s += "fd:${im.fd} "
    s += "level:${level_to_string(im.level)} "
    s += "optname:${optname_to_string(im.optname)} "
    s += "optlen:${im.optlen} "

    return s
}

fn (im IpcMsgWrite) to_string() string {
    mut s := im.IpcMsgBase.to_string() + " "
    s += "sockfd:${im.sockfd} "
    s += "len:${im.len}"

    return s
}

fn (im IpcMsgSendto) to_string() string {
    mut s := im.IpcMsgBase.to_string() + " "
    s += "sockfd:${im.sockfd} "
    s += "flags:${im.flags} "
    s += "addrlen:${im.addrlen} "
    s += "addr:${im.addr.to_string()} "
    s += "len:${im.len}"

    return s
}

fn (im IpcMsgRecvmsg) to_string() string {
    mut s := im.IpcMsgBase.to_string() + " "
    s += "sockfd:${im.sockfd} "
    s += "flags:${im.flags} "
    s += "msg_flags:${im.msg_flags} "
    s += "msg_namelen:${im.msg_namelen} "
    s += "msg_controllen:${im.msg_controllen} "
    s += "msg_iovlen:${im.msg_iovlen} "
    s += "msg:iovs_len:${im.msg_iovs_len}"

    return s
}

fn (im IpcMsgPoll) to_string() string {
    mut s := im.IpcMsgBase.to_string() + " "
    s += "nfds:${im.nfds} "
    s += "timeout:${im.timeout} "
    for fd in im.fds {
        s += "[fd:${fd.fd} "
        s += "events:${events_to_string(fd.events)} "
        s += "revents:${events_to_string(fd.revents)}]"
    }
    return s
}

fn (nd NetDevice) handle_control_usock(usock_path string) {
    mut l := unix.listen_stream(usock_path) or { panic(err) }
    for {
        mut new_conn := l.accept() or { continue }
        println("new conn")
        nd.ipc_sock_chan <- IpcSocket {
            stream : new_conn
        }
    }
}

fn domain_to_string(domain int) string {
    if domain == C.AF_INET {
        return "AF_INET"
    }
    return "$domain"
}

fn type_to_string(sock_type int) string {
    if sock_type == C.SOCK_DGRAM {
        return "SOCK_DGRAM"
    }
    return "$sock_type"
}

fn protocol_to_string(protocol int) string {
    if protocol == C.IPPROTO_ICMP {
        return "IPPROTO_ICMP"
    }
    if protocol == C.IPPROTO_IP {
        return "IPPROTO_IP"
    }
    return "$protocol"
}

fn level_to_string(level int) string {
    if level == C.SOL_SOCKET {
        return "SOL_SOCKET"
    }
    return "$level"
}

fn optname_to_string(opt int) string {
    if opt == C.SO_RCVBUF {
        return "SO_RCVBUF"
    }
    return "$opt"
}

fn events_to_string(events u16) string {
    mut s := ""
    mut e := events
    for {
        old_e := e
        if e & u16(C.POLLIN) > 0 {
            s += "|POLLIN"
            e &= ~u16(C.POLLIN)
        }

        if e == 0 {
            break
        }

        if old_e == e {
            s += " 0x${e}"
            break
        }
    }

    if s == "" {
        return ""
    } else {
        return s[1..]
    }
}

fn (shared sock Socket) handle_data(ipc_sock IpcSocket, nd &NetDevice, shared sock_shared SocketShared) {
    mut conn := ipc_sock.stream
    for {
        mut buf := []byte{len: 8192, init: 0}
        count := conn.read(mut buf) or {
            println('Server: connection drppped')
            break
        }
        if count <= 0 {
            continue
        }
        println("recv size:${count}")
        ipc_msg := parse_ipc_msg(buf) or { continue }
        msg := ipc_msg.msg
        match msg {
            IpcMsgBase {

            }
            IpcMsgSocket {
                sock.handle_socket(&msg, mut conn, nd, shared sock_shared) or { continue }
            }
            IpcMsgConnect {
                sock.handle_connect(&msg, mut conn, nd, shared sock_shared) or { continue }
            }
            IpcMsgSockname {
                sock.handle_sockname(&msg, mut conn, nd, shared sock_shared) or { continue }
            }
            IpcMsgClose {
                sock.handle_close(&msg, mut conn, nd, shared sock_shared) or { continue }
                break
            }
            IpcMsgSockopt {
                sock.handle_sockopt(&msg, mut conn, nd, shared sock_shared) or { continue }
            }
            IpcMsgWrite {
                sock.handle_write(&msg, mut conn, nd, shared sock_shared) or { continue }
            }
            IpcMsgSendto {
                sock.handle_sendto(&msg, mut conn, nd, shared sock_shared) or { continue }
            }
            IpcMsgRecvmsg {
                sock.handle_recvmsg(&msg, mut conn, nd, shared sock_shared) or { continue }
            }
            IpcMsgPoll {
                sock.handle_poll(&msg, mut conn, nd, shared sock_shared) or { continue }
            }
        }
    }

    println("[IPC] socket closed")
}

fn (shared sock Socket) handle_socket(msg &IpcMsgSocket, mut ipc_sock unix.StreamConn, nd &NetDevice, shared sock_shared SocketShared) ? {
    println("[IPC Socket] ${msg.to_string()}")

    mut fd := 0
    mut port := u16(0)
    lock sock_shared {
        fd = sock_shared.fd_base
        port = sock_shared.udp_port_base
        sock_shared.fd_base += 1
        sock_shared.udp_port_base += 1
    }

    lock sock {
        sock.pid = msg.pid
        sock.fd = fd
        sock.domain = msg.domain
        sock.sock_type = msg.sock_type
        sock.protocol = msg.protocol
        sock.port = port
    }

    res_msg := IpcMsgError {
        IpcMsgBase : msg.IpcMsgBase
        rc : fd
        err : 0
    }

    println("[IPC Socket] Assigned socket(fd:${fd})")
    res_msg_bytes := res_msg.to_bytes()
    ipc_sock.write(res_msg_bytes) ?
}

fn (shared sock Socket) handle_connect(msg &IpcMsgConnect, mut ipc_sock unix.StreamConn, nd &NetDevice, shared sock_shared SocketShared) ? {
    println("[IPC Connect] ${msg.to_string()}")

    mut pkt := Packet {
        payload : []byte{len:100}
    }

    dst_addr := AddrInfo {
        mac: nd.my_mac
        ipv4: nd.my_ip
        port: sock.port
    }

    mut success := true
    mut port := u16(0)
    lock sock {
        port = sock.port
    }
    nd.send_udp(mut pkt, &dst_addr, port) or { success = false }

    if !success {
        res_msg := IpcMsgError {
            IpcMsgBase : msg.IpcMsgBase
            rc : -1
            err : C.ETIMEDOUT
        }
        println("[IPC Connect] connect failed")
        ipc_sock.write(res_msg.to_bytes()) ?
    } else {
        res_msg := IpcMsgError {
            IpcMsgBase : msg.IpcMsgBase
            rc : 0
        }
        println("[IPC Connect] connect success")
        ipc_sock.write(res_msg.to_bytes()) ?
    }

}

fn (shared sock Socket) handle_sockname(msg &IpcMsgSockname, mut ipc_sock unix.StreamConn, nd &NetDevice, shared sock_shared SocketShared) ? {
    println("[IPC Sockname] ${msg.to_string()}")

    if msg.msg_type != C.IPC_GETSOCKNAME {
        return
    }

    mut sockaddr := SockAddrIn {
        family: u16(C.AF_INET)
        sin_addr: nd.my_ip
    }
    lock sock {
        sockaddr.sin_port = sock.port
    }

    mut res_sockname := IpcMsgSockname {
        IpcMsgBase : msg.IpcMsgBase
        socket: msg.socket
        address_len : u32(sockaddr.len)
        data: sockaddr.to_bytes()
    }

    mut res_msg := IpcMsgError {
        IpcMsgBase : msg.IpcMsgBase
        rc : 0
        err : 0
        data : res_sockname.to_bytes()[msg.IpcMsgBase.len..]
    }

    println("[IPC Sockname] response addr(${sockaddr.to_string()})")
    ipc_sock.write(res_msg.to_bytes()) ?
}

fn (shared sock Socket) handle_close(msg &IpcMsgClose, mut ipc_sock unix.StreamConn, nd &NetDevice, shared sock_shared SocketShared) ? {
    println("[IPC Close] ${msg.to_string()}")
    mut res_msg := IpcMsgError {
        IpcMsgBase : msg.IpcMsgBase
        rc : 0
        err : 0
    }

    println("[IPC Close] close socket(fd:${msg.sockfd}")
    ipc_sock.write(res_msg.to_bytes()) ?
}

fn (shared sock Socket) handle_sockopt(msg &IpcMsgSockopt, mut ipc_sock unix.StreamConn, nd &NetDevice, shared sock_shared SocketShared) ? {
    println("[IPC Sockopt] ${msg.to_string()}")

    mut res_sockopt := IpcMsgSockopt {
        IpcMsgBase : msg.IpcMsgBase
        fd : msg.fd
        level : msg.level
        optname : msg.optname
        optlen : msg.optlen
    }
    if msg.optname == C.SO_RCVBUF {
        rcv_buf_size  := 128 * 1024
        mut optval := []byte{len:4}
        optval[0] = byte(rcv_buf_size)
        optval[1] = byte(rcv_buf_size >> 8)
        optval[2] = byte(rcv_buf_size >> 16)
        optval[3] = byte(rcv_buf_size >> 24)
        res_sockopt.optval = optval
        res_msg := IpcMsgError {
            IpcMsgBase : msg.IpcMsgBase
            rc : 0
            err : 0
            data : res_sockopt.to_bytes()[msg.IpcMsgBase.len..]
        }
        println("[IPC Sockopt] SO_RCVBUF: $rcv_buf_size")
        ipc_sock.write(res_msg.to_bytes()) ?
    } else {
        res_msg := IpcMsgError {
            IpcMsgBase : msg.IpcMsgBase
            rc : -1
            err : C.ENOPROTOOPT
        }
        println("[IPC Sockopt] not supported option ${msg.to_string()}")
        ipc_sock.write(res_msg.to_bytes()) ?
    }
}

fn (shared sock Socket) handle_write(msg &IpcMsgWrite, mut ipc_sock unix.StreamConn, nd &NetDevice, shared sock_shared SocketShared) ? {
    println("[IPC Write] ${msg.to_string()}")
}

fn (shared sock Socket) handle_sendto(msg &IpcMsgSendto, mut ipc_sock unix.StreamConn, nd &NetDevice, shared sock_shared SocketShared) ? {
    println("[IPC Sendto] ${msg.to_string()}")

    mut domain := 0
    mut sock_type := 0
    mut protocol := 0
    lock sock {
        domain = sock.domain
        sock_type = sock.sock_type
        protocol = sock.protocol
    }

    if domain == C.AF_INET &&
       sock_type == C.SOCK_DGRAM &&
       protocol == C.IPPROTO_ICMP {
        mut pkt := Packet{}
        parse_icmp_packet(mut pkt, msg.buf) ?
        println(pkt.l4_hdr.to_string())
        println("[IPC Sendto] Send From IPv4 Layer")
        mut addr := SockAddrIn{}
        match msg.addr.addr {
            SockAddrBase {

            }
            SockAddrIn {
                addr = msg.addr.addr
            }
        }
        dest_addr := AddrInfo {
            ipv4: addr.sin_addr
        }

        mut success := true
        nd.send_ipv4(mut pkt, dest_addr) or { success = false }

        mut res_msg := IpcMsgError {
            IpcMsgBase : IpcMsgBase {
                msg_type: msg.IpcMsgBase.msg_type
                pid: msg.IpcMsgBase.pid
            }
            rc : 0
            err : 0
        }
        println("[IPC Sendto] ${res_msg.to_string()}")
        if !success {
            res_msg.rc = -1
            // is this ok ?
            res_msg.err = C.EBADF
            println("[IPC Sendto] sendto failed")
        } else {
            res_msg.rc = int(msg.buf.len)
            println("[IPC Sendto] sendto success")
        }
        res_msg_bytes := res_msg.to_bytes()
        ipc_sock.write(res_msg_bytes) ?
        mut s := ""
        for i := 0; i < 6; i += 1 {
            s += "0x${res_msg_bytes[i]:02X} "
        }
        println(s)
    }
}

fn (shared sock Socket) handle_recvmsg(msg &IpcMsgRecvmsg, mut ipc_sock unix.StreamConn, nd &NetDevice, shared sock_shared SocketShared) ? {
    println("[IPC Recvmsg] ${msg.to_string()}")

    println("[IPC Recvmsg] try to get packet")
    mut sock_chans := SocketChans{}
    lock sock {
        sock_chans = sock.sock_chans
    }
    mut pkt := Packet{}
    println("[IPC Recvmsg] read_chan.len:${sock_chans.read_chan.len}")
    select {
        pkt = <- sock_chans.read_chan {
        }
        2 * time.millisecond {
            println("[IPC Recvmsg] timeout")
            res_msg := IpcMsgError {
                IpcMsgBase : msg.IpcMsgBase
                rc : -1
                err : C.EAGAIN
            }
            ipc_sock.write(res_msg.to_bytes()) ?
            return
        }
    }
    println("[IPC Recvmsg] get packet")

    buf := pkt.payload
    mut res := *msg
    res.iov_data << buf
    l3_hdr := pkt.l3_hdr
    match l3_hdr {
        IPv4Hdr {
            res.msg_namelen = 16
            res.addr = SockAddr {
                addr : SockAddrIn {
                    sin_addr : l3_hdr.src_addr
                }
            }
        }
        else {}
    }

    mut res_msg := IpcMsgError {
        IpcMsgBase : msg.IpcMsgBase
        rc : buf.len
        err : 0
        data : res.to_bytes()?[msg.IpcMsgBase.len..]
    }

    res_msg_bytes := res_msg.to_bytes()
    println("[IPC Recvmsg] recvmsg success(size:${res_msg_bytes.len})")
    ipc_sock.write(res_msg_bytes) ?
}


fn (shared sock Socket) handle_poll(msg &IpcMsgPoll, mut ipc_sock unix.StreamConn, nd &NetDevice, shared sock_shared SocketShared) ? {
    println("[IPC Poll] ${msg.to_string()}")

    mut res := *msg
    for mut fd in res.fds {
        fd.revents = 0
        if fd.events & u16(C.POLLIN) > 0 {
            mut pkt := Packet{}
            select {
                pkt = <- sock.sock_chans.read_chan {
                    sock.sock_chans.read_chan <- pkt
                    fd.revents |= u16(C.POLLIN)
                }
                msg.timeout * time.millisecond {
                }
            }
        }
    }

    res_msg := IpcMsgError {
        IpcMsgBase : msg.IpcMsgBase
        rc : 0
        err : 0
        data : res.to_bytes()[msg.IpcMsgBase.len+12..]
    }
    println("[IPC Poll] poll success")
    ipc_sock.write(res_msg.to_bytes()) ?
}
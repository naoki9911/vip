module main

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
    write_chan chan []byte
    read_chan chan []byte
}

fn new_socket_chans() SocketChans {
    return SocketChans {
        write_chan : chan []byte{}
        read_chan : chan []byte{}
    }
}

type IpcMsgType = IpcMsgBase | IpcMsgSocket | IpcMsgConnect

struct IpcMsg {
    msg IpcMsgType
}

struct IpcMsgBase {
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

fn bytes_to_int(buf []byte) ?int {
    assert buf.len == 4
    return buf[0] | buf[1] << 8 | buf[2] << 16 | buf[3] << 24
}

fn bytes_to_u32(buf []byte) ?u32 {
    assert buf.len == 4
    return buf[0] | buf[1] << 8 | buf[2] << 16 | buf[3] << 24
}

fn parse_ipc_msg(buf []byte) ?IpcMsg {
    assert buf.len >= 6
    base := IpcMsgBase {
        msg_type : buf[0] | buf[1] << 8
        pid : bytes_to_int(buf[2..6]) ?
    }

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

fn (shared sock Socket) handle_data(ipc_sock IpcSocket, nd &NetDevice, shared sock_shared SocketShared) {
    mut conn := ipc_sock.stream
    for {
        mut buf := []byte{len: 8192, init: 0}
        count := conn.read(mut buf) or {
            println('Server: connection drppped')
            return
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
        }
    }
}

fn (shared sock Socket) handle_socket(msg &IpcMsgSocket, mut ipc_sock unix.StreamConn, nd &NetDevice, shared sock_shared SocketShared) ? {
    println("[IPC Socket] ${msg.to_string()}")

    mut fd := 0
    lock sock_shared {
        fd = sock_shared.fd_base
        sock_shared.fd_base += 1
    }

    lock sock {
        sock.pid = msg.pid
        sock.fd = fd
        sock.domain = msg.domain
        sock.sock_type = msg.sock_type
        sock.protocol = msg.protocol
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

    mut addr := SockAddrIn{}
    match msg.addr.addr {
        SockAddrBase {

        }
        SockAddrIn {
            addr = msg.addr.addr
        }
    }
    mut pkt := Packet {
        payload : []byte{len:100}
    }

    dst_addr := AddrInfo {
        ipv4: addr.sin_addr
        port: addr.sin_port
    }

    mut success := true
    nd.send_udp(mut pkt, &dst_addr, addr.sin_port) or { success = false }

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
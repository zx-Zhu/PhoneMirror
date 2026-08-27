#!/usr/bin/env python3
"""Bridge DevEco Testing's HarmonyOS gRPC H.264 stream to a tiny TCP protocol."""

import argparse
import os
import signal
import socket
import struct
import sys
import threading
import time


def receive_frames(grpc_port: int, stop: threading.Event, clients: set[socket.socket], lock: threading.Lock) -> None:
    import grpc
    import scrcpy_pb2
    import scrcpy_pb2_grpc

    while not stop.is_set():
        channel = grpc.insecure_channel(
            f"127.0.0.1:{grpc_port}",
            options=[("grpc.max_receive_message_length", 64 * 1024 * 1024)],
        )
        try:
            grpc.channel_ready_future(channel).result(timeout=8)
            stream = scrcpy_pb2_grpc.ScrcpyServiceStub(channel).onStart(scrcpy_pb2.Empty(), timeout=None)
            for response in stream:
                if stop.is_set():
                    return
                payload = response.payload
                value = payload.get("data")
                if value is not None and value.HasField("val_bytes"):
                    h264 = value.val_bytes
                else:
                    raw = getattr(response, "data", b"")
                    h264 = raw.encode() if isinstance(raw, str) else raw
                if not h264:
                    continue
                flag_value = payload.get("flags")
                pts_value = payload.get("pts")
                flags = flag_value.val_int if flag_value is not None and flag_value.HasField("val_int") else 0
                pts = pts_value.val_int if pts_value is not None and pts_value.HasField("val_int") else time.monotonic_ns() // 1000
                packet = struct.pack(">IBQ", 9 + len(h264), flags & 0xFF, pts & 0xFFFFFFFFFFFFFFFF) + h264
                dead = []
                with lock:
                    for client in clients:
                        try:
                            client.sendall(packet)
                        except OSError:
                            dead.append(client)
                    for client in dead:
                        clients.discard(client)
                        client.close()
        except Exception as error:
            print(f"gRPC stream retry: {error}", file=sys.stderr, flush=True)
            stop.wait(0.8)
        finally:
            channel.close()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--grpc-port", type=int, required=True)
    parser.add_argument("--bridge-port", type=int, required=True)
    parser.add_argument("--parent-pid", type=int, required=True)
    args = parser.parse_args()

    for key in ("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "all_proxy"):
        os.environ.pop(key, None)
    os.environ["NO_PROXY"] = "127.0.0.1,localhost"

    stop = threading.Event()
    clients: set[socket.socket] = set()
    lock = threading.Lock()
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", args.bridge_port))
    server.listen(2)
    server.settimeout(0.5)

    def shutdown(_signal=None, _frame=None):
        stop.set()
        try:
            server.close()
        except OSError:
            pass

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    worker = threading.Thread(target=receive_frames, args=(args.grpc_port, stop, clients, lock), daemon=True)
    worker.start()

    while not stop.is_set():
        try:
            os.kill(args.parent_pid, 0)
        except OSError:
            shutdown()
            break
        try:
            client, _ = server.accept()
            client.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            with lock:
                for existing in clients:
                    existing.close()
                clients.clear()
                clients.add(client)
        except socket.timeout:
            continue
        except OSError:
            break

    with lock:
        for client in clients:
            client.close()
        clients.clear()


if __name__ == "__main__":
    main()

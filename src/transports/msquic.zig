const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Channel = std.event.Channel;
const Lock = std.event.Lock;
const MsQuic = @import("msquic/msquic_wrapper.zig");
const crypto = @import("../crypto.zig");
const HandleAllocator = @import("../handle.zig").HandleAllocator;

const workaround = @cImport({
    @cInclude("link_workaround.h");
});

const MsQuicHandle = struct {
    id: u8,
    pub inline fn getQuicAPI(handle: MsQuicHandle) *const MsQuic.QUIC_API_TABLE {
        // TODO verify this is a valid handle
        return msquic_instances.instances[handle.id];
    }
};

const MsQuicInstances = struct {
    // Controls how many MsQuic.QUIC_API_TABLES we will want to allocate. Usually you wouldn't need more than one.
    const MAX_MSQUIC_INSTANCES = 4;
    instances: [MAX_MSQUIC_INSTANCES]*const MsQuic.QUIC_API_TABLE = .{},
    next_free_slot: u8 = 0,
    lock: std.event.RwLock,

    pub fn init() MsQuicInstances {
        return MsQuicInstances{
            .instances = [_]*const MsQuic.QUIC_API_TABLE{undefined} ** MAX_MSQUIC_INSTANCES,
            .next_free_slot = 0,
            .lock = std.event.RwLock.init(),
        };
    }

    pub fn deinit(self: MsQuicInstances) void {
        self.lock.deinit();
    }

    pub fn pushInstance(self: *MsQuicInstances, msquic: *const MsQuic.QUIC_API_TABLE) MsQuicHandle {
        const held = self.lock.acquireWrite();
        defer held.release();
        if (self.next_free_slot > MAX_MSQUIC_INSTANCES) {
            @panic("Too many msquic instances");
        }

        self.instances[self.next_free_slot] = msquic;
        self.next_free_slot += 1;
        return .{
            .id = self.next_free_slot - 1,
        };
    }
};

var msquic_instances = MsQuicInstances.init();

var libp2p_proto_name = "zig-libp2p".*;
const alpn = MsQuic.QUIC_BUFFER{
    .Length = @sizeOf(@TypeOf(libp2p_proto_name)),
    .Buffer = @ptrCast([*c]u8, libp2p_proto_name[0..]),
};

const MsQuicTransport = struct {
    const Self = @This();
    const CredentialConfigHelper = struct {
        cred_config: MsQuic.QUIC_CREDENTIAL_CONFIG,
        cert: MsQuic.QUIC_CERTIFICATE_PKCS12,
    };

    // Context struct that can be passed to QUIC callbacks
    const ConnectionContext = struct {
        const NodeWithConnectionContext = std.atomic.Queue(ConnectionContext).Node;
        connection_handle: HandleAllocator(Connection).Handle,
        transport: *MsQuicTransport,

        fn cCallback(connection: MsQuic.HQUIC, self_ptr: ?*anyopaque, event: [*c]MsQuic.struct_QUIC_CONNECTION_EVENT) callconv(.C) c_uint {
            const self = @ptrCast(*ConnectionContext, @alignCast(@alignOf(ConnectionContext), self_ptr));
            std.debug.print("Connection event: {}\n", .{event.*.Type});
            defer {
                switch (event.*.Type) {
                    MsQuic.QUIC_CONNECTION_EVENT_SHUTDOWN_COMPLETE => {
                        self.transport.allocator.destroy(self);
                    },
                    else => {},
                }
            }
            return self.callback(connection, event);
        }

        // Same as above, but this context has the node.
        fn cCallbackWithNode(connection: MsQuic.HQUIC, self_ptr: ?*anyopaque, event: [*c]MsQuic.struct_QUIC_CONNECTION_EVENT) c_uint {
            const self = @ptrCast(*NodeWithConnectionContext, @alignCast(@alignOf(NodeWithConnectionContext), self_ptr));
            std.debug.print("Server Connection event: {}\n", .{event.*.Type});
            defer std.debug.print("Done Server Connection event: {}\n", .{event.*.Type});
            defer {
                switch (event.*.Type) {
                    MsQuic.QUIC_CONNECTION_EVENT_SHUTDOWN_COMPLETE => {
                        self.data.transport.allocator.destroy(self);
                    },
                    else => {},
                }
            }
            return self.data.callback(connection, event);
        }

        inline fn callback(self: *ConnectionContext, connection: MsQuic.HQUIC, event: [*c]MsQuic.struct_QUIC_CONNECTION_EVENT) c_uint {
            const conn_ptr = self.transport.connection_system.handle_allocator.getPtr(self.connection_handle) catch {
                std.debug.print("Stale handle failed to get ptr\n", .{});
                return MsQuic.QuicStatus.InternalError;
            };
            if (conn_ptr.connection_handle != connection) {
                conn_ptr.connection_handle = connection;
            }
            std.debug.print("Handling event={}\n", .{event.*.Type});
            defer std.debug.print("done handling event={}\n", .{event.*.Type});

            // TODO handle other events
            switch (event.*.Type) {
                MsQuic.QUIC_CONNECTION_EVENT_CONNECTED => {
                    // The handshake has completed for the connection.
                    std.debug.print("conn={any} Client connected\n", .{connection});
                    // self.clientSend(self.allocator, connection) catch |err| {
                    //     std.debug.print("conn={any} Failed to send: {any}\n", .{ connection, err });
                    //     self.msquic.ConnectionShutdown.?(connection, MsQuic.QUIC_CONNECTION_SHUTDOWN_FLAG_NONE, 0);
                    // };
                    std.debug.print("Event={}\n", .{event.*.Type});
                    conn_ptr.rw_lock.lock();
                    defer conn_ptr.rw_lock.unlock();
                    conn_ptr.state = .Connected;
                    conn_ptr.fut.resolve();
                },
                MsQuic.QUIC_CONNECTION_EVENT_SHUTDOWN_INITIATED_BY_TRANSPORT => {
                    conn_ptr.rw_lock.lock();
                    defer conn_ptr.rw_lock.unlock();
                    if (conn_ptr.state == .Connecting) {
                        conn_ptr.fut.resolve();
                    }
                    conn_ptr.state = .Closed;
                    // The connection has been shut down by the transport. Generally, this
                    // is the expected way for the connection to shut down with this
                    // protocol, since we let idle timeout kill the connection.
                    if (event.*.unnamed_0.SHUTDOWN_INITIATED_BY_TRANSPORT.Status == MsQuic.QuicStatus.ConnectionIdle) {
                        std.debug.print("conn={any} successfully shut down on idle\n", .{connection});
                    } else {
                        std.debug.print("conn={any} shut down by transport status={x}\n", .{ connection, event.*.unnamed_0.SHUTDOWN_INITIATED_BY_TRANSPORT.Status });
                    }
                },
                MsQuic.QUIC_CONNECTION_EVENT_SHUTDOWN_INITIATED_BY_PEER => {
                    conn_ptr.rw_lock.lock();
                    defer conn_ptr.rw_lock.unlock();
                    conn_ptr.state = .Closing;
                    // The connection was explicitly shut down by the peer.
                    std.debug.print("conn={any} shut down by peer err={x}\n", .{ connection, event.*.unnamed_0.SHUTDOWN_INITIATED_BY_PEER.ErrorCode });
                },
                MsQuic.QUIC_CONNECTION_EVENT_SHUTDOWN_COMPLETE => {
                    conn_ptr.rw_lock.lock();
                    defer conn_ptr.rw_lock.unlock();
                    conn_ptr.state = .Closed;
                    std.debug.print("conn={any} All done\n", .{connection});
                    if (!event.*.unnamed_0.SHUTDOWN_COMPLETE.AppCloseInProgress) {
                        std.debug.print("Closing conn\n", .{});
                        self.transport.msquic.getQuicAPI().ConnectionClose.?(connection);
                    }
                },
                MsQuic.QUIC_CONNECTION_EVENT_RESUMPTION_TICKET_RECEIVED => {
                    const resumption_ticket = event.*.unnamed_0.RESUMPTION_TICKET_RECEIVED;
                    std.debug.print("conn={any} Resumption ticket received\n", .{connection});
                    var i: usize = 0;
                    while (i < resumption_ticket.ResumptionTicketLength) : (i += 1) {
                        std.debug.print("{x}", .{resumption_ticket.ResumptionTicket[i]});
                    }
                    std.debug.print("\n", .{});
                },
                MsQuic.QUIC_CONNECTION_EVENT_PEER_STREAM_STARTED => {
                    const handle = self.transport.stream_system.handle_allocator.allocSlot() catch {
                        std.debug.print("Failed to allocate stream. dropping\n", .{});
                        return MsQuic.QuicStatus.InternalError;
                    };
                    var stream = self.transport.stream_system.handle_allocator.getPtr(handle) catch {
                        unreachable;
                    };
                    stream.* = Stream.init(self.transport.allocator, true);

                    var stream_context = self.transport.allocator.create(Stream.StreamContext) catch {
                        std.debug.print("Failed to allocate stream context. dropping\n", .{});
                        return MsQuic.QuicStatus.InternalError;
                    };
                    // TODO dealloc on errors
                    stream_context.* = Stream.StreamContext{
                        .handle = handle,
                        .transport = self.transport,
                        .accept_lock = std.event.Lock.initLocked(),
                    };

                    self.transport.msquic.getQuicAPI().SetCallbackHandler.?(
                        event.*.unnamed_0.PEER_STREAM_STARTED.Stream,
                        Stream.StreamContext.cCallback,
                        stream_context,
                    );

                    var stream_queue_node = self.transport.allocator.create(Connection.StreamQueue.Node) catch {
                        std.debug.print("Failed to allocate stream queue node. dropping\n", .{});
                        return MsQuic.QuicStatus.InternalError;
                    };
                    stream_queue_node.* = Connection.StreamQueue.Node{ .data = handle };

                    // TODO drop streams if too many.
                    conn_ptr.ready_streams.put(stream_queue_node);
                    if (conn_ptr.pending_accepts.get()) |pending_accept| {
                        Lock.Held.release(Lock.Held{ .lock = pending_accept.data });
                    }
                },
                else => {
                    std.debug.print("conn={any} Unknown event: {}\n", .{ connection, event.*.Type });
                },
            }

            return 0;
        }
    };

    const Connection = struct {
        connection_handle: MsQuic.HQUIC,
        rw_lock: std.Thread.RwLock,
        state: enum {
            Connecting,
            Connected,
            Closing,
            Closed,
            ErrProtocolNegotiationFailed,
        },
        ready_streams: StreamQueue,
        pending_accepts: PendingStreamAcceptQueue,

        // So that you can dealloc this
        fut: Fut,

        const Fut = std.event.Future(void);
        const StreamQueue = std.atomic.Queue(StreamSystem.Handle);
        const PendingStreamAcceptQueue = std.atomic.Queue(*std.event.Lock);

        fn init() !Connection {
            var self = Connection{
                .rw_lock = .{},
                .state = .Connecting,
                .connection_handle = undefined,
                .ready_streams = StreamQueue.init(),
                .pending_accepts = PendingStreamAcceptQueue.init(),
                .fut = Fut.init(),
            };
            return self;
        }

        fn deinit(self: Connection, allocator: Allocator) void {
            var ready_streams = self.ready_streams;
            var pending_accepts = self.pending_accepts;
            while (ready_streams.get()) |node| {
                allocator.destroy(node);
            }
            while (pending_accepts.get()) |node| {
                Lock.Held.release(Lock.Held{ .lock = node.data });
                allocator.destroy(node);
            }
        }

        fn acceptStream(self: *Connection, allocator: Allocator) !StreamSystem.Handle {
            var lock = std.event.Lock{};
            var pending_node = try allocator.create(PendingStreamAcceptQueue.Node);
            defer allocator.destroy(pending_node);
            pending_node.* = PendingStreamAcceptQueue.Node{
                .data = &lock,
            };

            while (true) {
                if (self.ready_streams.get()) |ready_stream| {
                    const handle = ready_stream.data;
                    allocator.destroy(ready_stream);
                    return handle;
                }

                _ = lock.acquire();
                self.pending_accepts.put(pending_node);

                const held = lock.acquire();
                held.release();

                if (self.state == .Closed) {
                    return error.ConnectionClosed;
                }
            }
        }

        fn newStream(self: *Connection, transport: *MsQuicTransport) !StreamSystem.Handle {
            const stream_handle = try transport.stream_system.handle_allocator.allocSlot();
            const stream = try transport.stream_system.handle_allocator.getPtr(stream_handle);
            stream.* = Stream.init(transport.allocator, false);

            var context = try transport.allocator.create(Stream.StreamContext);
            context.* = Stream.StreamContext{ .handle = stream_handle, .transport = transport, .accept_lock = null };

            var status = transport.msquic.getQuicAPI().StreamOpen.?(
                self.connection_handle,
                MsQuic.QUIC_STREAM_OPEN_FLAG_NONE,
                Stream.StreamContext.cCallback,
                context,
                &stream.msquic_stream_handle,
            );
            if (MsQuic.QuicStatus.isError(status)) {
                std.debug.print("Stream open failed: {x}\n", .{status});
                return error.StreamOpenFailed;
            }
            errdefer transport.msquic.getQuicAPI().StreamClose.?(stream.msquic_stream_handle);

            // Starts the bidirectional stream. By default, the peer is not notified of
            // the stream being started until data is sent on the stream.
            status = transport.msquic.getQuicAPI().StreamStart.?(stream.msquic_stream_handle, MsQuic.QUIC_STREAM_START_FLAG_NONE);
            if (MsQuic.QuicStatus.isError(status)) {
                std.debug.print("Stream start failed: {x}\n", .{status});
                return error.StreamStartFailed;
            }

            return stream_handle;
        }
    };

    const Stream = struct {
        msquic_stream_handle: MsQuic.HQUIC,
        is_inbound: bool,
        // TODO initialize this with one
        waiting_recv: RecvQFutPtr,
        // TODO initialize this with one
        ready_recv: RecvQ,
        // TODO change these to a linked list since we ahve the state mutex up here.
        recv_frames: RecvFrameQ,
        recv_frame_buffer: RecvFrameQ,
        recv_frame_pending: RecvFrameQ = RecvFrameQ.init(),
        state_mutex: std.Thread.Mutex,
        state: packed struct {
            closed: bool = false,
            recv_deferred: bool = false,
        },

        const RecvFrameQ = std.atomic.Queue(struct {
            frame: anyframe,
            leased_buf: LeasedBuffer,
        });
        const RecvQ = std.atomic.Queue(LeasedBufferFut);
        const RecvQFutPtr = std.atomic.Queue(*LeasedBufferFut);
        const LeasedBufferFut = std.event.Future(LeasedBuffer);
        const LeasedBuffer = struct {
            buf: []u8,
            state: LeasedBufferState,

            const LeasedBufferState = packed struct {
                active_lease: bool = true,
                msquic_pending: bool = false,
                stream_closed: bool = false,
                reserved: u5 = 0,
            };

            const Loop = std.event.Loop;

            const global_event_loop = Loop.instance orelse
                @compileError("std.event.Lock currently only works with event-based I/O");

            inline fn atomicStateUpdate(
                self: *LeasedBuffer,
                next_state: LeasedBufferState,
                comptime op: std.builtin.AtomicRmwOp,
            ) LeasedBufferState {
                const next_state_int = @bitCast(u8, next_state);
                const prev_state_int = @atomicRmw(u8, @ptrCast(*u8, &self.state), op, next_state_int, .SeqCst);
                return @bitCast(LeasedBufferState, prev_state_int);
            }

            fn release(self: *LeasedBuffer, transport: *MsQuicTransport, stream: *Stream) void {
                const prev_state = self.atomicStateUpdate(LeasedBufferState{
                    .active_lease = false,
                    .msquic_pending = true,
                    .reserved = 0,
                }, .And);

                if (prev_state.msquic_pending) {
                    // We hit a suspend before releasing. So now we're in charge
                    // of telling msquic we are done with this buffer.
                    if (stream.recv_frame_pending.get()) |pending_recv_frame| {
                        if (&pending_recv_frame.data.leased_buf != self) {
                            @panic("Unexpected pending recv frame");
                        }
                        _ = self.atomicStateUpdate(LeasedBufferState{
                            .active_lease = false,
                            .msquic_pending = false,
                            .reserved = 0,
                        }, .Xchg);

                        stream.recv_frame_buffer.put(pending_recv_frame);
                    } else {
                        @panic("Missing pending recv frame for async release");
                    }

                    transport.msquic.getQuicAPI().StreamReceiveComplete.?(stream.msquic_stream_handle, self.buf.len);
                }

                var tick_node = Loop.NextTickNode{
                    .prev = undefined,
                    .next = undefined,
                    .data = @frame(),
                };

                suspend {
                    global_event_loop.onNextTick(&tick_node);
                }

                std.debug.print("Starting up again on main thread(s)\n", .{});

                // transport.msquic.getQuicAPI().StreamReceiveComplete.?(stream.msquic_stream_handle, self.buf.len);
                // TODO reuse these leased buffers
                // transport.allocator.destroy(self);
            }
        };

        fn init(allocator: Allocator, is_inbound: bool) Stream {
            var self = Stream{
                .state = .{},
                .state_mutex = std.Thread.Mutex{},
                .msquic_stream_handle = undefined,
                .is_inbound = is_inbound,
                .waiting_recv = RecvQFutPtr.init(),
                .ready_recv = RecvQ.init(),
                .recv_frames = RecvFrameQ.init(),
                .recv_frame_buffer = RecvFrameQ.init(),
            };
            const recvq_node = allocator.create(RecvQ.Node) catch {
                @panic("Failed to allocate recv buffer");
            };
            const recvq_node_fut_ptr = allocator.create(RecvQFutPtr.Node) catch {
                @panic("Failed to allocate recv buffer");
            };
            const buffer_size = 3;
            var i: usize = 0;
            while (i < buffer_size) : (i += 1) {
                const recv_frame = allocator.create(RecvFrameQ.Node) catch {
                    @panic("Failed to allocate recv frame");
                };
                self.recv_frame_buffer.put(recv_frame);
            }

            recvq_node.* = RecvQ.Node{ .data = LeasedBufferFut.init() };
            recvq_node_fut_ptr.* = RecvQFutPtr.Node{ .data = &recvq_node.data };
            self.waiting_recv.put(recvq_node_fut_ptr);
            self.ready_recv.put(recvq_node);

            return self;
        }

        fn deinit(self: *Stream, allocator: Allocator) void {
            // TODO anything else?
            var waiting_recv = self.waiting_recv;
            var ready_recv = self.ready_recv;
            var recv_frames = self.recv_frames;
            var recv_frame_buffer = self.recv_frame_buffer;
            var recv_frame_pending = self.recv_frame_pending;

            while (waiting_recv.get()) |node| {
                allocator.destroy(node);
            }
            while (ready_recv.get()) |node| {
                allocator.destroy(node);
            }
            while (recv_frames.get()) |node| {
                _ = node.data.leased_buf.atomicStateUpdate(LeasedBuffer.LeasedBufferState{
                    .active_lease = false,
                    .msquic_pending = false,
                    .stream_closed = true,
                    .reserved = 0,
                }, .Xchg);
                resume node.data.frame;
                allocator.destroy(node);
            }
            while (recv_frame_buffer.get()) |node| {
                allocator.destroy(node);
            }
            while (recv_frame_pending.get()) |node| {
                allocator.destroy(node);
            }
        }

        fn send(self: *Stream, transport: *MsQuicTransport, buf: []u8) !void {
            std.debug.print("Send: Stream handle:{*}\n", .{self.msquic_stream_handle});
            var lock = std.event.Lock.initLocked();

            const quic_buf = MsQuic.QUIC_BUFFER{
                .Buffer = buf.ptr,
                .Length = @intCast(u32, buf.len),
            };
            const status = transport.msquic.getQuicAPI().StreamSend.?(
                self.msquic_stream_handle,
                &quic_buf,
                1,
                // TODO any special way to pass flags?
                // MsQuic.QUIC_SEND_FLAG_FIN,
                MsQuic.QUIC_SEND_FLAG_NONE,
                &lock,
            );

            if (MsQuic.QuicStatus.isError(status)) {
                std.debug.print("Stream send failed: {x}\n", .{status});
                return error.streamSendFailed;
            }

            const held = lock.acquire();
            held.release();
        }

        fn recvWithLease(self: *Stream, transport: *MsQuicTransport) !*LeasedBuffer {
            {
                self.state_mutex.lock();
                defer self.state_mutex.unlock();
                if (self.state.closed) {
                    return error.StreamClosed;
                }
            }

            if (self.recv_frame_buffer.get()) |recv_frame| {
                var was_deferred = blk: {
                    self.state_mutex.lock();
                    defer self.state_mutex.unlock();

                    recv_frame.data.frame = @frame();
                    self.recv_frames.put(recv_frame);
                    break :blk self.state.recv_deferred;
                };

                if (was_deferred) {
                    // We deferred a receive in the past, so tell msquic we are ready to recv
                    std.debug.print("Had to enable recv\n", .{});
                    _ = transport.msquic.getQuicAPI().StreamReceiveSetEnabled.?(self.msquic_stream_handle, @as(u8, @boolToInt(true)));
                }

                suspend {}
                std.debug.print("Recv: {any}\n", .{recv_frame.data.leased_buf.state});
                if (recv_frame.data.leased_buf.state.stream_closed) {
                    return error.StreamClosed;
                }
                return &recv_frame.data.leased_buf;
            } else {
                @panic("TODO implement. caller should allocate instead (maybe");
            }
        }

        const StreamContext = struct {
            handle: StreamSystem.Handle,
            transport: *MsQuicTransport,
            accept_lock: ?std.event.Lock,

            fn cCallback(msquic_stream: MsQuic.HQUIC, self_ptr: ?*anyopaque, event: [*c]MsQuic.struct_QUIC_STREAM_EVENT) callconv(.C) c_uint {
                const self = @ptrCast(*StreamContext, @alignCast(@alignOf(StreamContext), self_ptr));
                defer {
                    switch (event.*.Type) {
                        MsQuic.QUIC_STREAM_EVENT_SHUTDOWN_COMPLETE => {
                            self.deinit();
                            self.transport.allocator.destroy(self);
                        },
                        else => {},
                    }
                }
                return self.callback(msquic_stream, event);
            }

            // Same as above, but this context has the node.
            // TODO can I remove?
            fn cCallbackWithNode(msquic_stream: MsQuic.HQUIC, self_ptr: ?*anyopaque, event: [*c]MsQuic.struct_QUIC_STREAM_EVENT) c_uint {
                const self = @ptrCast(*Connection.StreamQueue.Node, @alignCast(@alignOf(Connection.StreamQueue.Node), self_ptr));
                defer {
                    switch (event.*.Type) {
                        MsQuic.QUIC_STREAM_EVENT_SHUTDOWN_COMPLETE => {
                            self.data.deinit();
                            self.data.transport.allocator.destroy(self);
                        },
                        else => {},
                    }
                }
                return self.data.callback(msquic_stream, event);
            }

            inline fn callback(self: StreamContext, msquic_stream: MsQuic.HQUIC, event: [*c]MsQuic.struct_QUIC_STREAM_EVENT) c_uint {
                const stream_handle = self.handle;

                var stream_ptr = self.transport.stream_system.handle_allocator.getPtr(stream_handle) catch {
                    std.debug.print("Stream callback: stream handle not found\n", .{});
                    return MsQuic.QuicStatus.InternalError;
                };
                if (stream_ptr.msquic_stream_handle != msquic_stream) {
                    stream_ptr.msquic_stream_handle = msquic_stream;
                }

                switch (event.*.Type) {
                    MsQuic.QUIC_STREAM_EVENT_SEND_COMPLETE => {
                        // A previous StreamSend call has completed, and the context is being
                        // returned back to the app.
                        std.debug.print("strm={any} data sent\n", .{msquic_stream});

                        if (event.*.unnamed_0.SEND_COMPLETE.ClientContext) |client_context| {
                            const lock = @ptrCast(*Lock, @alignCast(@alignOf(Lock), client_context));
                            Lock.Held.release(Lock.Held{ .lock = lock });
                        }
                    },
                    MsQuic.QUIC_STREAM_EVENT_RECEIVE => {
                        const limit = event.*.unnamed_0.RECEIVE.BufferCount;
                        var i: usize = 0;
                        var consumed_bytes: usize = 0;
                        while (i < limit) : (i += 1) {
                            var maybe_recv_frame = blk: {
                                stream_ptr.state_mutex.lock();
                                defer stream_ptr.state_mutex.unlock();
                                var f = stream_ptr.recv_frames.get();
                                if (f == null) {
                                    stream_ptr.state.recv_deferred = true;
                                }
                                break :blk f;
                            };
                            if (maybe_recv_frame) |recv_frame| {
                                // Return this node to our buffer queue.
                                // TODO this should happen in the recvWithLease

                                const buf = event.*.unnamed_0.RECEIVE.Buffers[i];
                                const slice = buf.Buffer[0..buf.Length];
                                recv_frame.data.leased_buf = LeasedBuffer{ .buf = slice, .state = .{ .active_lease = true } };
                                resume recv_frame.data.frame;

                                const prev_state = recv_frame.data.leased_buf.atomicStateUpdate(LeasedBuffer.LeasedBufferState{
                                    .active_lease = false,
                                    // If the lease isn't active, we set the
                                    // msquic_pending to true. But that's fine.
                                    // because nothing will read this again.
                                    .msquic_pending = true,
                                    .reserved = 0,
                                }, .Or);
                                if (prev_state.active_lease) {
                                    // The caller kept the buffer past a
                                    // suspend. We'll tell msquic we're still
                                    // processing it.  And rely on the caller to
                                    // tell msquic to continue
                                    stream_ptr.recv_frame_pending.put(recv_frame);

                                    return @bitCast(c_uint, @as(c_int, MsQuic.QuicStatus.Pending));
                                } else {

                                    // We were active, so we need to return the buffer to the pool.
                                    // if (@atomicLoad(bool, &state.active_lease, .SeqCst) != false) {
                                    //     // @panic("Caller did not return leased buffer synchronously");
                                    //     // TODO support this case?

                                    //     @atomicStore(bool, &self.state.msquic_pending, true, .SeqCst);
                                    // }

                                    _ = recv_frame.data.leased_buf.atomicStateUpdate(LeasedBuffer.LeasedBufferState{
                                        .active_lease = false,
                                        .msquic_pending = false,
                                        .reserved = 0,
                                    }, .Xchg);

                                    recv_frame.data.frame = undefined;
                                    stream_ptr.recv_frame_buffer.put(recv_frame);

                                    consumed_bytes += buf.Length;
                                }
                                // TODO return 0 read and wait
                            } else {
                                std.debug.print("Deferring recv. Consumed {} bytes\n", .{consumed_bytes});
                                event.*.unnamed_0.RECEIVE.TotalBufferLength = consumed_bytes;
                            }
                        }
                    },
                    MsQuic.QUIC_STREAM_EVENT_PEER_SEND_ABORTED => {
                        std.debug.print("strm={any} peer aborted\n", .{msquic_stream});
                    },
                    MsQuic.QUIC_STREAM_EVENT_PEER_SEND_SHUTDOWN => {
                        std.debug.print("strm={any} peer shutdown\n", .{msquic_stream});
                    },
                    MsQuic.QUIC_STREAM_EVENT_SHUTDOWN_COMPLETE => {
                        std.debug.print("!!!!!!!strm={any} all done\n", .{msquic_stream});
                        if (!event.*.unnamed_0.SHUTDOWN_COMPLETE.AppCloseInProgress) {
                            self.transport.msquic.getQuicAPI().StreamClose.?(msquic_stream);
                            stream_ptr.deinit(self.transport.allocator);
                        }
                    },
                    else => {},
                }

                return MsQuic.QuicStatus.Success;
            }

            fn deinit(self: *StreamContext) void {
                self.transport.stream_system.handle_allocator.freeSlot(self.handle) catch {
                    @panic("StreamContext deinit: handle not found");
                };
            }
        };
    };

    const Listener = struct {
        transport: *MsQuicTransport,
        listener_handle: MsQuic.HQUIC,
        configuration: *const MsQuic.HQUIC,
        registration: *const MsQuic.HQUIC,
        connection_queue: ConnQueue,
        ready_connection_queue: ConnQueue,
        pending_accepts: std.atomic.Queue(anyframe),
        allocator: Allocator,

        const ConnQueue = std.atomic.Queue(ConnectionContext);

        pub fn init(allocator: Allocator, transport: *MsQuicTransport, msquic: MsQuicHandle, registration: *const MsQuic.HQUIC, configuration: *const MsQuic.HQUIC, addr: std.net.Address, connection_buffer_size: u8) !ListenerSystem.Handle {
            var listener = try transport.listener_system.handle_allocator.allocSlot();
            var listener_ptr = try transport.listener_system.handle_allocator.getPtr(listener);
            listener_ptr.* = Listener{
                .listener_handle = undefined,
                .transport = transport,
                .configuration = configuration,
                .registration = registration,
                .connection_queue = ConnQueue.init(),
                .ready_connection_queue = ConnQueue.init(),
                .pending_accepts = std.atomic.Queue(anyframe).init(),
                .allocator = allocator,
            };

            var i: usize = 0;
            std.debug.print("\n\n", .{});
            while (i < connection_buffer_size) : (i += 1) {
                var conn_handle = try transport.connection_system.handle_allocator.allocSlot();
                var conn = try allocator.create(ConnQueue.Node);
                const connection_context = ConnectionContext{
                    .connection_handle = conn_handle,
                    .transport = transport,
                };
                std.debug.print("init: conn={*}\n", .{conn});
                conn.* = ConnQueue.Node{ .data = connection_context };
                listener_ptr.connection_queue.put(conn);
            }

            if (MsQuic.QuicStatus.isError(msquic.getQuicAPI().ListenerOpen.?(
                registration.*,
                Listener.listenerCallback,
                listener_ptr,
                &listener_ptr.listener_handle,
            ))) {
                return error.ListenerOpenFailed;
            }

            // var addr_quic = @as(MsQuic.QUIC_ADDR, addr);
            // var addr_quic_ptr = @ptrCast(*const MsQuic.QUIC_ADDR, &addr);
            // TODO this is properly
            var quic_addr = std.mem.zeroes(MsQuic.QUIC_ADDR);
            MsQuic.QuicAddrSetFamily(&quic_addr, MsQuic.QUIC_ADDRESS_FAMILY_UNSPEC);
            MsQuic.QuicAddrSetPort(&quic_addr, addr.getPort());

            const status = msquic.getQuicAPI().ListenerStart.?(
                listener_ptr.listener_handle,
                &alpn,
                1,
                &quic_addr,
            );
            if (MsQuic.QuicStatus.isError(status)) {
                std.debug.print("Listener failed: {}\n", .{status});

                return error.ListenerStartFailed;
            }
            std.debug.print("\nSelf in init is {*}\n", .{listener_ptr});
            std.debug.print("starting listener\n", .{});
            return listener;
        }

        pub fn deinit(self: *Listener) void {
            self.transport.msquic.getQuicAPI().ListenerClose.?(self.listener_handle);
            while (self.connection_queue.get()) |conn| {
                self.transport.connection_system.handle_allocator.freeSlot(conn.data.connection_handle) catch {
                    @panic("Tried to free stale handle");
                };
                std.debug.print("deinit: conn={*}\n", .{conn});
                self.allocator.destroy(conn);
            }
            while (self.ready_connection_queue.get()) |conn| {
                self.transport.connection_system.handle_allocator.freeSlot(conn.data.connection_handle) catch {
                    @panic("Tried to free stale handle");
                };
                std.debug.print("ready deinit: conn={*}\n", .{conn});
                self.allocator.destroy(conn);
            }
        }

        pub fn deinitHandle(self: ListenerSystem.Handle, transport: *MsQuicTransport) void {
            var listener_ptr = transport.listener_system.handle_allocator.getPtr(self) catch {
                std.debug.print("lost pointer\n", .{});
                return;
            };
            listener_ptr.deinit();
            transport.listener_system.handle_allocator.freeSlot(self) catch {
                unreachable;
            };
        }

        fn listenerCallback(listener: MsQuic.HQUIC, self_ptr: ?*anyopaque, event: [*c]MsQuic.struct_QUIC_LISTENER_EVENT) callconv(.C) c_uint {
            std.debug.print("Self is {*}\n", .{self_ptr});
            const self: *Listener = @ptrCast(*Listener, @alignCast(@alignOf(Listener), self_ptr));

            var status = @bitCast(u32, MsQuic.EOPNOTSUPP);
            _ = listener;
            std.debug.print("\n!!!!listener Event: {any}\n", .{event.*.Type});

            switch (event.*.Type) {
                MsQuic.QUIC_LISTENER_EVENT_NEW_CONNECTION => {
                    std.debug.print("tail {*} \n", .{self.connection_queue.tail});
                    std.debug.print("head {*} \n", .{self.connection_queue.head});
                    var conn_handle_node = self.connection_queue.get() orelse {
                        std.debug.print("Dropping connection. No buffered conns available\n", .{});
                        // TODO what's the correct code to return here?
                        return 0;
                    };

                    std.debug.print("put conn in ready {*} \n", .{conn_handle_node});
                    self.ready_connection_queue.put(conn_handle_node);

                    std.debug.print("Creating new connection\n", .{});
                    var conn_ptr = self.transport.connection_system.handle_allocator.getPtr(conn_handle_node.data.connection_handle) catch {
                        std.debug.print("Stale connection handle!", .{});
                        return MsQuic.QuicStatus.InternalError;
                    };
                    conn_ptr.* = Connection.init() catch {
                        std.debug.print("Failed to allocate connection", .{});
                        return MsQuic.QuicStatus.InternalError;
                    };

                    self.transport.msquic.getQuicAPI().SetCallbackHandler.?(
                        event.*.unnamed_0.NEW_CONNECTION.Connection,
                        ConnectionContext.cCallbackWithNode,
                        conn_handle_node,
                    );
                    status = self.transport.msquic.getQuicAPI().ConnectionSetConfiguration.?(
                        event.*.unnamed_0.NEW_CONNECTION.Connection,
                        self.configuration.*,
                    );

                    // TODO is there a race here?
                    if (self.pending_accepts.get()) |pending_accept| {
                        resume pending_accept.data;
                    }
                },
                else => {},
            }

            return status;
        }

        fn streamCallback(stream: MsQuic.HQUIC, self_ptr: ?*anyopaque, event: [*c]MsQuic.struct_QUIC_STREAM_EVENT) callconv(.C) c_uint {
            const self: *Listener = @ptrCast(*Self, @alignCast(@alignOf(Listener), self_ptr));
            switch (event.*.Type) {
                MsQuic.QUIC_STREAM_EVENT_SEND_COMPLETE => {
                    // A previous StreamSend call has completed, and the context is being
                    // returned back to the app.
                    std.debug.print("strm={any} data sent\n", .{stream});
                    // if (event.*.unnamed_0.SEND_COMPLETE.ClientContext) |client_context| {
                    // const T = SendBuffer(send_buffer_size);
                    // const send_buffer = @ptrCast(*T, @alignCast(@alignOf(T), client_context));
                    // send_buffer.deinit(self.allocator);
                    // }
                },
                MsQuic.QUIC_STREAM_EVENT_RECEIVE => {
                    // Data was received from the peer on the stream.
                    std.debug.print("strm={any} data received\n", .{stream});
                    const limit = event.*.unnamed_0.RECEIVE.BufferCount;
                    var i: usize = 0;
                    while (i < limit) : (i += 1) {
                        const buf = event.*.unnamed_0.RECEIVE.Buffers[i];
                        const slice = buf.Buffer[0..buf.Length];
                        std.debug.print("strm={any} data: {s}\n", .{ stream, slice });
                    }
                },
                MsQuic.QUIC_STREAM_EVENT_PEER_SEND_SHUTDOWN => {
                    // The peer gracefully shut down its send direction of the stream.
                    std.debug.print("strm={any} peer shutdown send direction\n", .{stream});
                    self.serverSend(self.allocator, stream) catch |err| {
                        std.debug.print("strm={any} err={any} sending data\n", .{ stream, err });
                        _ = self.msquic.StreamShutdown.?(stream, MsQuic.QUIC_STREAM_SHUTDOWN_FLAG_ABORT, 0);
                        return 0;
                    };
                },
                MsQuic.QUIC_STREAM_EVENT_PEER_SEND_ABORTED => {
                    // The peer aborted its send direction of the stream.
                    std.debug.print("strm={any} peer aborted\n", .{stream});
                    _ = self.msquic.getQuicAPI().StreamShutdown.?(stream, MsQuic.QUIC_STREAM_SHUTDOWN_FLAG_ABORT, 0);
                },
                MsQuic.QUIC_STREAM_EVENT_SHUTDOWN_COMPLETE => {
                    std.debug.print("strm={any} all done\n", .{stream});
                    self.msquic.getQuicAPI().StreamClose.?(stream);
                },
                else => {},
            }
            return 0;
        }

        // Accept a connection
        pub fn accept(self: *Listener) !ConnectionSystem.Handle {
            std.debug.print("\nSelf in accept is {*}\n", .{self});
            while (true) {
                std.debug.print("accept tail {*} \n", .{self.connection_queue.tail});
                std.debug.print("accept head {*} \n", .{self.connection_queue.head});
                if (self.ready_connection_queue.get()) |ready_conn| {
                    const conn_context = ready_conn.*.data;
                    // Wait for connection to be ready
                    var conn_ptr = try self.transport.connection_system.handle_allocator.getPtr(conn_context.connection_handle);

                    _ = conn_ptr.fut.get();
                    return conn_context.connection_handle;
                }

                var frame_node = std.atomic.Queue(anyframe).Node{
                    .data = @frame(),
                };

                suspend {
                    self.pending_accepts.put(&frame_node);
                }
                std.debug.print("!!!!resuming\n", .{});
            }
        }
    };

    // A handle instead of a pointer for the connection. Different than MsQuic.hquic
    const ConnectionSystem = struct {
        const Handle = HandleAllocator(Connection).Handle;
        handle_allocator: HandleAllocator(Connection),

        fn init(allocator: Allocator) ConnectionSystem {
            return ConnectionSystem{
                .handle_allocator = HandleAllocator(Connection).init(allocator),
            };
        }

        fn deinit(self: ConnectionSystem) void {
            self.handle_allocator.deinit();
        }

        // fn acceptStream(self: *ConnectionSystem, handle: Handle) StreamSystem.Handle {}
    };

    const StreamSystem = struct {
        const Handle = HandleAllocator(Stream).Handle;
        handle_allocator: HandleAllocator(Stream),

        fn init(allocator: Allocator) StreamSystem {
            return StreamSystem{
                .handle_allocator = HandleAllocator(Stream).init(allocator),
            };
        }

        fn deinit(self: StreamSystem) void {
            self.handle_allocator.deinit();
        }
    };

    const ListenerSystem = struct {
        const Handle = HandleAllocator(Listener).Handle;
        handle_allocator: HandleAllocator(Listener),

        fn init(allocator: Allocator) ListenerSystem {
            return ListenerSystem{
                .handle_allocator = HandleAllocator(Listener).init(allocator),
            };
        }

        fn deinit(self: ListenerSystem) void {
            self.handle_allocator.deinit();
        }
    };

    allocator: Allocator,
    msquic: MsQuicHandle,
    registration: MsQuic.HQUIC,
    configuration: MsQuic.HQUIC,
    listener_system: ListenerSystem,
    connection_system: ConnectionSystem,
    stream_system: StreamSystem,

    pub fn init(allocator: Allocator, app_name: [:0]const u8, pkcs12: *crypto.PKCS12) !Self {
        // Workaround a bug in the zig compiler. It loses this symbol.
        var max_mem = workaround.CGroupGetMemoryLimit();
        _ = max_mem;

        var msquic: *const MsQuic.QUIC_API_TABLE = undefined;
        const msQuicPtr = @ptrCast([*c]?*const anyopaque, &msquic);
        var status = MsQuic.MsQuicOpenVersion(MsQuic.QUIC_API_VERSION_2, msQuicPtr);
        if (status > 0) {
            std.debug.print("MsQuicOpen failed: {}\n", .{status});
            return error.OpenFailed;
        }

        const reg_config = MsQuic.QUIC_REGISTRATION_CONFIG{
            .AppName = app_name,
            .ExecutionProfile = MsQuic.QUIC_EXECUTION_PROFILE_LOW_LATENCY,
        };
        var registration: MsQuic.HQUIC = undefined;
        status = msquic.RegistrationOpen.?(&reg_config, &registration);
        if (status > 0) {
            std.debug.print("registration failed: {}\n", .{status});
            return error.RegistrationFailed;
        }

        const configuration = try loadConfiguration(msquic, &registration, pkcs12);
        const handle = msquic_instances.pushInstance(msquic);

        return MsQuicTransport{
            .allocator = allocator,
            .msquic = handle,
            .registration = registration,
            .configuration = configuration,
            .listener_system = ListenerSystem.init(allocator),
            .connection_system = ConnectionSystem.init(allocator),
            .stream_system = StreamSystem.init(allocator),
        };
    }

    pub fn deinit(self: *const Self) void {
        self.msquic.getQuicAPI().ConfigurationClose.?(self.configuration);
        self.msquic.getQuicAPI().RegistrationClose.?(self.registration);
        MsQuic.MsQuicClose(self.msquic.getQuicAPI());
        self.listener_system.deinit();
        self.connection_system.deinit();
        self.stream_system.deinit();
    }

    fn loadConfiguration(msquic: *const MsQuic.QUIC_API_TABLE, registration: *MsQuic.HQUIC, pkcs12: *crypto.PKCS12) !MsQuic.HQUIC {
        var settings = std.mem.zeroes(MsQuic.QuicSettings);

        settings.IdleTimeoutMs = 1000;
        settings.IsSet.IdleTimeoutMs = true;

        // Configures the server's resumption level to allow for resumption and
        // 0-RTT.
        settings.ServerResumptionLevel = MsQuic.QUIC_SERVER_RESUME_AND_ZERORTT;
        settings.IsSet.ServerResumptionLevel = true;

        // Configures the server's settings to allow for the peer to open a single
        // bidirectional stream. By default connections are not configured to allow
        // any streams from the peer.
        settings.PeerBidiStreamCount = 1;
        settings.IsSet.PeerBidiStreamCount = true;

        var cred_helper = CredentialConfigHelper{
            .cred_config = std.mem.zeroes(MsQuic.QUIC_CREDENTIAL_CONFIG),
            .cert = undefined,
        };

        cred_helper.cred_config.Flags = MsQuic.QUIC_CREDENTIAL_FLAG_NONE;

        var pkcs12_bytes = [_]u8{0} ** 1024;
        const pkcs12_len = try pkcs12.read(pkcs12_bytes[0..]);
        const pkcs12_slice = pkcs12_bytes[0..pkcs12_len];

        cred_helper.cert.Asn1Blob = pkcs12_slice.ptr;
        cred_helper.cert.Asn1BlobLength = @intCast(u32, pkcs12_slice.len);
        cred_helper.cert.PrivateKeyPassword = "";
        cred_helper.cred_config.Type = MsQuic.QUIC_CREDENTIAL_TYPE_CERTIFICATE_PKCS12;
        cred_helper.cred_config.CertPtr.CertificatePkcs12 = &cred_helper.cert;

        var configuration: MsQuic.HQUIC = undefined;

        if (MsQuic.QuicStatus.isError(msquic.ConfigurationOpen.?(registration.*, &alpn, 1, &settings, @sizeOf(@TypeOf(settings)), null, &configuration))) {
            return error.ConfigurationFailed;
        }
        errdefer msquic.ConfigurationClose.?(configuration);

        const status = msquic.ConfigurationLoadCredential.?(configuration, &cred_helper.cred_config);
        if (MsQuic.QuicStatus.isError(status)) {
            std.debug.print("Failed to load credential: {}\n", .{status});
            return error.ConfigurationLoadCredentialFailed;
        }

        return configuration;
    }

    pub fn listen(self: *Self, allocator: Allocator, addr: std.net.Address) !ListenerSystem.Handle {
        return try Listener.init(allocator, self, self.msquic, &self.registration, &self.configuration, addr, 4);
    }

    pub fn startConnection(self: *Self, allocator: Allocator, target: [*c]const u8, port: u16) callconv(.Async) !ConnectionSystem.Handle {
        var conn_context_ptr = try allocator.create(ConnectionContext);

        const conn_handle = try self.connection_system.handle_allocator.allocSlot();
        const conn_ptr = try self.connection_system.handle_allocator.getPtr(conn_handle);
        conn_ptr.* = try Connection.init();

        conn_context_ptr.* = ConnectionContext{
            .connection_handle = conn_handle,
            .transport = self,
        };

        if (MsQuic.QuicStatus.isError(self.msquic.getQuicAPI().ConnectionOpen.?(
            self.registration,
            ConnectionContext.cCallback,
            conn_context_ptr,
            &conn_ptr.connection_handle,
        ))) {
            std.debug.print("Conn open failed\n", .{});
            return error.ConnectionOpenFailed;
        }
        errdefer self.msquic.getQuicAPI().ConnectionClose.?(conn_ptr.connection_handle);

        const status = self.msquic.getQuicAPI().ConnectionStart.?(
            conn_ptr.connection_handle,
            self.configuration,
            MsQuic.QUIC_ADDRESS_FAMILY_UNSPEC,
            target,
            port,
        );
        if (MsQuic.QuicStatus.isError(status)) {
            std.debug.print("Connection start failed: {}\n", .{status});
            return error.ConnectionStartFailed;
        }

        _ = conn_ptr.fut.get();
        return conn_handle;
    }

    pub fn deinitConnection(self: *Self, connection: ConnectionSystem.Handle) void {
        _ = self;
        _ = connection;
        // const ptr = self.connection_system.handle_allocator.getPtr(connection);
    }
};

test "Spin up transport" {
    const allocator = std.testing.allocator;
    var kp = try crypto.ED25519KeyPair.new();
    defer kp.deinit();
    const x509 = try crypto.X509.init(kp);
    defer x509.deinit();
    var pkcs12 = try crypto.PKCS12.init(kp, x509);
    defer pkcs12.deinit();

    var transport = try MsQuicTransport.init(allocator, "test", &pkcs12);
    defer transport.deinit();

    // TODO this should take in an allocated listener or transport should allocate a listener.
    var listener = try transport.listen(allocator, try std.net.Address.parseIp4("0.0.0.0", 54321));
    defer MsQuicTransport.Listener.deinitHandle(listener, &transport);

    const listener_ptr = try transport.listener_system.handle_allocator.getPtr(listener);
    var incoming_conn_frame = async listener_ptr.accept();

    const connection = try await async transport.startConnection(allocator, "localhost", 54321);
    // TODO dealloc connection
    std.debug.print("\ngot connection {}\n", .{connection});
    {
        var connection_ptr = try transport.connection_system.handle_allocator.getPtr(connection);
        const stream_handle = try connection_ptr.newStream(&transport);
        var stream = try transport.stream_system.handle_allocator.getPtr(stream_handle);
        std.debug.print("\nSending data\n", .{});
        var data = "Hello World".*;
        try await async stream.send(&transport, data[0..]);
        std.debug.print("\nSent data\n", .{});
        const f = struct {
            fn f(stream_handle_1: MsQuicTransport.StreamSystem.Handle, closure_transport: *MsQuicTransport, conn_handle_1: MsQuicTransport.ConnectionSystem.Handle) !void {
                defer {
                    var connection_ptr_1 = closure_transport.connection_system.handle_allocator.getPtr(conn_handle_1) catch {
                        @panic("Stale handle");
                    };
                    connection_ptr_1.deinit(allocator);
                }
                var closure_stream = try closure_transport.stream_system.handle_allocator.getPtr(stream_handle_1);
                errdefer {
                    std.debug.print("\n!!!!!!!Found error\n", .{});
                }
                var count: usize = 0;
                while (true) : (count += 1) {
                    std.debug.print("\n!!Read loop!!\n", .{});

                    const leased_buf = try await async closure_stream.recvWithLease(closure_transport);
                    std.debug.print("\nRead data {s}\n", .{leased_buf.buf});
                    if (count % 4 == 0) {
                        // To test what happens if we suspend with a leased buffer
                        std.time.sleep(1 * std.time.ns_per_ms);
                    }
                    leased_buf.release(
                        closure_transport,
                        closure_stream,
                    );
                    std.debug.print("!!!!!! Released buffer\n", .{});
                }
            }
        };
        _ = async f.f(stream_handle, &transport, connection);
    }

    const incoming_conn = try await incoming_conn_frame;
    var incoming_conn_ptr = try transport.connection_system.handle_allocator.getPtr(incoming_conn);
    defer incoming_conn_ptr.deinit(allocator);
    std.debug.print("\nincoming connection {}\n", .{incoming_conn});

    const incoming_stream = try await async incoming_conn_ptr.acceptStream(allocator);
    std.debug.print("\nincoming stream {}\n", .{incoming_stream});

    const incoming_stream_ptr = try transport.stream_system.handle_allocator.getPtr(incoming_stream);
    const leased_buf = try incoming_stream_ptr.recvWithLease(&transport);
    std.debug.print("\nRead server data {s}\n", .{leased_buf.buf});
    leased_buf.release(&transport, incoming_stream_ptr);

    var msgs_to_send: usize = 20;
    while (msgs_to_send > 0) : (msgs_to_send -= 1) {
        var msg_bytes = try std.fmt.allocPrint(allocator, "Hello from server. Countdown: {}\n", .{msgs_to_send});
        try await async incoming_stream_ptr.send(&transport, msg_bytes);
        allocator.free(msg_bytes);
    }
}

test "Spin up transport with cert extension" {
    const allocator = std.testing.allocator;
    var host_key = try crypto.ED25519KeyPair.new();
    var cert_key = try crypto.ED25519KeyPair.new();
    defer host_key.deinit();
    defer cert_key.deinit();
    var x509 = try crypto.X509.init(cert_key);
    defer x509.deinit();

    try crypto.Libp2pTLSCert.insertExtension(&x509, try crypto.Libp2pTLSCert.serializeLibp2pExt(.{ .host_key = host_key, .cert_key = cert_key }));

    var pkcs12 = try crypto.PKCS12.init(cert_key, x509);
    defer pkcs12.deinit();

    var transport = try MsQuicTransport.init(allocator, "test", &pkcs12);
    defer transport.deinit();
}

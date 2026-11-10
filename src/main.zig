const std = @import("std");
const logger = @import("logger.zig");
const is_linux = @import("builtin").os.tag == .linux;
const reader_mod = @import("reader.zig");
const server = @import("server.zig");
const inventory = @import("inventory.zig");
const safealloc = @import("safealloc.zig");

// Command line options, same flags as the go binary. Like Go's flag
// package, both -flag value and -flag=value are accepted.
const Options = struct {
    port: u16 = 1667,
    wake: bool = true,
    only_one: bool = true,
    tls: bool = false,
    api_token: []const u8 = "",
    library: []const u8 = "02030000",
    tag_standard: []const u8 = "dansk",
    axe_host: []const u8 = "",
    axe_port: u16 = 0,
    ble_mac: []const u8 = "",
    com_port: []const u8 = "",
    com_frame: []const u8 = "8E1",
    com_baud: u32 = 38400,
    debug: bool = false,
};

// Usage text, shown on any command line error.
const usage: []const u8 =
    \\Usage: feig [options]
    \\
    \\  -apiToken string   API token; when set, all endpoints need "Authorization: Bearer <token>" (/events/: ?apiToken=)
    \\  -axeHost string     host of feiging axe (tcp)
    \\  -axePort int        port of feiging axe
    \\  -bleMac string      MAC address of BLE reader (e.g. AA:BB:CC:DD:EE:FF)
    \\  -comPort string     serial port of reader (e.g. /dev/ttyUSB0)
    \\  -comFrame string    serial byte frame (8E1 | 8N1 | 8O1) (default "8E1")
    \\  -comBaud int        serial baudrate (default 38400)
    \\  -debug              turn on verbose logging
    \\  -library string     library ISIL number (default "02030000")
    \\  -onlyOne            only one active /events/ subscriber (default true)
    \\  -port string        port of http API (default ":1667")
    \\  -tagStandard string tag content standard (default "dansk")
    \\  -tls                use tls (linux; cert.pem + key.pem in the current directory)
    \\  -wake               keep transponders awake, no tag content (default true)
    \\
;

// Report an argument error with the usage text and exit non-zero. Arg
// errors never panic.
fn argError(comptime fmt: []const u8, args: anytype) noreturn {
    logger.print("ERROR: " ++ fmt, args);
    logger.print("{s}", .{usage});
    std.process.exit(1);
}

fn isBoolFlag(name: []const u8) bool {
    return std.mem.eql(u8, name, "wake") or
        std.mem.eql(u8, name, "onlyOne") or
        std.mem.eql(u8, name, "tls") or
        std.mem.eql(u8, name, "debug");
}

// Go strconv.ParseBool compatible
fn parseBool(name: []const u8, s: []const u8) bool {
    if (std.mem.eql(u8, s, "1") or std.mem.eql(u8, s, "t") or std.mem.eql(u8, s, "T") or
        std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "TRUE") or std.mem.eql(u8, s, "True"))
    {
        return true;
    }
    if (std.mem.eql(u8, s, "0") or std.mem.eql(u8, s, "f") or std.mem.eql(u8, s, "F") or
        std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "FALSE") or std.mem.eql(u8, s, "False"))
    {
        return false;
    }
    argError("invalid boolean value for -{s}: '{s}'", .{ name, s });
}

fn parseUint(comptime T: type, name: []const u8, s: []const u8) T {
    // -port also accepts the go style ":1667"
    const rest = if (std.mem.startsWith(u8, s, ":")) s[1..] else s;
    return std.fmt.parseInt(T, rest, 10) catch
        argError("invalid number for -{s}: '{s}'", .{ name, s });
}

fn dupeStr(alloc: std.mem.Allocator, s: []const u8) []const u8 {
    return alloc.dupe(u8, s) catch
        std.debug.panic("out of memory", .{});
}

fn setOption(alloc: std.mem.Allocator, opts: *Options, name: []const u8, value: []const u8) void {
    if (std.mem.eql(u8, name, "apiToken")) {
        opts.api_token = dupeStr(alloc, value);
    } else if (std.mem.eql(u8, name, "port")) {
        opts.port = parseUint(u16, name, value);
    } else if (std.mem.eql(u8, name, "axePort")) {
        opts.axe_port = parseUint(u16, name, value);
    } else if (std.mem.eql(u8, name, "comBaud")) {
        opts.com_baud = parseUint(u32, name, value);
    } else if (std.mem.eql(u8, name, "wake")) {
        opts.wake = parseBool(name, value);
    } else if (std.mem.eql(u8, name, "onlyOne")) {
        opts.only_one = parseBool(name, value);
    } else if (std.mem.eql(u8, name, "tls")) {
        opts.tls = parseBool(name, value);
    } else if (std.mem.eql(u8, name, "debug")) {
        opts.debug = parseBool(name, value);
    } else if (std.mem.eql(u8, name, "library")) {
        opts.library = dupeStr(alloc, value);
    } else if (std.mem.eql(u8, name, "tagStandard")) {
        opts.tag_standard = dupeStr(alloc, value);
    } else if (std.mem.eql(u8, name, "axeHost")) {
        opts.axe_host = dupeStr(alloc, value);
    } else if (std.mem.eql(u8, name, "bleMac")) {
        opts.ble_mac = dupeStr(alloc, value);
    } else if (std.mem.eql(u8, name, "comPort")) {
        opts.com_port = dupeStr(alloc, value);
    } else if (std.mem.eql(u8, name, "comFrame")) {
        opts.com_frame = dupeStr(alloc, value);
    } else {
        argError("unknown flag -{s}", .{name});
    }
}

fn parseArgs(alloc: std.mem.Allocator, args: []const []const u8, opts: *Options) void {
    var i: usize = 1; // skip program name
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (a.len < 2 or a[0] != '-') continue;
        var name = a[1..];
        if (name.len > 0 and name[0] == '-') name = name[1..]; // --flag form
        var value: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, name, '=')) |eq| {
            value = name[eq + 1 ..];
            name = name[0..eq];
        }
        if (value == null) {
            if (isBoolFlag(name)) {
                // Go bool flags take no value in the space form: -wake == -wake=true
                value = "true";
            } else {
                i += 1;
                if (i >= args.len) argError("flag -{s} requires a value", .{name});
                value = args[i];
            }
        }
        setOption(alloc, opts, name, value.?);
    }
}

pub fn main(init: std.process.Init) !void {
    // init.io: the process's global engine. Net reads only work with
    // it on the MAIN thread - every net read from a non-main thread,
    // and every net read with a user-created engine (Threaded.init),
    // faulted at NULL+0x1328; hologlobe's identical pattern (init.io,
    // main thread) works. All net handling is therefore on main.
    // (fluid/glow's Threaded.init pattern is for file io, not net.)
    const io = init.io;
    logger.initIo(io);

    // The process-lifetime arena, mutex-protected: the reader loop and
    // the main thread both allocate from it (see safealloc.zig)
    var safe_alloc = safealloc.SafeAlloc.init(io);
    const alloc = safe_alloc.allocator();
    logger.initAlloc(alloc);

    logger.print("Starting feiging...", .{});

    const args = init.minimal.args.toSlice(alloc) catch
        std.debug.panic("failed to read command line", .{});

    var opts: Options = .{};
    parseArgs(alloc, args, &opts);

    if (inventory.tagStandardByName(opts.tag_standard)) |ts| {
        inventory.current = ts;
        logger.print("Tag standard: {s}", .{ts.name});
    } else {
        argError("unknown -tagStandard '{s}' (available: {s})", .{ opts.tag_standard, inventory.availableStandards });
    }

    if (opts.debug) logger.debug_enabled = true;

    var tls_enabled: bool = false;
    if (opts.tls) {
        if (!is_linux) argError("-tls is not supported on this platform (linux only)", .{});
        // cert.pem and key.pem (PEM) from the current directory
        if (!server.tlsInit("cert.pem", "key.pem")) {
            argError("tls init failed: {s}", .{server.tlsLastError()});
        }
        tls_enabled = true;
        logger.print("TLS enabled (cert.pem + key.pem)", .{});
    }

    var reader = reader_mod.Reader.init(alloc, io);

    // Pick connection type: BLE > serial COM > TCP (axe) > USB (auto scan)
    if (opts.ble_mac.len > 0) {
        logger.print("Connecting to BLE reader {s}", .{opts.ble_mac});
        if (reader.connectBle(opts.ble_mac)) |_| {} else |_| {
            logger.print("No RFID Device found! {s}", .{reader.last_err});
        }
    } else if (opts.com_port.len > 0) {
        logger.print("Connecting to reader on serial port {s}", .{opts.com_port});
        if (reader.connectCom(opts.com_port, opts.com_frame, opts.com_baud)) |_| {} else |_| {
            logger.print("No RFID Device found! {s}", .{reader.last_err});
        }
    } else if (opts.axe_host.len > 0 and opts.axe_port != 0) {
        logger.print("Connecting to axe at host {s} port {d}", .{ opts.axe_host, opts.axe_port });
        if (reader.connectTcp(opts.axe_host, opts.axe_port)) |_| {} else |_| {
            logger.print("No RFID Device found! {s}", .{reader.last_err});
        }
    } else {
        logger.print("Scanning for USB reader...", .{});
        if (reader.connectUsb()) |_| {} else |_| {
            logger.print("No RFID Device found! {s}", .{reader.last_err});
        }
    }

    if (opts.debug) {
        var buf: [8192]u8 = undefined;
        var mw = inventory.MemWriter{ .buf = buf[0..], .alloc = alloc };
        reader.json(&mw) catch {};
        logger.print("{s}", .{mw.slice()});
    }

    var app = server.App.init(alloc, io, &reader, opts.wake, opts.only_one, opts.library, tls_enabled, opts.api_token) catch
        std.debug.panic("failed to initialize app", .{});

    const reader_thread = try std.Thread.spawn(.{}, server.App.readerLoop, .{&app});
    reader_thread.detach();

    const sse_thread = try std.Thread.spawn(.{}, server.App.sseLoop, .{&app});
    sse_thread.detach();

    logger.print("Starting web server at port {d}", .{opts.port});
    const address = std.Io.net.IpAddress.parse("0.0.0.0", opts.port) catch |err|
        std.debug.panic("failed to parse address: {s}", .{@errorName(err)});
    var tcp = address.listen(io, .{ .reuse_address = true }) catch |err|
        std.debug.panic("failed to listen on port {d}: {s}", .{ opts.port, @errorName(err) });
    defer tcp.deinit(io);

    app.httpLoop(&tcp) catch |err| {
        logger.print("http server stopped: {s}", .{@errorName(err)});
    };
}

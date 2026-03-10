const std = @import("std");
const beam = @import("beam");
const e = @import("erl_nif");
const c = @cImport({
    @cInclude("pg_query.h");
    @cInclude("protobuf/pg_query.pb-c.h");
    @cInclude("protobuf-c/protobuf-c.h");
});
// Zigler's generic u64 term encoding still resolves to a 32-bit c_ulong on
// some cross targets, so this shim keeps fingerprint map construction portable.
extern fn pginspect_make_uint64(env: beam.env, value: u64) e.ErlNifTerm;

const max_sql_length: usize = 16 * 1024 * 1024;
const max_protobuf_length: usize = 32 * 1024 * 1024;

fn error_message(err: anyerror) []const u8 {
    return switch (err) {
        error.InputTooLarge => "input too large",
        error.ContainsNullByte => "argument must not contain null bytes",
        error.InputSizeTooLarge => "input size too large",
        error.AllocationFailed => "memory allocation failed",
        error.OutOfMemory => "memory allocation failed",
        error.InvalidProtobufMessage => "invalid protobuf message format",
        else => "unexpected error",
    };
}

fn make_error(env: beam.env, message: []const u8) beam.term {
    return beam.make(.{ .@"error", message }, .{ .env = env });
}

fn ok_binary(env: beam.env, bytes: []const u8) beam.term {
    return beam.make(.{ .ok, bytes }, .{ .env = env });
}

fn c_string_slice(ptr: [*c]const u8) []const u8 {
    return std.mem.span(ptr);
}

fn protobuf_message_valid(msg: *c.PgQuery__ParseResult) bool {
    return c.protobuf_c_message_check(&msg.*.base) != 0;
}

fn pg_query_error_message(err: [*c]const c.PgQueryError) []const u8 {
    return c_string_slice(err[0].message);
}

fn beam_error(env: beam.env, err: anyerror) beam.term {
    return make_error(env, error_message(err));
}

fn validate_input(input: []const u8, max_length: usize) !void {
    if (input.len > max_length) {
        return error.InputTooLarge;
    }
}

fn make_c_string(input: []const u8) ![:0]u8 {
    if (std.mem.indexOfScalar(u8, input, 0) != null) {
        return error.ContainsNullByte;
    }

    if (input.len >= std.math.maxInt(usize) - 1) {
        return error.InputSizeTooLarge;
    }

    // libpg_query expects a mutable, NUL-terminated C string. Use Zigler's
    // BEAM-backed allocator so this temporary buffer follows normal Zig
    // allocation patterns.
    const str = try beam.allocator.allocSentinel(u8, input.len, 0);

    if (input.len > 0) {
        @memcpy(str[0..input.len], input);
    }

    return str;
}

fn parse_error_term(env: beam.env, err: [*c]const c.PgQueryError) beam.term {
    return beam.make(
        .{
            .@"error",
            .{
                .message = pg_query_error_message(err),
                .cursorpos = err[0].cursorpos - 1,
            },
        },
        .{ .env = env },
    );
}

/// Parses a SQL query into a serialized protobuf AST.
pub fn parse_protobuf(query: []const u8) beam.term {
    const env = beam.context.env;

    validate_input(query, max_sql_length) catch |err| return beam_error(env, err);
    const query_str = make_c_string(query) catch |err| return beam_error(env, err);
    defer beam.allocator.free(query_str);

    const result = c.pg_query_parse_protobuf(query_str.ptr);
    defer c.pg_query_free_protobuf_parse_result(result);

    if (result.@"error" != null) {
        return parse_error_term(env, &result.@"error"[0]);
    }

    return ok_binary(
        env,
        @as([*c]const u8, @ptrCast(result.parse_tree.data))[0..result.parse_tree.len],
    );
}

/// Converts a serialized protobuf AST back into SQL text.
pub fn deparse_protobuf(input: []const u8) beam.term {
    const env = beam.context.env;

    validate_input(input, max_protobuf_length) catch |err| return beam_error(env, err);

    // Unpack once purely as a validation step. libpg_query assumes the protobuf
    // bytes are structurally valid and may misbehave on malformed input.
    const msg = c.pg_query__parse_result__unpack(null, input.len, input.ptr) orelse
        return beam_error(env, error.InvalidProtobufMessage);

    // protobuf-c allocates the unpacked message tree; free it after the
    // validation check. The actual libpg_query deparse entrypoint consumes the
    // original serialized bytes below.
    defer c.pg_query__parse_result__free_unpacked(msg, null);

    if (!protobuf_message_valid(msg)) {
        return beam_error(env, error.InvalidProtobufMessage);
    }

    const protobuf = c.PgQueryProtobuf{
        .len = input.len,
        .data = @ptrCast(@constCast(input.ptr)),
    };

    const result = c.pg_query_deparse_protobuf(protobuf);
    defer c.pg_query_free_deparse_result(result);

    if (result.@"error" != null) {
        return make_error(env, pg_query_error_message(&result.@"error"[0]));
    }

    return ok_binary(env, c_string_slice(result.query));
}

/// Generates a fingerprint for a SQL query.
pub fn fingerprint(query: []const u8) beam.term {
    const env = beam.context.env;

    validate_input(query, max_sql_length) catch |err| return beam_error(env, err);
    const query_str = make_c_string(query) catch |err| return beam_error(env, err);
    defer beam.allocator.free(query_str);

    const result = c.pg_query_fingerprint(query_str.ptr);
    defer c.pg_query_free_fingerprint_result(result);

    if (result.@"error" != null) {
        return make_error(env, pg_query_error_message(&result.@"error"[0]));
    }

    return beam.make(
        .{
            .ok,
            .{
                .fingerprint = beam.term{ .v = pginspect_make_uint64(env, result.fingerprint) },
                .fingerprint_str = c_string_slice(result.fingerprint_str),
            },
        },
        .{ .env = env },
    );
}

/// Scans SQL into libpg_query's protobuf token stream.
pub fn scan(query: []const u8) beam.term {
    const env = beam.context.env;

    validate_input(query, max_sql_length) catch |err| return beam_error(env, err);
    const query_str = make_c_string(query) catch |err| return beam_error(env, err);
    defer beam.allocator.free(query_str);

    const result = c.pg_query_scan(query_str.ptr);
    defer c.pg_query_free_scan_result(result);

    if (result.@"error" != null) {
        return parse_error_term(env, &result.@"error"[0]);
    }

    return ok_binary(
        env,
        @as([*c]const u8, @ptrCast(result.pbuf.data))[0..result.pbuf.len],
    );
}

/// Normalizes SQL by replacing literals with placeholders.
pub fn normalize(query: []const u8) beam.term {
    const env = beam.context.env;

    validate_input(query, max_sql_length) catch |err| return beam_error(env, err);
    const query_str = make_c_string(query) catch |err| return beam_error(env, err);
    defer beam.allocator.free(query_str);

    const result = c.pg_query_normalize(query_str.ptr);
    defer c.pg_query_free_normalize_result(result);

    if (result.@"error" != null) {
        return make_error(env, pg_query_error_message(&result.@"error"[0]));
    }

    return ok_binary(env, c_string_slice(result.normalized_query));
}

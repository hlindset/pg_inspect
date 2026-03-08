const std = @import("std");
const beam = @import("beam");
const e = @import("erl_nif");
const c = @cImport({
    @cInclude("pg_query.h");
    @cInclude("protobuf/pg_query.pb-c.h");
    @cInclude("protobuf-c/protobuf-c.h");
});

// Zig's imported Erlang NIF signature for enif_make_uint64 was not portable
// across the precompile target matrix, so this C shim provides a stable call.
extern fn pginspect_make_uint64(env: beam.env, value: u64) e.ErlNifTerm;

const max_sql_length: usize = 16 * 1024 * 1024;
const max_protobuf_length: usize = 32 * 1024 * 1024;

fn atom(env: beam.env, name: [*:0]const u8) e.ErlNifTerm {
    return e.enif_make_atom(env, name);
}

fn ok_term(env: beam.env, value: e.ErlNifTerm) beam.term {
    return .{ .v = e.enif_make_tuple2(env, atom(env, "ok"), value) };
}

fn error_term(env: beam.env, value: e.ErlNifTerm) beam.term {
    return .{ .v = e.enif_make_tuple2(env, atom(env, "error"), value) };
}

fn error_message(err: anyerror) []const u8 {
    return switch (err) {
        error.InputTooLarge => "input too large",
        error.ContainsNullByte => "argument must not contain null bytes",
        error.InputSizeTooLarge => "input size too large",
        error.AllocationFailed => "memory allocation failed",
        error.InvalidProtobufMessage => "invalid protobuf message format",
        error.ErrorMapCreationFailed => "failed to create error map",
        error.ResultMapCreationFailed => "failed to create result map",
        else => "unexpected error",
    };
}

fn make_binary(env: beam.env, bytes: []const u8) beam.term {
    var binary: e.ErlNifTerm = undefined;

    // Allocate a BEAM-managed binary and copy the result into it so the term
    // outlives any temporary C buffers returned by libpg_query.
    const data = e.enif_make_new_binary(env, bytes.len, &binary);

    if (bytes.len > 0) {
        @memcpy(data[0..bytes.len], bytes);
    }

    return .{ .v = binary };
}

fn make_error(env: beam.env, message: []const u8) beam.term {
    return error_term(env, make_binary(env, message).v);
}

fn ok_binary(env: beam.env, bytes: []const u8) beam.term {
    return ok_term(env, make_binary(env, bytes).v);
}

fn c_string_slice(ptr: [*c]const u8) []const u8 {
    return std.mem.span(ptr);
}

fn ptr_slice(ptr: [*c]const u8, len: usize) []const u8 {
    return ptr[0..len];
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

fn make_c_string(input: []const u8) ![*:0]u8 {
    if (std.mem.indexOfScalar(u8, input, 0) != null) {
        return error.ContainsNullByte;
    }

    if (input.len >= std.math.maxInt(usize) - 1) {
        return error.InputSizeTooLarge;
    }

    // libpg_query expects a mutable, NUL-terminated C string. We allocate it
    // with enif_alloc so it can be released with enif_free in the caller.
    const raw = e.enif_alloc(input.len + 1) orelse return error.AllocationFailed;

    const str = @as([*]u8, @ptrCast(raw));

    if (input.len > 0) {
        @memcpy(str[0..input.len], input);
    }

    str[input.len] = 0;

    return @as([*:0]u8, @ptrCast(str));
}

fn put_error_map_value(env: beam.env, map: *e.ErlNifTerm, key: [*:0]const u8, value: e.ErlNifTerm) !void {
    if (e.enif_make_map_put(env, map.*, atom(env, key), value, map) == 0) {
        return error.ErrorMapCreationFailed;
    }
}

fn put_result_map_value(env: beam.env, map: *e.ErlNifTerm, key: [*:0]const u8, value: e.ErlNifTerm) !void {
    if (e.enif_make_map_put(env, map.*, atom(env, key), value, map) == 0) {
        return error.ResultMapCreationFailed;
    }
}

fn create_parse_error_map(env: beam.env, err: [*c]const c.PgQueryError) !beam.term {
    var error_map = e.enif_make_new_map(env);
    const message_binary = make_binary(env, pg_query_error_message(err));

    try put_error_map_value(env, &error_map, "message", message_binary.v);
    try put_error_map_value(
        env,
        &error_map,
        "cursorpos",
        e.enif_make_int(env, err[0].cursorpos - 1),
    );

    return error_term(env, error_map);
}

fn parse_error_term(env: beam.env, err: [*c]const c.PgQueryError) beam.term {
    return create_parse_error_map(env, err) catch |create_err| beam_error(env, create_err);
}

/// Parses a SQL query into a serialized protobuf AST.
pub fn parse_protobuf(query: []const u8) beam.term {
    const env = beam.context.env;

    validate_input(query, max_sql_length) catch |err| return beam_error(env, err);
    const query_str = make_c_string(query) catch |err| return beam_error(env, err);
    defer e.enif_free(query_str);

    const result = c.pg_query_parse_protobuf(query_str);
    defer c.pg_query_free_protobuf_parse_result(result);

    if (result.@"error" != null) {
        return parse_error_term(env, &result.@"error"[0]);
    }

    return ok_binary(
        env,
        ptr_slice(@as([*c]const u8, @ptrCast(result.parse_tree.data)), result.parse_tree.len),
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
    defer e.enif_free(query_str);

    const result = c.pg_query_fingerprint(query_str);
    defer c.pg_query_free_fingerprint_result(result);

    if (result.@"error" != null) {
        return make_error(env, pg_query_error_message(&result.@"error"[0]));
    }

    var map = e.enif_make_new_map(env);
    const fingerprint_str = make_binary(env, c_string_slice(result.fingerprint_str));

    put_result_map_value(
        env,
        &map,
        "fingerprint",
        pginspect_make_uint64(env, result.fingerprint),
    ) catch |err| return beam_error(env, err);
    put_result_map_value(
        env,
        &map,
        "fingerprint_str",
        fingerprint_str.v,
    ) catch |err| return beam_error(env, err);

    return ok_term(env, map);
}

/// Scans SQL into libpg_query's protobuf token stream.
pub fn scan(query: []const u8) beam.term {
    const env = beam.context.env;

    validate_input(query, max_sql_length) catch |err| return beam_error(env, err);
    const query_str = make_c_string(query) catch |err| return beam_error(env, err);
    defer e.enif_free(query_str);

    const result = c.pg_query_scan(query_str);
    defer c.pg_query_free_scan_result(result);

    if (result.@"error" != null) {
        return parse_error_term(env, &result.@"error"[0]);
    }

    return ok_binary(
        env,
        ptr_slice(@as([*c]const u8, @ptrCast(result.pbuf.data)), result.pbuf.len),
    );
}

/// Normalizes SQL by replacing literals with placeholders.
pub fn normalize(query: []const u8) beam.term {
    const env = beam.context.env;

    validate_input(query, max_sql_length) catch |err| return beam_error(env, err);
    const query_str = make_c_string(query) catch |err| return beam_error(env, err);
    defer e.enif_free(query_str);

    const result = c.pg_query_normalize(query_str);
    defer c.pg_query_free_normalize_result(result);

    if (result.@"error" != null) {
        return make_error(env, pg_query_error_message(&result.@"error"[0]));
    }

    return ok_binary(env, c_string_slice(result.normalized_query));
}

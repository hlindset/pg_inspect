const std = @import("std");
const beam = @import("beam");
const e = @import("erl_nif");
const c = @cImport({
    @cInclude("pg_query.h");
    @cInclude("protobuf/pg_query.pb-c.h");
    @cInclude("protobuf-c/protobuf-c.h");
});
extern fn pginspect_make_uint64(env: beam.env, value: u64) e.ErlNifTerm;

const max_sql_length: usize = 16 * 1024 * 1024;
const max_protobuf_length: usize = 32 * 1024 * 1024;

fn make_binary(env: beam.env, bytes: []const u8) beam.term {
    var binary: e.ErlNifTerm = undefined;
    const data = e.enif_make_new_binary(env, bytes.len, &binary);

    if (bytes.len > 0) {
        @memcpy(data[0..bytes.len], bytes);
    }

    return .{ .v = binary };
}

fn make_error(env: beam.env, message: []const u8) beam.term {
    return .{
        .v = e.enif_make_tuple2(
            env,
            e.enif_make_atom(env, "error"),
            make_binary(env, message).v,
        ),
    };
}

fn make_success(env: beam.env, bytes: []const u8) beam.term {
    return .{
        .v = e.enif_make_tuple2(
            env,
            e.enif_make_atom(env, "ok"),
            make_binary(env, bytes).v,
        ),
    };
}

fn c_string_slice(ptr: [*c]const u8) []const u8 {
    return std.mem.span(ptr);
}

fn binary_slice(binary: e.ErlNifBinary) []const u8 {
    return binary.data[0..binary.size];
}

fn ptr_slice(ptr: [*c]const u8, len: usize) []const u8 {
    return ptr[0..len];
}

fn validate_input(
    env: beam.env,
    input: []const u8,
    max_length: usize,
) ?beam.term {
    if (input.len > max_length) {
        return make_error(env, "input too large");
    }

    return null;
}

fn mk_cstr(
    env: beam.env,
    input: []const u8,
    error_term: *beam.term,
) ?[*:0]u8 {
    if (std.mem.indexOfScalar(u8, input, 0) != null) {
        error_term.* = make_error(env, "argument must not contain null bytes");
        return null;
    }

    if (input.len >= std.math.maxInt(usize) - 1) {
        error_term.* = make_error(env, "input size too large");
        return null;
    }

    const raw = e.enif_alloc(input.len + 1) orelse {
        error_term.* = make_error(env, "memory allocation failed");
        return null;
    };

    const str = @as([*]u8, @ptrCast(raw));

    if (input.len > 0) {
        @memcpy(str[0..input.len], input);
    }

    str[input.len] = 0;

    return @as([*:0]u8, @ptrCast(str));
}

fn create_parse_error_map(env: beam.env, err: [*c]const c.PgQueryError) beam.term {
    var error_map = e.enif_make_new_map(env);
    const message_binary = make_binary(env, c_string_slice(err[0].message));

    if (e.enif_make_map_put(
        env,
        error_map,
        e.enif_make_atom(env, "message"),
        message_binary.v,
        &error_map,
    ) == 0) {
        return make_error(env, "failed to create error map");
    }

    if (e.enif_make_map_put(
        env,
        error_map,
        e.enif_make_atom(env, "cursorpos"),
        e.enif_make_int(env, err[0].cursorpos - 1),
        &error_map,
    ) == 0) {
        return make_error(env, "failed to create error map");
    }

    return .{ .v = e.enif_make_tuple2(env, e.enif_make_atom(env, "error"), error_map) };
}

/// Parses a SQL query into a serialized protobuf AST.
pub fn parse_protobuf(query: []const u8) beam.term {
    const env = beam.context.env;

    if (validate_input(env, query, max_sql_length)) |error_term| {
        return error_term;
    }

    var error_term: beam.term = undefined;
    const query_str = mk_cstr(env, query, &error_term) orelse return error_term;
    defer e.enif_free(query_str);

    const result = c.pg_query_parse_protobuf(query_str);
    defer c.pg_query_free_protobuf_parse_result(result);

    if (result.@"error" != null) {
        return create_parse_error_map(env, &result.@"error"[0]);
    }

    return make_success(
        env,
        ptr_slice(@as([*c]const u8, @ptrCast(result.parse_tree.data)), result.parse_tree.len),
    );
}

/// Converts a serialized protobuf AST back into SQL text.
pub fn deparse_protobuf(input: []const u8) beam.term {
    const env = beam.context.env;

    if (validate_input(env, input, max_protobuf_length)) |error_term| {
        return error_term;
    }

    const msg = c.pg_query__parse_result__unpack(null, input.len, input.ptr);

    if (msg == null or c.protobuf_c_message_check(&msg[0].base) == 0) {
        if (msg != null) {
            c.pg_query__parse_result__free_unpacked(msg, null);
        }

        return make_error(env, "invalid protobuf message format");
    }

    c.pg_query__parse_result__free_unpacked(msg, null);

    const protobuf = c.PgQueryProtobuf{
        .len = input.len,
        .data = @constCast(@ptrCast(input.ptr)),
    };

    const result = c.pg_query_deparse_protobuf(protobuf);
    defer c.pg_query_free_deparse_result(result);

    if (result.@"error" != null) {
        return make_error(env, c_string_slice(result.@"error"[0].message));
    }

    return make_success(env, c_string_slice(result.query));
}

/// Generates a fingerprint for a SQL query.
pub fn fingerprint(query: []const u8) beam.term {
    const env = beam.context.env;

    if (validate_input(env, query, max_sql_length)) |error_term| {
        return error_term;
    }

    var error_term: beam.term = undefined;
    const query_str = mk_cstr(env, query, &error_term) orelse return error_term;
    defer e.enif_free(query_str);

    const result = c.pg_query_fingerprint(query_str);
    defer c.pg_query_free_fingerprint_result(result);

    if (result.@"error" != null) {
        return make_error(env, c_string_slice(result.@"error"[0].message));
    }

    var map = e.enif_make_new_map(env);
    const fingerprint_str = make_binary(env, c_string_slice(result.fingerprint_str));

    if (e.enif_make_map_put(
        env,
        map,
        e.enif_make_atom(env, "fingerprint"),
        pginspect_make_uint64(env, result.fingerprint),
        &map,
    ) == 0) {
        return make_error(env, "failed to create result map");
    }

    if (e.enif_make_map_put(
        env,
        map,
        e.enif_make_atom(env, "fingerprint_str"),
        fingerprint_str.v,
        &map,
    ) == 0) {
        return make_error(env, "failed to create result map");
    }

    return .{ .v = e.enif_make_tuple2(env, e.enif_make_atom(env, "ok"), map) };
}

/// Scans SQL into libpg_query's protobuf token stream.
pub fn scan(query: []const u8) beam.term {
    const env = beam.context.env;

    if (validate_input(env, query, max_sql_length)) |error_term| {
        return error_term;
    }

    var error_term: beam.term = undefined;
    const query_str = mk_cstr(env, query, &error_term) orelse return error_term;
    defer e.enif_free(query_str);

    const result = c.pg_query_scan(query_str);
    defer c.pg_query_free_scan_result(result);

    if (result.@"error" != null) {
        return create_parse_error_map(env, &result.@"error"[0]);
    }

    return make_success(
        env,
        ptr_slice(@as([*c]const u8, @ptrCast(result.pbuf.data)), result.pbuf.len),
    );
}

/// Normalizes SQL by replacing literals with placeholders.
pub fn normalize(query: []const u8) beam.term {
    const env = beam.context.env;

    if (validate_input(env, query, max_sql_length)) |error_term| {
        return error_term;
    }

    var error_term: beam.term = undefined;
    const query_str = mk_cstr(env, query, &error_term) orelse return error_term;
    defer e.enif_free(query_str);

    const result = c.pg_query_normalize(query_str);
    defer c.pg_query_free_normalize_result(result);

    if (result.@"error" != null) {
        return make_error(env, c_string_slice(result.@"error"[0].message));
    }

    return make_success(env, c_string_slice(result.normalized_query));
}

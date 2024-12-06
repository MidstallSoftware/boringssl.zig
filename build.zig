const std = @import("std");
const mem = std.mem;
const fs = std.fs;

fn collectSources(b: *std.Build, path: std.Build.LazyPath, extensions: []const []const u8, is_test: bool, access_sub_paths: bool) []const []const u8 {
    const p = path.getPath(b);

    var dir = fs.openDirAbsolute(p, .{
        .iterate = true,
        .access_sub_paths = access_sub_paths,
    }) catch |e| std.debug.panic("Failed to open {s}: {s}", .{ p, @errorName(e) });
    defer dir.close();

    var list = std.ArrayList([]const u8).init(b.allocator);
    defer list.deinit();

    if (access_sub_paths) {
        var iter = dir.walk(b.allocator) catch @panic("OOM");
        defer iter.deinit();

        while (iter.next() catch |e| std.debug.panic("Failed to iterate {s}: {s}", .{ p, @errorName(e) })) |entry| {
            if (entry.kind != .file) continue;

            const ext = fs.path.extension(entry.basename);

            if ((mem.startsWith(u8, entry.path, "test") or mem.endsWith(u8, fs.path.stem(entry.basename), "_test")) and !is_test) {
                continue;
            }

            for (extensions) |e| {
                if (ext.len < 1) continue;
                if (mem.eql(u8, ext[1..], e)) {
                    list.append(b.allocator.dupe(u8, entry.path) catch @panic("OOM")) catch @panic("OOM");
                    break;
                }
            }
        }
    } else {
        var iter = dir.iterate();
        while (iter.next() catch |e| std.debug.panic("Failed to iterate {s}: {s}", .{ p, @errorName(e) })) |entry| {
            if (entry.kind != .file) continue;

            const ext = fs.path.extension(entry.name);

            if (mem.endsWith(u8, fs.path.stem(entry.name), "_test") and !is_test) {
                continue;
            }

            for (extensions) |e| {
                if (mem.eql(u8, ext[1..], e)) {
                    list.append(b.allocator.dupe(u8, entry.name) catch @panic("OOM")) catch @panic("OOM");
                    break;
                }
            }
        }
    }

    return list.toOwnedSlice() catch |e| std.debug.panic("Failed to allocate memory: {s}", .{@errorName(e)});
}

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const linkage = b.option(std.builtin.LinkMode, "linkage", "whether to statically or dynamically link the library") orelse @as(std.builtin.LinkMode, if (target.result.isGnuLibC()) .dynamic else .static);

    const boringssl_dep = b.dependency("boringssl", .{});

    const cflags: []const []const u8 = &.{
        b.fmt("-DOPENSSL_{s}", .{std.ascii.allocUpperString(b.allocator, @tagName(target.result.cpu.arch)) catch @panic("OOM")}),
    };

    const libcrypto = std.Build.Step.Compile.create(b, .{
        .name = "crypto",
        .root_module = .{
            .target = target,
            .optimize = optimize,
            .link_libcpp = true,
        },
        .kind = .lib,
        .linkage = linkage,
    });

    libcrypto.addCSourceFiles(.{
        .root = boringssl_dep.path("crypto"),
        .files = collectSources(b, boringssl_dep.path("crypto"), &.{"cc"}, false, true),
        .flags = cflags,
    });

    libcrypto.addCSourceFiles(.{
        .root = boringssl_dep.path("gen/bcm"),
        .files = collectSources(b, boringssl_dep.path("gen/bcm"), &.{"S"}, false, true),
        .flags = cflags,
    });

    libcrypto.addCSourceFiles(.{
        .root = boringssl_dep.path("crypto"),
        .files = &.{
            "curve25519/asm/x25519-asm-arm.S",
            "hrss/asm/poly_rq_mul.S",
            "poly1305/poly1305_arm_asm.S",
        },
        .flags = cflags,
    });

    libcrypto.addCSourceFiles(.{
        .root = boringssl_dep.path("third_party/fiat/asm"),
        .files = &.{
            "fiat_curve25519_adx_mul.S",
            "fiat_curve25519_adx_square.S",
            "fiat_p256_adx_mul.S",
            "fiat_p256_adx_sqr.S",
        },
        .flags = cflags,
    });

    libcrypto.addCSourceFiles(.{
        .root = boringssl_dep.path("gen/crypto"),
        .files = collectSources(b, boringssl_dep.path("gen/crypto"), &.{"S"}, false, true),
        .flags = cflags,
    });

    libcrypto.addCSourceFile(.{
        .file = boringssl_dep.path("gen/crypto/err_data.cc"),
        .flags = cflags,
    });

    libcrypto.addIncludePath(boringssl_dep.path("include"));
    libcrypto.installHeadersDirectory(boringssl_dep.path("include/openssl"), "openssl", .{});
    b.installArtifact(libcrypto);

    const libdecrepit = std.Build.Step.Compile.create(b, .{
        .name = "decrepit",
        .root_module = .{
            .target = target,
            .optimize = optimize,
            .link_libcpp = true,
        },
        .kind = .lib,
        .linkage = linkage,
    });

    libdecrepit.addCSourceFiles(.{
        .root = boringssl_dep.path("decrepit"),
        .files = collectSources(b, boringssl_dep.path("decrepit"), &.{"cc"}, false, true),
        .flags = cflags,
    });

    libdecrepit.addIncludePath(boringssl_dep.path("include"));
    libdecrepit.installHeadersDirectory(boringssl_dep.path("include/openssl"), "openssl", .{});
    b.installArtifact(libdecrepit);

    const libssl = std.Build.Step.Compile.create(b, .{
        .name = "ssl",
        .root_module = .{
            .target = target,
            .optimize = optimize,
            .link_libcpp = true,
        },
        .kind = .lib,
        .linkage = linkage,
    });

    libssl.addCSourceFiles(.{
        .root = boringssl_dep.path("ssl"),
        .files = collectSources(b, boringssl_dep.path("ssl"), &.{"cc"}, false, false),
        .flags = cflags,
    });

    libssl.addIncludePath(boringssl_dep.path("include"));
    libssl.installHeadersDirectory(boringssl_dep.path("include/openssl"), "openssl", .{});
    b.installArtifact(libssl);

    const bssl = b.addExecutable(.{
        .name = "bssl",
        .target = target,
        .optimize = optimize,
        .linkage = linkage,
    });

    bssl.addCSourceFiles(.{
        .root = boringssl_dep.path("tool"),
        .files = collectSources(b, boringssl_dep.path("tool"), &.{"cc"}, false, false),
        .flags = cflags,
    });

    bssl.addIncludePath(boringssl_dep.path("include"));
    bssl.linkLibCpp();
    bssl.linkLibrary(libcrypto);
    bssl.linkLibrary(libssl);

    b.installArtifact(bssl);
}

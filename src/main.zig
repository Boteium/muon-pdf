const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    // The shim headers declare the GTK/GLib and MuPDF surface this app
    // uses; zig 0.16's translate-c cannot handle the real <gtk/gtk.h> and
    // <mupdf/fitz.h> yet (see the comments in the shims).
    @cInclude("gtk_shim.h");
    @cInclude("mupdf_shim.h");
    @cInclude("stdlib.h"); // realpath, free
});

const PersistedState = struct {
    page_index: u32 = 0,
    zoom: f64 = 1.0,
    pan_x: f64 = 0.0,
    pan_y: f64 = 0.0,
    rotate_turns: u8 = 0,
};

const MinZoom: f64 = 0.5;
const MaxZoom: f64 = 2.5;
const ZoomStep: f64 = 0.05;

const RenderedPage = struct {
    width: i32,
    height: i32,
    stride: i32,
    pixels: []u8,
};

const AppState = struct {
    allocator: std.mem.Allocator,
    gtk_app: ?*c.GtkApplication = null,
    window: ?*c.GtkWidget = null,
    overlay: ?*c.GtkWidget = null,
    scroller: ?*c.GtkWidget = null,
    picture: ?*c.GtkWidget = null,
    pan_controls: ?*c.GtkWidget = null,
    open_btn: ?*c.GtkWidget = null,
    zoom_out_btn: ?*c.GtkWidget = null,
    zoom_in_btn: ?*c.GtkWidget = null,
    pan_up_btn: ?*c.GtkWidget = null,
    pan_down_btn: ?*c.GtkWidget = null,
    pan_left_btn: ?*c.GtkWidget = null,
    pan_right_btn: ?*c.GtkWidget = null,
    menu_fullscreen_item: ?*c.GtkWidget = null,
    menu_rotate_item: ?*c.GtkWidget = null,
    menu_hide_ui_item: ?*c.GtkWidget = null,
    feedback_label: ?*c.GtkWidget = null,
    page_indicator_label: ?*c.GtkWidget = null,
    title_label: ?*c.GtkWidget = null,

    mupdf_ctx: ?*c.fz_context = null,
    mupdf_doc: ?*c.fz_document = null,

    current_file_path: ?[]u8 = null,
    current_cache_path: ?[]u8 = null,
    rendered_pixels: ?[]u8 = null,

    total_pages: i32 = 0,
    current_page: i32 = 0,
    zoom: f64 = 1.0,
    pan_x: f64 = 0.0,
    pan_y: f64 = 0.0,
    rotate_turns: u8 = 0,
    ui_hidden: bool = false,
    fit_scale: f64 = 1.0,
    open_on_activate: ?[]u8 = null,
    last_view_w: i32 = -1,
    last_view_h: i32 = -1,
    swipe_claimed: bool = false,
    suppress_tap_until_ms: i64 = 0,
    last_page_nav_ms: i64 = 0,
    open_btn_timeout_id: c.guint = 0,
    zoom_out_btn_timeout_id: c.guint = 0,
    zoom_in_btn_timeout_id: c.guint = 0,
    pan_up_btn_timeout_id: c.guint = 0,
    pan_down_btn_timeout_id: c.guint = 0,
    pan_left_btn_timeout_id: c.guint = 0,
    pan_right_btn_timeout_id: c.guint = 0,
    feedback_timeout_id: c.guint = 0,
};

fn cstrDup(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return try allocator.dupe(u8, text);
}

fn maybeFree(allocator: std.mem.Allocator, data: *?[]u8) void {
    if (data.*) |buf| {
        allocator.free(buf);
        data.* = null;
    }
}

fn openMupdfIfNeeded(state: *AppState) !void {
    if (state.mupdf_ctx != null) return;
    const ctx = c.fz_new_context(null, null, c.FZ_STORE_DEFAULT);
    if (ctx == null) return error.MuPdfContextInitFailed;
    c.fz_register_document_handlers(ctx);
    state.mupdf_ctx = ctx;
}

fn dropDocument(state: *AppState) void {
    if (state.mupdf_doc) |doc| {
        c.fz_drop_document(state.mupdf_ctx.?, doc);
        state.mupdf_doc = null;
    }
    state.total_pages = 0;
    state.current_page = 0;
}

// File system and clock access goes through GLib/libc rather than std.fs and
// std.time: zig 0.16 reworked those around the new std.Io interface, while
// the C APIs are identical on every zig version this project supports.
fn resolveAbsolutePath(allocator: std.mem.Allocator, in_path: []const u8) ![]u8 {
    const in_z = try allocator.dupeZ(u8, in_path);
    defer allocator.free(in_z);
    const resolved = c.realpath(in_z.ptr, null) orelse return error.FileNotFound;
    defer c.free(resolved);
    return try allocator.dupe(u8, std.mem.span(resolved));
}

fn computeCachePath(allocator: std.mem.Allocator, abs_pdf_path: []const u8) ![]u8 {
    const home_c = c.g_getenv("HOME") orelse return error.MissingHome;
    const home = std.mem.span(home_c);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(abs_pdf_path, &digest, .{});
    const hash_hex = std.fmt.bytesToHex(digest, .lower);

    // Trailing NUL included so .ptr can go straight to C; the slice is
    // temporary and never used as a string on the Zig side.
    const cache_dir_z = try std.fmt.allocPrint(allocator, "{s}/.cache/muon-pdf\x00", .{home});
    defer allocator.free(cache_dir_z);
    if (c.g_mkdir_with_parents(cache_dir_z.ptr, 0o755) != 0) return error.CacheDirUnavailable;

    return try std.fmt.allocPrint(allocator, "{s}/.cache/muon-pdf/{s}.json", .{ home, hash_hex });
}

fn loadPersistedState(state: *AppState) PersistedState {
    const cache_path = state.current_cache_path orelse return .{};
    const path_z = state.allocator.dupeZ(u8, cache_path) catch return .{};
    defer state.allocator.free(path_z);

    var contents: [*c]u8 = null;
    var length: c.gsize = 0;
    if (c.g_file_get_contents(path_z.ptr, &contents, &length, null) == 0) return .{};
    defer c.g_free(contents);
    if (length > 16 * 1024) return .{};

    const parsed = std.json.parseFromSlice(PersistedState, state.allocator, contents[0..length], .{}) catch return .{};
    defer parsed.deinit();
    return parsed.value;
}

fn savePersistedState(state: *AppState) void {
    const cache_path = state.current_cache_path orelse return;
    const path_z = state.allocator.dupeZ(u8, cache_path) catch return;
    defer state.allocator.free(path_z);

    const serialized = std.fmt.allocPrint(
        state.allocator,
        "{{\"page_index\":{},\"zoom\":{d:.6},\"pan_x\":{d:.6},\"pan_y\":{d:.6},\"rotate_turns\":{}}}",
        .{ state.current_page, state.zoom, state.pan_x, state.pan_y, state.rotate_turns },
    ) catch return;
    defer state.allocator.free(serialized);
    _ = c.g_file_set_contents(path_z.ptr, serialized.ptr, @intCast(serialized.len), null);
}

// Monotonic milliseconds; only ever compared against itself for debouncing.
fn nowMs() i64 {
    return @divTrunc(c.g_get_monotonic_time(), 1000);
}

fn getCurrentPageRect(state: *AppState) !c.fz_rect {
    const ctx = state.mupdf_ctx orelse return error.MuPdfNotReady;
    const doc = state.mupdf_doc orelse return error.DocumentNotReady;
    const page = c.fz_load_page(ctx, doc, state.current_page);
    if (page == null) return error.PageLoadFailed;
    defer c.fz_drop_page(ctx, page);
    return c.fz_bound_page(ctx, page);
}

fn computeFitScale(state: *AppState) !void {
    const scroller = state.scroller orelse return;
    const view_w = c.gtk_widget_get_width(scroller);
    const view_h = c.gtk_widget_get_height(scroller);
    if (view_w <= 0 or view_h <= 0) return error.ViewportNotReady;

    const rect = try getCurrentPageRect(state);
    const page_w = @as(f64, rect.x1 - rect.x0);
    const page_h = @as(f64, rect.y1 - rect.y0);
    if (page_w <= 0 or page_h <= 0) return;

    const fit_w = @as(f64, @floatFromInt(view_w)) / page_w;
    const fit_h = @as(f64, @floatFromInt(view_h)) / page_h;
    state.fit_scale = @min(fit_w, fit_h);
}

fn renderCurrentPage(state: *AppState) !void {
    const ctx = state.mupdf_ctx orelse return error.MuPdfNotReady;
    const doc = state.mupdf_doc orelse return error.DocumentNotReady;
    const picture = state.picture orelse return;

    try computeFitScale(state);
    const final_scale = state.fit_scale * state.zoom;
    if (final_scale <= 0) return error.InvalidScale;

    var ctm = c.fz_scale(@floatCast(final_scale), @floatCast(final_scale));
    const degrees = 90.0 * @as(f64, @floatFromInt(@mod(state.rotate_turns, 4)));
    if (@abs(degrees) > 0.0001) {
        ctm = c.fz_concat(ctm, c.fz_rotate(@floatCast(degrees)));
    }
    const pix = c.fz_new_pixmap_from_page_number(
        ctx,
        doc,
        state.current_page,
        ctm,
        c.fz_device_rgb(ctx),
        0,
    );
    if (pix == null) return error.PixmapAllocFailed;
    defer c.fz_drop_pixmap(ctx, pix);

    const w = c.fz_pixmap_width(ctx, pix);
    const h = c.fz_pixmap_height(ctx, pix);
    const stride = c.fz_pixmap_stride(ctx, pix);
    const src_ptr = c.fz_pixmap_samples(ctx, pix);
    const src_len: usize = @intCast(stride * h);

    // g_bytes_new copies the incoming bytes, so the texture does not depend on
    // temporary MuPDF pixmap memory (or a manually managed side buffer).
    const bytes = c.g_bytes_new(@ptrCast(src_ptr), src_len);
    defer c.g_bytes_unref(bytes);
    const texture = c.gdk_memory_texture_new(
        w,
        h,
        c.GDK_MEMORY_R8G8B8,
        bytes,
        @intCast(stride),
    );
    defer c.g_object_unref(texture);

    c.gtk_picture_set_paintable(@ptrCast(picture), @ptrCast(texture));
    updateWindowTitle(state);
    applyPan(state);
    updatePanControlsVisibility(state);
    _ = c.g_idle_add(@ptrCast(&onPanVisibilityIdle), state);
}

fn queueRender(state: *AppState) void {
    if (state.mupdf_doc == null) return;
    renderCurrentPage(state) catch |err| switch (err) {
        error.ViewportNotReady => {
            _ = c.g_idle_add(@ptrCast(&onRenderIdle), state);
        },
        else => {
            var msg_buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "Render failed: {s}", .{@errorName(err)}) catch "Render failed";
            showErrorDialog(state, msg);
        },
    };
}

fn refreshIfViewportChanged(state: *AppState) void {
    const scroller = state.scroller orelse return;
    const view_w = c.gtk_widget_get_width(scroller);
    const view_h = c.gtk_widget_get_height(scroller);
    if (view_w <= 0 or view_h <= 0) return;
    if (view_w == state.last_view_w and view_h == state.last_view_h) return;

    state.last_view_w = view_w;
    state.last_view_h = view_h;
    queueRender(state);
}

fn updatePanControlsVisibility(state: *AppState) void {
    const has_doc = state.mupdf_doc != null;
    const show_aux_ui = has_doc and !state.ui_hidden;

    if (state.menu_fullscreen_item) |item| c.gtk_widget_set_visible(item, if (has_doc) 1 else 0);
    if (state.menu_rotate_item) |item| c.gtk_widget_set_visible(item, if (has_doc) 1 else 0);
    if (state.menu_hide_ui_item) |item| c.gtk_widget_set_visible(item, if (has_doc) 1 else 0);

    if (state.zoom_out_btn) |btn| c.gtk_widget_set_visible(btn, if (show_aux_ui) 1 else 0);
    if (state.zoom_in_btn) |btn| c.gtk_widget_set_visible(btn, if (show_aux_ui) 1 else 0);
    if (state.page_indicator_label) |label| c.gtk_widget_set_visible(label, if (has_doc) 1 else 0);

    if (!has_doc) {
        if (state.pan_controls) |pan_controls| c.gtk_widget_set_visible(pan_controls, 0);
        if (state.open_btn) |open_btn| {
            c.gtk_widget_add_css_class(open_btn, "controls-active");
            if (state.open_btn_timeout_id != 0) {
                _ = c.g_source_remove(state.open_btn_timeout_id);
                state.open_btn_timeout_id = 0;
            }
        }
        return;
    }
    if (state.ui_hidden) {
        if (state.pan_controls) |pan_controls| c.gtk_widget_set_visible(pan_controls, 0);
        if (state.open_btn) |open_btn| {
            if (state.open_btn_timeout_id == 0) {
                c.gtk_widget_remove_css_class(open_btn, "controls-active");
            }
        }
        return;
    }

    const scroller = state.scroller orelse return;
    const hadj = c.gtk_scrolled_window_get_hadjustment(@ptrCast(scroller));
    const vadj = c.gtk_scrolled_window_get_vadjustment(@ptrCast(scroller));

    var can_left = false;
    var can_right = false;
    var can_up = false;
    var can_down = false;
    const eps = 1.0;

    if (hadj != null) {
        const h_upper = c.gtk_adjustment_get_upper(hadj);
        const h_page = c.gtk_adjustment_get_page_size(hadj);
        const h_value = c.gtk_adjustment_get_value(hadj);
        const h_max = @max(@as(f64, 0), h_upper - h_page);
        can_left = h_max > eps and h_value > eps;
        can_right = h_max > eps and h_value < (h_max - eps);
    }
    if (vadj != null) {
        const v_upper = c.gtk_adjustment_get_upper(vadj);
        const v_page = c.gtk_adjustment_get_page_size(vadj);
        const v_value = c.gtk_adjustment_get_value(vadj);
        const v_max = @max(@as(f64, 0), v_upper - v_page);
        can_up = v_max > eps and v_value > eps;
        can_down = v_max > eps and v_value < (v_max - eps);
    }

    setArrowButtonState(state.pan_left_btn, can_left);
    setArrowButtonState(state.pan_right_btn, can_right);
    setArrowButtonState(state.pan_up_btn, can_up);
    setArrowButtonState(state.pan_down_btn, can_down);

    if (state.pan_controls) |pan_controls| {
        c.gtk_widget_set_visible(pan_controls, if (can_left or can_right or can_up or can_down) 1 else 0);
    }

    if (state.open_btn) |open_btn| {
        if (state.open_btn_timeout_id == 0) {
            c.gtk_widget_remove_css_class(open_btn, "controls-active");
        }
    }
}

fn setArrowButtonState(btn: ?*c.GtkWidget, enabled: bool) void {
    if (btn == null) return;
    const w = btn.?;
    c.gtk_widget_set_visible(w, 1);
    c.gtk_widget_set_sensitive(w, if (enabled) 1 else 0);
    if (enabled) {
        c.gtk_widget_remove_css_class(w, "edge-disabled");
    } else {
        c.gtk_widget_add_css_class(w, "edge-disabled");
    }
}

fn onPanVisibilityIdle(user_data: ?*anyopaque) callconv(.c) c.gboolean {
    if (user_data == null) return 0;
    const state: *AppState = @ptrCast(@alignCast(user_data.?));
    updatePanControlsVisibility(state);
    return 0;
}

fn activateButtonWithTimeout(
    state: *AppState,
    btn: ?*c.GtkWidget,
    timeout_id: *c.guint,
    callback: *const fn (?*anyopaque) callconv(.c) c.gboolean,
) void {
    if (btn == null) return;
    const widget: *c.GtkWidget = btn.?;

    if (state.open_btn != null and widget == state.open_btn.? and state.mupdf_doc == null) {
        c.gtk_widget_add_css_class(widget, "controls-active");
        return;
    }

    c.gtk_widget_add_css_class(widget, "controls-active");
    if (timeout_id.* != 0) {
        _ = c.g_source_remove(timeout_id.*);
    }
    timeout_id.* = c.g_timeout_add(500, @ptrCast(callback), state);
}

fn applyPan(state: *AppState) void {
    const scroller = state.scroller orelse return;
    const hadj = c.gtk_scrolled_window_get_hadjustment(@ptrCast(scroller));
    const vadj = c.gtk_scrolled_window_get_vadjustment(@ptrCast(scroller));
    if (hadj == null or vadj == null) return;

    const h_upper = c.gtk_adjustment_get_upper(hadj);
    const h_page = c.gtk_adjustment_get_page_size(hadj);
    const v_upper = c.gtk_adjustment_get_upper(vadj);
    const v_page = c.gtk_adjustment_get_page_size(vadj);

    const max_h = @max(@as(f64, 0), h_upper - h_page);
    const max_v = @max(@as(f64, 0), v_upper - v_page);
    state.pan_x = std.math.clamp(state.pan_x, 0, max_h);
    state.pan_y = std.math.clamp(state.pan_y, 0, max_v);

    c.gtk_adjustment_set_value(hadj, state.pan_x);
    c.gtk_adjustment_set_value(vadj, state.pan_y);
}

fn notifyBlockedAction(state: *AppState, msg: []const u8) void {
    const label = state.feedback_label orelse return;
    const z_msg = state.allocator.dupeZ(u8, msg) catch return;
    defer state.allocator.free(z_msg);
    c.gtk_label_set_text(@ptrCast(label), z_msg);
    c.gtk_widget_set_visible(label, 1);
    c.gtk_widget_set_opacity(label, 1.0);
    c.gtk_widget_add_css_class(label, "feedback-active");

    if (state.feedback_timeout_id != 0) {
        _ = c.g_source_remove(state.feedback_timeout_id);
    }
    state.feedback_timeout_id = c.g_timeout_add(700, @ptrCast(&onFeedbackHideTimeout), state);
}

fn updateWindowTitle(state: *AppState) void {
    const window = state.window orelse return;
    var title_buf: [256]u8 = undefined;
    const title = std.fmt.bufPrint(
        &title_buf,
        "muon-pdf {d}/{d} ({d:.0}%)",
        .{ state.current_page + 1, state.total_pages, state.zoom * 100.0 },
    ) catch "muon-pdf";
    const z_title = state.allocator.dupeZ(u8, title) catch return;
    defer state.allocator.free(z_title);
    c.gtk_window_set_title(@ptrCast(window), z_title);

    if (state.page_indicator_label) |label| {
        var page_buf: [64]u8 = undefined;
        const page_text = std.fmt.bufPrint(
            &page_buf,
            "{d}/{d}",
            .{ state.current_page + 1, state.total_pages },
        ) catch return;
        const z_page_text = state.allocator.dupeZ(u8, page_text) catch return;
        defer state.allocator.free(z_page_text);
        c.gtk_label_set_text(@ptrCast(label), z_page_text);
    }
}

fn openDocumentAtPath(state: *AppState, path: []const u8) !void {
    try openMupdfIfNeeded(state);
    const ctx = state.mupdf_ctx.?;

    const abs_path = try resolveAbsolutePath(state.allocator, path);
    errdefer state.allocator.free(abs_path);

    const z_path = try state.allocator.dupeZ(u8, abs_path);
    defer state.allocator.free(z_path);

    dropDocument(state);
    const doc = c.fz_open_document(ctx, z_path.ptr);
    if (doc == null) return error.DocumentOpenFailed;
    state.mupdf_doc = doc;
    state.total_pages = c.fz_count_pages(ctx, doc);
    if (state.total_pages <= 0) return error.EmptyPdf;

    maybeFree(state.allocator, &state.current_file_path);
    state.current_file_path = abs_path;

    maybeFree(state.allocator, &state.current_cache_path);
    state.current_cache_path = try computeCachePath(state.allocator, abs_path);

    const cached = loadPersistedState(state);
    state.current_page = @intCast(@min(@as(i32, @intCast(cached.page_index)), state.total_pages - 1));
    state.zoom = std.math.clamp(cached.zoom, MinZoom, MaxZoom);
    state.pan_x = @max(cached.pan_x, 0.0);
    state.pan_y = @max(cached.pan_y, 0.0);
    state.rotate_turns = @mod(cached.rotate_turns, 4);

    queueRender(state);
}

fn pageNext(state: *AppState) void {
    if (state.current_page + 1 >= state.total_pages) {
        notifyBlockedAction(state, "Last page");
        return;
    }
    const now = nowMs();
    if (now - state.last_page_nav_ms < 135) return;
    state.last_page_nav_ms = now;
    goToPagePreserveCenter(state, state.current_page + 1);
}

fn pagePrev(state: *AppState) void {
    if (state.current_page <= 0) {
        notifyBlockedAction(state, "First page");
        return;
    }
    const now = nowMs();
    if (now - state.last_page_nav_ms < 135) return;
    state.last_page_nav_ms = now;
    goToPagePreserveCenter(state, state.current_page - 1);
}

fn goToPagePreserveCenter(state: *AppState, target_page: i32) void {
    if (target_page < 0 or target_page >= state.total_pages) return;
    if (target_page == state.current_page) return;

    const scroller = state.scroller;
    var hadj: ?*c.GtkAdjustment = null;
    var vadj: ?*c.GtkAdjustment = null;
    var center_page_x: f64 = 0;
    var center_page_y: f64 = 0;
    var has_center = false;

    if (scroller) |s| {
        hadj = c.gtk_scrolled_window_get_hadjustment(@ptrCast(s));
        vadj = c.gtk_scrolled_window_get_vadjustment(@ptrCast(s));
        if (hadj != null and vadj != null) {
            const old_scale = state.fit_scale * state.zoom;
            if (old_scale > 0.000001) {
                const old_view_w = c.gtk_adjustment_get_page_size(hadj.?);
                const old_view_h = c.gtk_adjustment_get_page_size(vadj.?);
                const old_center_x = c.gtk_adjustment_get_value(hadj.?) + old_view_w / 2.0;
                const old_center_y = c.gtk_adjustment_get_value(vadj.?) + old_view_h / 2.0;
                center_page_x = old_center_x / old_scale;
                center_page_y = old_center_y / old_scale;
                has_center = true;
            }
        }
    }

    state.current_page = target_page;
    renderCurrentPage(state) catch {};

    if (has_center and hadj != null and vadj != null and scroller != null) {
        const new_hadj = c.gtk_scrolled_window_get_hadjustment(@ptrCast(scroller.?)) orelse hadj.?;
        const new_vadj = c.gtk_scrolled_window_get_vadjustment(@ptrCast(scroller.?)) orelse vadj.?;
        const new_view_w = c.gtk_adjustment_get_page_size(new_hadj);
        const new_view_h = c.gtk_adjustment_get_page_size(new_vadj);
        const new_scale = state.fit_scale * state.zoom;
        if (new_scale > 0.000001) {
            state.pan_x = center_page_x * new_scale - new_view_w / 2.0;
            state.pan_y = center_page_y * new_scale - new_view_h / 2.0;
            applyPan(state);
            updatePanControlsVisibility(state);
        }
    }

    savePersistedState(state);
}

fn zoomIn(state: *AppState) void {
    zoomTo(state, state.zoom + ZoomStep);
}

fn zoomOut(state: *AppState) void {
    zoomTo(state, state.zoom - ZoomStep);
}

fn rotateClockwise(state: *AppState) void {
    if (state.mupdf_doc == null) return;
    state.rotate_turns = @mod(state.rotate_turns + 1, 4);
    renderCurrentPage(state) catch {};
    savePersistedState(state);
}

fn zoomTo(state: *AppState, target_zoom: f64) void {
    if (state.mupdf_doc == null) return;
    const clamped_zoom = std.math.clamp(target_zoom, MinZoom, MaxZoom);
    if (std.math.approxEqAbs(f64, clamped_zoom, state.zoom, 0.000001)) return;

    const scroller = state.scroller orelse {
        state.zoom = clamped_zoom;
        renderCurrentPage(state) catch {};
        savePersistedState(state);
        return;
    };
    const hadj = c.gtk_scrolled_window_get_hadjustment(@ptrCast(scroller));
    const vadj = c.gtk_scrolled_window_get_vadjustment(@ptrCast(scroller));
    if (hadj == null or vadj == null) {
        state.zoom = clamped_zoom;
        renderCurrentPage(state) catch {};
        savePersistedState(state);
        return;
    }

    const old_scale = state.fit_scale * state.zoom;
    if (old_scale <= 0.000001) {
        state.zoom = clamped_zoom;
        renderCurrentPage(state) catch {};
        savePersistedState(state);
        return;
    }

    const old_view_w = c.gtk_adjustment_get_page_size(hadj);
    const old_view_h = c.gtk_adjustment_get_page_size(vadj);
    const old_center_x = c.gtk_adjustment_get_value(hadj) + old_view_w / 2.0;
    const old_center_y = c.gtk_adjustment_get_value(vadj) + old_view_h / 2.0;

    const center_page_x = old_center_x / old_scale;
    const center_page_y = old_center_y / old_scale;

    state.zoom = clamped_zoom;
    renderCurrentPage(state) catch {};

    const new_hadj = c.gtk_scrolled_window_get_hadjustment(@ptrCast(scroller)) orelse hadj;
    const new_vadj = c.gtk_scrolled_window_get_vadjustment(@ptrCast(scroller)) orelse vadj;
    const new_view_w = c.gtk_adjustment_get_page_size(new_hadj);
    const new_view_h = c.gtk_adjustment_get_page_size(new_vadj);
    const new_scale = state.fit_scale * state.zoom;
    if (new_scale > 0.000001) {
        state.pan_x = center_page_x * new_scale - new_view_w / 2.0;
        state.pan_y = center_page_y * new_scale - new_view_h / 2.0;
        applyPan(state);
        updatePanControlsVisibility(state);
    }

    savePersistedState(state);
}

fn panBy(state: *AppState, dx: f64, dy: f64) void {
    const old_x = state.pan_x;
    const old_y = state.pan_y;
    state.pan_x += dx;
    state.pan_y += dy;
    applyPan(state);
    const moved_x = @abs(state.pan_x - old_x);
    const moved_y = @abs(state.pan_y - old_y);
    if ((@abs(dx) > 0.0001 or @abs(dy) > 0.0001) and moved_x <= 0.0001 and moved_y <= 0.0001) {
        notifyBlockedAction(state, "Edge reached");
    }
    updatePanControlsVisibility(state);
    savePersistedState(state);
}

fn panByFraction(state: *AppState, fx: f64, fy: f64) void {
    const scroller = state.scroller orelse return;
    const view_w = c.gtk_widget_get_width(scroller);
    const view_h = c.gtk_widget_get_height(scroller);
    if (view_w <= 0 or view_h <= 0) return;

    const dx = @as(f64, @floatFromInt(view_w)) * fx;
    const dy = @as(f64, @floatFromInt(view_h)) * fy;
    panBy(state, dx, dy);
}

fn showOpenFileDialog(state: *AppState) void {
    const window = state.window orelse return;
    const native = c.gtk_file_chooser_native_new(
        "Open PDF",
        @ptrCast(window),
        c.GTK_FILE_CHOOSER_ACTION_OPEN,
        "Open",
        "Cancel",
    );
    _ = c.g_signal_connect_data(
        native,
        "response",
        @ptrCast(&onOpenFileDialogResponse),
        state,
        null,
        0,
    );
    c.gtk_native_dialog_show(@ptrCast(@alignCast(native)));
}

fn showErrorDialog(state: *AppState, msg: []const u8) void {
    const window = state.window orelse return;
    const z_msg = state.allocator.dupeZ(u8, msg) catch return;
    defer state.allocator.free(z_msg);

    const dialog = c.gtk_message_dialog_new(
        @ptrCast(window),
        c.GTK_DIALOG_MODAL,
        c.GTK_MESSAGE_ERROR,
        c.GTK_BUTTONS_CLOSE,
        "%s",
        z_msg.ptr,
    );
    _ = c.g_signal_connect_data(
        dialog,
        "response",
        @ptrCast(&onErrorDialogResponse),
        null,
        null,
        0,
    );
    c.gtk_widget_show(dialog);
}

fn toggleFullscreen(state: *AppState) void {
    if (state.window) |window| {
        if (c.gtk_window_is_fullscreen(@ptrCast(window)) != 0) {
            c.gtk_window_unfullscreen(@ptrCast(window));
        } else {
            c.gtk_window_fullscreen(@ptrCast(window));
        }
    }
}

fn buildUi(state: *AppState, app: *c.GtkApplication) void {
    state.window = @ptrCast(c.gtk_application_window_new(app));
    const window = state.window.?;
    c.gtk_window_set_default_size(@ptrCast(window), 900, 700);
    c.gtk_window_set_title(@ptrCast(window), "muon-pdf");

    const overlay = c.gtk_overlay_new();
    state.overlay = overlay;
    c.gtk_window_set_child(@ptrCast(window), overlay);

    const css_provider = c.gtk_css_provider_new();
    defer c.g_object_unref(css_provider);
    _ = c.gtk_css_provider_load_from_string(
        @ptrCast(css_provider),
        \\.overlay-control { opacity: 0.3; transition: opacity 180ms ease-in-out; }
        \\.overlay-control:not(.edge-disabled):hover,
        \\.overlay-control:not(.edge-disabled):active,
        \\.overlay-control.controls-active { opacity: 1.0; }
        \\.feedback-toast { opacity: 0.0; transition: opacity 220ms ease-in-out; background: alpha(@theme_bg_color, 0.85); border-radius: 8px; padding: 6px 10px; }
        \\.feedback-toast.feedback-active { opacity: 1.0; }
        \\.direction-button { min-width: 36px; min-height: 36px; padding: 0; }
        \\.arrow-left { transform: rotate(0deg); }
        \\.arrow-up { transform: rotate(90deg); }
        \\.arrow-down { transform: rotate(270deg); }
        \\.arrow-right { transform: rotate(180deg); }
        ,
    );
    const display = c.gdk_display_get_default();
    if (display != null) {
        c.gtk_style_context_add_provider_for_display(
            display,
            @ptrCast(css_provider),
            c.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
    }

    state.scroller = c.gtk_scrolled_window_new();
    c.gtk_widget_set_hexpand(state.scroller, 1);
    c.gtk_widget_set_vexpand(state.scroller, 1);
    c.gtk_overlay_set_child(@ptrCast(overlay), state.scroller);

    state.picture = c.gtk_picture_new();
    c.gtk_picture_set_can_shrink(@ptrCast(state.picture), 0);
    c.gtk_widget_set_halign(state.picture, c.GTK_ALIGN_CENTER);
    c.gtk_widget_set_valign(state.picture, c.GTK_ALIGN_CENTER);
    c.gtk_scrolled_window_set_child(@ptrCast(state.scroller), state.picture);

    const feedback_label = c.gtk_label_new("");
    state.feedback_label = feedback_label;
    c.gtk_widget_set_halign(feedback_label, c.GTK_ALIGN_CENTER);
    c.gtk_widget_set_valign(feedback_label, c.GTK_ALIGN_END);
    c.gtk_widget_set_margin_bottom(feedback_label, 18);
    c.gtk_widget_set_visible(feedback_label, 0);
    c.gtk_widget_add_css_class(feedback_label, "feedback-toast");
    c.gtk_overlay_add_overlay(@ptrCast(overlay), feedback_label);

    const page_indicator_label = c.gtk_label_new("0/0");
    state.page_indicator_label = page_indicator_label;
    c.gtk_widget_set_halign(page_indicator_label, c.GTK_ALIGN_START);
    c.gtk_widget_set_valign(page_indicator_label, c.GTK_ALIGN_END);
    c.gtk_widget_set_margin_start(page_indicator_label, 12);
    c.gtk_widget_set_margin_bottom(page_indicator_label, 12);
    c.gtk_widget_add_css_class(page_indicator_label, "feedback-toast");
    c.gtk_widget_add_css_class(page_indicator_label, "feedback-active");
    c.gtk_overlay_add_overlay(@ptrCast(overlay), page_indicator_label);

    const open_menu_btn = c.gtk_menu_button_new();
    state.open_btn = open_menu_btn;
    c.gtk_widget_set_focusable(open_menu_btn, 0);
    c.gtk_menu_button_set_icon_name(@ptrCast(open_menu_btn), "open-menu-symbolic");
    c.gtk_widget_add_css_class(open_menu_btn, "overlay-control");
    c.gtk_widget_set_halign(open_menu_btn, c.GTK_ALIGN_START);
    c.gtk_widget_set_valign(open_menu_btn, c.GTK_ALIGN_START);
    c.gtk_widget_set_margin_start(open_menu_btn, 10);
    c.gtk_widget_set_margin_top(open_menu_btn, 10);
    c.gtk_overlay_add_overlay(@ptrCast(overlay), open_menu_btn);

    const menu_popover = c.gtk_popover_new();
    const menu_box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2);
    c.gtk_popover_set_child(@ptrCast(menu_popover), menu_box);
    const menu_open_item = c.gtk_button_new_with_label("Open");
    const menu_fullscreen_item = c.gtk_button_new_with_label("Fullscreen");
    const menu_rotate_item = c.gtk_button_new_with_label("Rotate");
    const menu_hide_ui_item = c.gtk_check_button_new_with_label("Hide UI");
    const menu_quit_item = c.gtk_button_new_with_label("Quit");
    state.menu_fullscreen_item = menu_fullscreen_item;
    state.menu_rotate_item = menu_rotate_item;
    state.menu_hide_ui_item = menu_hide_ui_item;
    c.gtk_widget_set_focusable(menu_open_item, 0);
    c.gtk_widget_set_focusable(menu_fullscreen_item, 0);
    c.gtk_widget_set_focusable(menu_rotate_item, 0);
    c.gtk_widget_set_focusable(menu_hide_ui_item, 0);
    c.gtk_widget_set_focusable(menu_quit_item, 0);
    c.gtk_box_append(@ptrCast(menu_box), menu_open_item);
    c.gtk_box_append(@ptrCast(menu_box), menu_fullscreen_item);
    c.gtk_box_append(@ptrCast(menu_box), menu_rotate_item);
    c.gtk_box_append(@ptrCast(menu_box), menu_hide_ui_item);
    c.gtk_box_append(@ptrCast(menu_box), menu_quit_item);
    c.gtk_menu_button_set_popover(@ptrCast(open_menu_btn), menu_popover);

    const zoom_box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
    c.gtk_widget_set_halign(zoom_box, c.GTK_ALIGN_END);
    c.gtk_widget_set_valign(zoom_box, c.GTK_ALIGN_START);
    c.gtk_widget_set_margin_end(zoom_box, 10);
    c.gtk_widget_set_margin_top(zoom_box, 10);
    c.gtk_overlay_add_overlay(@ptrCast(overlay), zoom_box);

    const zoom_out_btn = c.gtk_button_new_with_label("-");
    const zoom_in_btn = c.gtk_button_new_with_label("+");
    c.gtk_widget_set_focusable(zoom_out_btn, 0);
    c.gtk_widget_set_focusable(zoom_in_btn, 0);
    state.zoom_out_btn = zoom_out_btn;
    state.zoom_in_btn = zoom_in_btn;
    c.gtk_widget_add_css_class(zoom_out_btn, "overlay-control");
    c.gtk_widget_add_css_class(zoom_in_btn, "overlay-control");
    c.gtk_box_append(@ptrCast(zoom_box), zoom_out_btn);
    c.gtk_box_append(@ptrCast(zoom_box), zoom_in_btn);

    const arrows_grid = c.gtk_grid_new();
    state.pan_controls = arrows_grid;
    c.gtk_grid_set_row_spacing(@ptrCast(arrows_grid), 4);
    c.gtk_grid_set_column_spacing(@ptrCast(arrows_grid), 4);
    c.gtk_widget_set_halign(arrows_grid, c.GTK_ALIGN_END);
    c.gtk_widget_set_valign(arrows_grid, c.GTK_ALIGN_END);
    c.gtk_widget_set_margin_end(arrows_grid, 10);
    c.gtk_widget_set_margin_bottom(arrows_grid, 10);
    c.gtk_overlay_add_overlay(@ptrCast(overlay), arrows_grid);

    const up_btn = c.gtk_button_new_with_label("<");
    const down_btn = c.gtk_button_new_with_label("<");
    const left_btn = c.gtk_button_new_with_label("<");
    const right_btn = c.gtk_button_new_with_label("<");
    c.gtk_widget_set_focusable(up_btn, 0);
    c.gtk_widget_set_focusable(down_btn, 0);
    c.gtk_widget_set_focusable(left_btn, 0);
    c.gtk_widget_set_focusable(right_btn, 0);
    state.pan_up_btn = up_btn;
    state.pan_down_btn = down_btn;
    state.pan_left_btn = left_btn;
    state.pan_right_btn = right_btn;
    c.gtk_widget_set_size_request(up_btn, 36, 36);
    c.gtk_widget_set_size_request(down_btn, 36, 36);
    c.gtk_widget_set_size_request(left_btn, 36, 36);
    c.gtk_widget_set_size_request(right_btn, 36, 36);
    c.gtk_widget_add_css_class(up_btn, "overlay-control");
    c.gtk_widget_add_css_class(down_btn, "overlay-control");
    c.gtk_widget_add_css_class(left_btn, "overlay-control");
    c.gtk_widget_add_css_class(right_btn, "overlay-control");
    c.gtk_widget_add_css_class(up_btn, "direction-button");
    c.gtk_widget_add_css_class(down_btn, "direction-button");
    c.gtk_widget_add_css_class(left_btn, "direction-button");
    c.gtk_widget_add_css_class(right_btn, "direction-button");
    c.gtk_widget_add_css_class(up_btn, "arrow-up");
    c.gtk_widget_add_css_class(down_btn, "arrow-down");
    c.gtk_widget_add_css_class(left_btn, "arrow-left");
    c.gtk_widget_add_css_class(right_btn, "arrow-right");
    c.gtk_grid_attach(@ptrCast(arrows_grid), up_btn, 1, 0, 1, 1);
    c.gtk_grid_attach(@ptrCast(arrows_grid), left_btn, 0, 1, 1, 1);
    c.gtk_grid_attach(@ptrCast(arrows_grid), down_btn, 1, 1, 1, 1);
    c.gtk_grid_attach(@ptrCast(arrows_grid), right_btn, 2, 1, 1, 1);

    const click = c.gtk_gesture_click_new();
    c.gtk_widget_add_controller(state.scroller, @ptrCast(click));
    _ = c.g_signal_connect_data(click, "pressed", @ptrCast(&onPressed), state, null, 0);

    const swipe_drag = c.gtk_gesture_drag_new();
    c.gtk_gesture_single_set_touch_only(@ptrCast(swipe_drag), 1);
    c.gtk_event_controller_set_propagation_phase(@ptrCast(swipe_drag), c.GTK_PHASE_CAPTURE);
    c.gtk_widget_add_controller(window, @ptrCast(swipe_drag));
    _ = c.g_signal_connect_data(swipe_drag, "drag-update", @ptrCast(&onSwipeDragUpdate), state, null, 0);
    _ = c.g_signal_connect_data(swipe_drag, "drag-end", @ptrCast(&onSwipeDragEnd), state, null, 0);

    const key_controller = c.gtk_event_controller_key_new();
    c.gtk_event_controller_set_propagation_phase(@ptrCast(key_controller), c.GTK_PHASE_CAPTURE);
    c.gtk_widget_add_controller(window, @ptrCast(key_controller));
    _ = c.g_signal_connect_data(
        key_controller,
        "key-pressed",
        @ptrCast(&onKeyPressed),
        state,
        null,
        0,
    );

    _ = c.g_signal_connect_data(menu_open_item, "clicked", @ptrCast(&onMenuOpenClicked), state, null, 0);
    _ = c.g_signal_connect_data(menu_fullscreen_item, "clicked", @ptrCast(&onMenuFullscreenClicked), state, null, 0);
    _ = c.g_signal_connect_data(menu_rotate_item, "clicked", @ptrCast(&onMenuRotateClicked), state, null, 0);
    _ = c.g_signal_connect_data(menu_hide_ui_item, "toggled", @ptrCast(&onMenuHideUiToggled), state, null, 0);
    _ = c.g_signal_connect_data(menu_quit_item, "clicked", @ptrCast(&onMenuQuitClicked), state, null, 0);
    _ = c.g_signal_connect_data(zoom_in_btn, "clicked", @ptrCast(&onZoomInClicked), state, null, 0);
    _ = c.g_signal_connect_data(zoom_out_btn, "clicked", @ptrCast(&onZoomOutClicked), state, null, 0);
    _ = c.g_signal_connect_data(up_btn, "clicked", @ptrCast(&onPanUpClicked), state, null, 0);
    _ = c.g_signal_connect_data(down_btn, "clicked", @ptrCast(&onPanDownClicked), state, null, 0);
    _ = c.g_signal_connect_data(left_btn, "clicked", @ptrCast(&onPanLeftClicked), state, null, 0);
    _ = c.g_signal_connect_data(right_btn, "clicked", @ptrCast(&onPanRightClicked), state, null, 0);

    if (c.gtk_scrolled_window_get_hadjustment(@ptrCast(state.scroller))) |hadj| {
        _ = c.g_signal_connect_data(hadj, "changed", @ptrCast(&onAdjustmentChanged), state, null, 0);
        _ = c.g_signal_connect_data(hadj, "value-changed", @ptrCast(&onAdjustmentChanged), state, null, 0);
    }
    if (c.gtk_scrolled_window_get_vadjustment(@ptrCast(state.scroller))) |vadj| {
        _ = c.g_signal_connect_data(vadj, "changed", @ptrCast(&onAdjustmentChanged), state, null, 0);
        _ = c.g_signal_connect_data(vadj, "value-changed", @ptrCast(&onAdjustmentChanged), state, null, 0);
    }

    _ = c.g_signal_connect_data(state.scroller, "notify::width", @ptrCast(&onSizeNotify), state, null, 0);
    _ = c.g_signal_connect_data(state.scroller, "notify::height", @ptrCast(&onSizeNotify), state, null, 0);
    _ = c.g_signal_connect_data(window, "notify::width", @ptrCast(&onSizeNotify), state, null, 0);
    _ = c.g_signal_connect_data(window, "notify::height", @ptrCast(&onSizeNotify), state, null, 0);
    _ = c.g_signal_connect_data(window, "close-request", @ptrCast(&onCloseRequest), state, null, 0);
    _ = c.g_timeout_add(350, @ptrCast(&onViewportPoll), state);

    updatePanControlsVisibility(state);
    c.gtk_window_present(@ptrCast(window));
}

fn onActivate(app: ?*c.GtkApplication, user_data: ?*anyopaque) callconv(.c) void {
    if (app == null or user_data == null) return;
    const state: *AppState = @ptrCast(@alignCast(user_data.?));
    buildUi(state, app.?);

    if (state.open_on_activate) |path| {
        openDocumentAtPath(state, path) catch |err| {
            var msg_buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "Failed to open file: {s}", .{@errorName(err)}) catch "Failed to open file";
            showErrorDialog(state, msg);
        };
    }
}

fn onResize(_: ?*c.GtkWidget, _: c.gint, _: c.gint, user_data: ?*anyopaque) callconv(.c) void {
    if (user_data == null) return;
    const state: *AppState = @ptrCast(@alignCast(user_data.?));
    if (state.mupdf_doc == null) return;
    renderCurrentPage(state) catch {};
}

fn onSizeNotify(_: ?*c.GObject, _: ?*c.GParamSpec, user_data: ?*anyopaque) callconv(.c) void {
    if (user_data == null) return;
    const state: *AppState = @ptrCast(@alignCast(user_data.?));
    refreshIfViewportChanged(state);
}

fn onRenderIdle(user_data: ?*anyopaque) callconv(.c) c.gboolean {
    if (user_data == null) return 0;
    const state: *AppState = @ptrCast(@alignCast(user_data.?));
    queueRender(state);
    return 0;
}

fn onViewportPoll(user_data: ?*anyopaque) callconv(.c) c.gboolean {
    if (user_data == null) return 0;
    const state: *AppState = @ptrCast(@alignCast(user_data.?));
    refreshIfViewportChanged(state);
    return 1;
}

fn onCloseRequest(_: ?*c.GtkWidget, user_data: ?*anyopaque) callconv(.c) c.gboolean {
    if (user_data != null) {
        const state: *AppState = @ptrCast(@alignCast(user_data.?));
        savePersistedState(state);
    }
    return 0;
}

fn onMenuOpenClicked(_: ?*c.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    if (user_data == null) return;
    const state: *AppState = @ptrCast(@alignCast(user_data.?));
    activateButtonWithTimeout(state, state.open_btn, &state.open_btn_timeout_id, onOpenButtonFadeTimeout);
    if (state.open_btn) |menu_btn| c.gtk_menu_button_popdown(@ptrCast(menu_btn));
    showOpenFileDialog(state);
}

fn onMenuFullscreenClicked(_: ?*c.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    if (user_data == null) return;
    const state: *AppState = @ptrCast(@alignCast(user_data.?));
    activateButtonWithTimeout(state, state.open_btn, &state.open_btn_timeout_id, onOpenButtonFadeTimeout);
    if (state.open_btn) |menu_btn| c.gtk_menu_button_popdown(@ptrCast(menu_btn));
    toggleFullscreen(state);
}

fn onMenuRotateClicked(_: ?*c.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    if (user_data == null) return;
    const state: *AppState = @ptrCast(@alignCast(user_data.?));
    activateButtonWithTimeout(state, state.open_btn, &state.open_btn_timeout_id, onOpenButtonFadeTimeout);
    if (state.open_btn) |menu_btn| c.gtk_menu_button_popdown(@ptrCast(menu_btn));
    rotateClockwise(state);
}

fn onMenuHideUiToggled(btn: ?*c.GtkCheckButton, user_data: ?*anyopaque) callconv(.c) void {
    if (btn == null or user_data == null) return;
    const state: *AppState = @ptrCast(@alignCast(user_data.?));
    state.ui_hidden = c.gtk_check_button_get_active(btn.?) != 0;
    updatePanControlsVisibility(state);
}

fn onMenuQuitClicked(_: ?*c.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    if (user_data == null) return;
    const state: *AppState = @ptrCast(@alignCast(user_data.?));
    if (state.open_btn) |menu_btn| c.gtk_menu_button_popdown(@ptrCast(menu_btn));
    if (state.gtk_app) |app| c.g_application_quit(@ptrCast(app));
}

fn onZoomInClicked(btn: ?*c.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    if (user_data == null) return;
    const state: *AppState = @ptrCast(@alignCast(user_data.?));
    activateButtonWithTimeout(state, if (btn) |b| @ptrCast(b) else null, &state.zoom_in_btn_timeout_id, onZoomInButtonFadeTimeout);
    zoomIn(state);
}

fn onZoomOutClicked(btn: ?*c.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    if (user_data == null) return;
    const state: *AppState = @ptrCast(@alignCast(user_data.?));
    activateButtonWithTimeout(state, if (btn) |b| @ptrCast(b) else null, &state.zoom_out_btn_timeout_id, onZoomOutButtonFadeTimeout);
    zoomOut(state);
}

fn onPanUpClicked(btn: ?*c.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    if (user_data == null) return;
    const state: *AppState = @ptrCast(@alignCast(user_data.?));
    activateButtonWithTimeout(state, if (btn) |b| @ptrCast(b) else null, &state.pan_up_btn_timeout_id, onPanUpButtonFadeTimeout);
    panByFraction(state, 0, -0.02);
}

fn onPanDownClicked(btn: ?*c.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    if (user_data == null) return;
    const state: *AppState = @ptrCast(@alignCast(user_data.?));
    activateButtonWithTimeout(state, if (btn) |b| @ptrCast(b) else null, &state.pan_down_btn_timeout_id, onPanDownButtonFadeTimeout);
    panByFraction(state, 0, 0.02);
}

fn onPanLeftClicked(btn: ?*c.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    if (user_data == null) return;
    const state: *AppState = @ptrCast(@alignCast(user_data.?));
    activateButtonWithTimeout(state, if (btn) |b| @ptrCast(b) else null, &state.pan_left_btn_timeout_id, onPanLeftButtonFadeTimeout);
    panByFraction(state, -0.02, 0);
}

fn onPanRightClicked(btn: ?*c.GtkButton, user_data: ?*anyopaque) callconv(.c) void {
    if (user_data == null) return;
    const state: *AppState = @ptrCast(@alignCast(user_data.?));
    activateButtonWithTimeout(state, if (btn) |b| @ptrCast(b) else null, &state.pan_right_btn_timeout_id, onPanRightButtonFadeTimeout);
    panByFraction(state, 0.02, 0);
}

fn isTapInControlSafeZone(state: *AppState, x: f64, y: f64, view_w: f64, view_h: f64) bool {
    _ = state;
    const zone_w = view_w * 0.20;
    const zone_h = view_h * 0.20;

    const in_top_left = x <= zone_w and y <= zone_h;
    const in_top_right = x >= (view_w - zone_w) and y <= zone_h;
    const in_bottom_left = x <= zone_w and y >= (view_h - zone_h);
    const in_bottom_right = x >= (view_w - zone_w) and y >= (view_h - zone_h);

    return in_top_left or in_top_right or in_bottom_left or in_bottom_right;
}

fn onPressed(gesture: ?*c.GtkGestureClick, n_press: c.gint, x: c.gdouble, y: c.gdouble, user_data: ?*anyopaque) callconv(.c) void {
    if (gesture == null or user_data == null) return;
    const state: *AppState = @ptrCast(@alignCast(user_data.?));
    const now = nowMs();
    if (now < state.suppress_tap_until_ms) {
        return;
    }
    const widget = c.gtk_event_controller_get_widget(@ptrCast(gesture.?));
    if (widget == null) return;

    const width = c.gtk_widget_get_width(widget);
    const height = c.gtk_widget_get_height(widget);
    const xf: f64 = x;
    const yf: f64 = y;
    const wf: f64 = @floatFromInt(width);
    const hf: f64 = @floatFromInt(height);

    if (isTapInControlSafeZone(state, xf, yf, wf, hf)) return;

    if (n_press >= 2) {
        const in_center_zone = xf > wf * 0.40 and xf < wf * 0.60;
        if (in_center_zone) {
            toggleFullscreen(state);
            return;
        }
    }

    if (xf <= wf * 0.40) {
        pagePrev(state);
    } else if (xf >= wf * 0.60) {
        pageNext(state);
    }
}

fn onSwipe(_: ?*c.GtkGestureSwipe, vel_x: c.gdouble, vel_y: c.gdouble, user_data: ?*anyopaque) callconv(.c) void {
    if (user_data == null) return;
    const state: *AppState = @ptrCast(@alignCast(user_data.?));
    const abs_x = @abs(@as(f64, vel_x));
    const abs_y = @abs(@as(f64, vel_y));
    if (abs_x < 300 and abs_y < 300) return;

    if (abs_x >= abs_y) {
        if (vel_x < 0) {
            pageNext(state);
        } else {
            pagePrev(state);
        }
    } else {
        // Map vertical swipe to page-up/page-down semantics.
        if (vel_y < 0) {
            pageNext(state);
        } else {
            pagePrev(state);
        }
    }
}

fn onSwipeDragUpdate(gesture: ?*c.GtkGestureDrag, offset_x: c.gdouble, offset_y: c.gdouble, user_data: ?*anyopaque) callconv(.c) void {
    if (gesture == null or user_data == null) return;
    const state: *AppState = @ptrCast(@alignCast(user_data.?));
    if (state.swipe_claimed) return;

    const ax = @abs(@as(f64, offset_x));
    const ay = @abs(@as(f64, offset_y));
    // Claim early to disable touch drag-panning in GtkScrolledWindow.
    // Taps are unaffected because they do not exceed this movement threshold.
    const claim_threshold = 6.0;
    if (ax < claim_threshold and ay < claim_threshold) return;

    _ = c.gtk_gesture_set_state(@ptrCast(gesture.?), c.GTK_EVENT_SEQUENCE_CLAIMED);
    state.swipe_claimed = true;
}

fn onSwipeDragEnd(_: ?*c.GtkGestureDrag, offset_x: c.gdouble, offset_y: c.gdouble, user_data: ?*anyopaque) callconv(.c) void {
    if (user_data == null) return;
    const state: *AppState = @ptrCast(@alignCast(user_data.?));
    const claimed = state.swipe_claimed;
    state.swipe_claimed = false;
    if (!claimed) return;

    const x = @as(f64, offset_x);
    const y = @as(f64, offset_y);
    const ax = @abs(x);
    const ay = @abs(y);
    const trigger_threshold = 220.0;
    const dominance_ratio = 1.25;
    if (ax < trigger_threshold and ay < trigger_threshold) return;

    // Require a clear dominant direction to avoid accidental diagonal turns.
    if (ax >= ay * dominance_ratio) {
        if (x < 0) {
            pageNext(state);
        } else {
            pagePrev(state);
        }
        state.suppress_tap_until_ms = nowMs() + 160;
    } else if (ay >= ax * dominance_ratio) {
        // Natural vertical swipe mapping.
        if (y < 0) {
            pageNext(state);
        } else {
            pagePrev(state);
        }
        state.suppress_tap_until_ms = nowMs() + 160;
    } else {
        return;
    }
}

fn onKeyPressed(
    _: ?*c.GtkEventControllerKey,
    keyval: c.guint,
    _: c.guint,
    modifiers: c.GdkModifierType,
    user_data: ?*anyopaque,
) callconv(.c) c.gboolean {
    if (user_data == null) return 0;
    const state: *AppState = @ptrCast(@alignCast(user_data.?));

    if (keyval == c.GDK_KEY_Left or keyval == c.GDK_KEY_h or keyval == c.GDK_KEY_H) {
        panByFraction(state, -0.02, 0);
        return 1;
    }
    if (keyval == c.GDK_KEY_Right or keyval == c.GDK_KEY_l or keyval == c.GDK_KEY_L) {
        panByFraction(state, 0.02, 0);
        return 1;
    }
    if (keyval == c.GDK_KEY_Up or keyval == c.GDK_KEY_k or keyval == c.GDK_KEY_K) {
        panByFraction(state, 0, -0.02);
        return 1;
    }
    if (keyval == c.GDK_KEY_Down or keyval == c.GDK_KEY_j or keyval == c.GDK_KEY_J) {
        panByFraction(state, 0, 0.02);
        return 1;
    }
    if (keyval == c.GDK_KEY_space and (modifiers & c.GDK_SHIFT_MASK) != 0) {
        pagePrev(state);
        return 1;
    }
    if (keyval == c.GDK_KEY_space or keyval == c.GDK_KEY_greater or keyval == c.GDK_KEY_period) {
        pageNext(state);
        return 1;
    }
    if (keyval == c.GDK_KEY_less or keyval == c.GDK_KEY_comma) {
        pagePrev(state);
        return 1;
    }
    if (keyval == c.GDK_KEY_plus or keyval == c.GDK_KEY_equal or keyval == c.GDK_KEY_KP_Add) {
        zoomIn(state);
        return 1;
    }
    if (keyval == c.GDK_KEY_minus or keyval == c.GDK_KEY_underscore or keyval == c.GDK_KEY_KP_Subtract) {
        zoomOut(state);
        return 1;
    }
    if (keyval == c.GDK_KEY_q or keyval == c.GDK_KEY_Q) {
        if (state.gtk_app) |app| {
            c.g_application_quit(@ptrCast(app));
        }
        return 1;
    }
    if (keyval == c.GDK_KEY_f or keyval == c.GDK_KEY_F or keyval == c.GDK_KEY_F11) {
        toggleFullscreen(state);
        return 1;
    }
    if (keyval == c.GDK_KEY_r or keyval == c.GDK_KEY_R) {
        rotateClockwise(state);
        return 1;
    }
    return 0;
}

fn onOpenButtonFadeTimeout(user_data: ?*anyopaque) callconv(.c) c.gboolean {
    if (user_data == null) return 0;
    const state: *AppState = @ptrCast(@alignCast(user_data.?));
    state.open_btn_timeout_id = 0;
    if (state.open_btn) |btn| {
        if (state.mupdf_doc == null) {
            c.gtk_widget_add_css_class(btn, "controls-active");
        } else {
            c.gtk_widget_remove_css_class(btn, "controls-active");
        }
    }
    return 0;
}

fn onZoomInButtonFadeTimeout(user_data: ?*anyopaque) callconv(.c) c.gboolean {
    if (user_data == null) return 0;
    const state: *AppState = @ptrCast(@alignCast(user_data.?));
    state.zoom_in_btn_timeout_id = 0;
    if (state.zoom_in_btn) |btn| c.gtk_widget_remove_css_class(btn, "controls-active");
    return 0;
}

fn onZoomOutButtonFadeTimeout(user_data: ?*anyopaque) callconv(.c) c.gboolean {
    if (user_data == null) return 0;
    const state: *AppState = @ptrCast(@alignCast(user_data.?));
    state.zoom_out_btn_timeout_id = 0;
    if (state.zoom_out_btn) |btn| c.gtk_widget_remove_css_class(btn, "controls-active");
    return 0;
}

fn onPanUpButtonFadeTimeout(user_data: ?*anyopaque) callconv(.c) c.gboolean {
    if (user_data == null) return 0;
    const state: *AppState = @ptrCast(@alignCast(user_data.?));
    state.pan_up_btn_timeout_id = 0;
    if (state.pan_up_btn) |btn| c.gtk_widget_remove_css_class(btn, "controls-active");
    return 0;
}

fn onPanDownButtonFadeTimeout(user_data: ?*anyopaque) callconv(.c) c.gboolean {
    if (user_data == null) return 0;
    const state: *AppState = @ptrCast(@alignCast(user_data.?));
    state.pan_down_btn_timeout_id = 0;
    if (state.pan_down_btn) |btn| c.gtk_widget_remove_css_class(btn, "controls-active");
    return 0;
}

fn onPanLeftButtonFadeTimeout(user_data: ?*anyopaque) callconv(.c) c.gboolean {
    if (user_data == null) return 0;
    const state: *AppState = @ptrCast(@alignCast(user_data.?));
    state.pan_left_btn_timeout_id = 0;
    if (state.pan_left_btn) |btn| c.gtk_widget_remove_css_class(btn, "controls-active");
    return 0;
}

fn onPanRightButtonFadeTimeout(user_data: ?*anyopaque) callconv(.c) c.gboolean {
    if (user_data == null) return 0;
    const state: *AppState = @ptrCast(@alignCast(user_data.?));
    state.pan_right_btn_timeout_id = 0;
    if (state.pan_right_btn) |btn| c.gtk_widget_remove_css_class(btn, "controls-active");
    return 0;
}

fn onFeedbackHideTimeout(user_data: ?*anyopaque) callconv(.c) c.gboolean {
    if (user_data == null) return 0;
    const state: *AppState = @ptrCast(@alignCast(user_data.?));
    state.feedback_timeout_id = 0;
    if (state.feedback_label) |label| {
        c.gtk_widget_remove_css_class(label, "feedback-active");
        c.gtk_widget_set_opacity(label, 0.0);
    }
    return 0;
}

fn onAdjustmentChanged(_: ?*c.GtkAdjustment, user_data: ?*anyopaque) callconv(.c) void {
    if (user_data == null) return;
    const state: *AppState = @ptrCast(@alignCast(user_data.?));
    updatePanControlsVisibility(state);
}

fn onOpenFileDialogResponse(dialog: ?*c.GtkNativeDialog, response: c.gint, user_data: ?*anyopaque) callconv(.c) void {
    if (dialog == null or user_data == null) return;
    defer c.g_object_unref(dialog);

    if (response != c.GTK_RESPONSE_ACCEPT) return;
    const chooser: *c.GtkFileChooser = @ptrCast(dialog.?);
    const file = c.gtk_file_chooser_get_file(chooser);
    if (file == null) return;
    defer c.g_object_unref(file);

    const path = c.g_file_get_path(file);
    if (path == null) return;
    defer c.g_free(path);

    const state: *AppState = @ptrCast(@alignCast(user_data.?));
    const zig_path = std.mem.span(path);
    openDocumentAtPath(state, zig_path) catch |err| {
        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Failed to open file: {s}", .{@errorName(err)}) catch "Failed to open file";
        showErrorDialog(state, msg);
    };
}

fn onErrorDialogResponse(dialog: ?*c.GtkDialog, _: c.gint, _: ?*anyopaque) callconv(.c) void {
    if (dialog == null) return;
    c.gtk_window_destroy(@ptrCast(dialog.?));
}

fn freeState(state: *AppState) void {
    if (state.open_btn_timeout_id != 0) _ = c.g_source_remove(state.open_btn_timeout_id);
    if (state.zoom_out_btn_timeout_id != 0) _ = c.g_source_remove(state.zoom_out_btn_timeout_id);
    if (state.zoom_in_btn_timeout_id != 0) _ = c.g_source_remove(state.zoom_in_btn_timeout_id);
    if (state.pan_up_btn_timeout_id != 0) _ = c.g_source_remove(state.pan_up_btn_timeout_id);
    if (state.pan_down_btn_timeout_id != 0) _ = c.g_source_remove(state.pan_down_btn_timeout_id);
    if (state.pan_left_btn_timeout_id != 0) _ = c.g_source_remove(state.pan_left_btn_timeout_id);
    if (state.pan_right_btn_timeout_id != 0) _ = c.g_source_remove(state.pan_right_btn_timeout_id);
    if (state.feedback_timeout_id != 0) _ = c.g_source_remove(state.feedback_timeout_id);
    savePersistedState(state);
    maybeFree(state.allocator, &state.current_file_path);
    maybeFree(state.allocator, &state.current_cache_path);
    maybeFree(state.allocator, &state.open_on_activate);
    if (state.mupdf_doc) |doc| {
        c.fz_drop_document(state.mupdf_ctx.?, doc);
    }
    if (state.mupdf_ctx) |ctx| {
        c.fz_drop_context(ctx);
    }
}

// Zig 0.16 removed std.process.argsAlloc; command line arguments are now
// passed to main via std.process.Init.Minimal. Keep one entry point per
// compiler generation; lazy analysis means only the selected one is compiled.
const zig_has_process_init =
    builtin.zig_version.order(.{ .major = 0, .minor = 16, .patch = 0 }) != .lt;

pub const main = if (zig_has_process_init) mainZig016 else mainZig015;

fn mainZig015() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    try appMain(allocator, if (args.len > 1) args[1] else null);
}

fn mainZig016(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = init.args.iterate();
    _ = args.skip();
    try appMain(allocator, args.next());
}

fn appMain(allocator: std.mem.Allocator, open_path: ?[]const u8) !void {
    var state = AppState{ .allocator = allocator };
    defer freeState(&state);

    if (open_path) |path| {
        state.open_on_activate = try cstrDup(allocator, path);
    }

    c.g_set_prgname("muon-pdf");
    c.g_set_application_name("muon-pdf");

    const app = c.gtk_application_new("com.muonpdf", c.G_APPLICATION_FLAGS_NONE);
    if (app == null) return error.GtkInitFailed;
    defer c.g_object_unref(app);
    state.gtk_app = app;

    _ = c.g_signal_connect_data(app, "activate", @ptrCast(&onActivate), &state, null, 0);
    _ = c.g_application_run(@ptrCast(app), 0, null);
}

const rl = @import("raylib");
const std = @import("std");
const sheet = @import("spreadsheet.zig");
const input = @import("input_handler.zig");
const renderer = @import("renderer.zig");

pub fn main() !void {
    rl.initWindow(1000, 700, "Zync Spreadsheet");
    defer rl.closeWindow();
    rl.setExitKey(.null);
    rl.setTargetFPS(120);

    var codepoints: [12000]i32 = undefined;
    var cp_count: usize = 0;
    var cp_i: i32 = 32;
    while (cp_i <= 126) : (cp_i += 1) {
        codepoints[cp_count] = cp_i;
        cp_count += 1;
    }
    var cp_j: i32 = 0x1100; // 한글 자모
    while (cp_j <= 0x11FF) : (cp_j += 1) {
        codepoints[cp_count] = cp_j;
        cp_count += 1;
    }
    var cp_k: i32 = 0x3130; // 한글 호환 자모 (ㄱㄴㄷ...)
    while (cp_k <= 0x318F) : (cp_k += 1) {
        codepoints[cp_count] = cp_k;
        cp_count += 1;
    }
    var cp_l: i32 = 0xAC00; // 완성형 한글
    while (cp_l <= 0xD7A3) : (cp_l += 1) {
        codepoints[cp_count] = cp_l;
        cp_count += 1;
    }

    const font = try rl.loadFontEx("resources/Pretendard-Regular.ttf", 24, codepoints[0..cp_count]);
    defer rl.unloadFont(font);
    rl.setTextureFilter(font.texture, .bilinear);

    var grid = [_][sheet.COLS]sheet.Cell{[_]sheet.Cell{.{}} ** sheet.COLS} ** sheet.ROWS;
    var selR: i32 = 1;
    var selC: i32 = 1;
    var inState = input.InputState{};

    while (!rl.windowShouldClose()) {
        inState.update(rl.getFrameTime(), &selR, &selC, &grid);

        rl.beginDrawing();
        rl.clearBackground(rl.Color.white);

        for (0..sheet.ROWS) |r| {
            for (0..sheet.COLS) |c| {
                const x = @as(f32, @floatFromInt(c)) * sheet.CELL_W;
                const y = @as(f32, @floatFromInt(r)) * sheet.CELL_H;
                const rect = rl.Rectangle{ .x = x, .y = y, .width = sheet.CELL_W, .height = sheet.CELL_H };

                var bgColor = rl.Color.white;
                if (r == 0 or c == 0) bgColor = rl.Color.light_gray else if (@as(i32, @intCast(r)) == selR and @as(i32, @intCast(c)) == selC) {
                    bgColor = if (inState.mode == .Insert) rl.Color.orange else rl.Color.sky_blue;
                }
                rl.drawRectangleRec(rect, bgColor);
                rl.drawRectangleLinesEx(rect, 1.0, rl.Color.gray);

                if (r == 0 and c > 0) {
                    var buf: [2:0]u8 = undefined;
                    const txt = std.fmt.bufPrintZ(&buf, "{c}", .{@as(u8, @intCast(64 + c))}) catch "!";
                    renderer.drawCentered(font, txt, rect, 18, rl.Color.dark_gray);
                } else if (c == 0 and r > 0) {
                    var buf: [4:0]u8 = undefined;
                    const txt = std.fmt.bufPrintZ(&buf, "{d}", .{r}) catch "!";
                    renderer.drawCentered(font, txt, rect, 18, rl.Color.dark_gray);
                } else if (grid[r][c].len > 0) {
                    const txt_slice = std.mem.span(@as([*:0]const u8, @ptrCast(&grid[r][c].content)));
                    rl.beginScissorMode(@intFromFloat(rect.x + 1), @intFromFloat(rect.y + 1), @intFromFloat(rect.width - 2), @intFromFloat(rect.height - 2));
                    rl.drawTextEx(font, txt_slice, rl.Vector2{ .x = x + 6, .y = y + 7 }, 20, 1, rl.Color.black);
                    rl.endScissorMode();
                }
            }
        }

        const barColor = if (inState.mode == .Insert) rl.Color.red else rl.Color.blue;
        rl.drawRectangle(0, 660, 1000, 40, barColor);

        var statusBuf: [128:0]u8 = undefined;
        const modeTxt = if (inState.mode == .Insert) "INSERT" else "NORMAL";
        const langTxt = if (inState.lang == .KO) "KO" else "EN";
        const statusTxt = std.fmt.bufPrintZ(&statusBuf, "-- {s} --  [{s}]  R-ALT: 한/영", .{ modeTxt, langTxt }) catch "!";

        rl.drawTextEx(font, statusTxt, rl.Vector2{ .x = 10, .y = 670 }, 18, 1, rl.Color.white);
        rl.drawFPS(920, 670);
        rl.endDrawing();
    }
}

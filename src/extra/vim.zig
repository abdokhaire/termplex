const std = @import("std");
const Config = @import("../config/Config.zig");

/// This is the associated Vim file as named by the variable.
pub const syntax = comptimeGenSyntax();
pub const ftdetect =
    \\" Vim filetype detect file
    \\" Language: Termplex config file
    \\" Maintainer: Termplex <https://github.com/termplex-org/termplex>
    \\"
    \\" THIS FILE IS AUTO-GENERATED
    \\
    \\au BufRead,BufNewFile */termplex/config,*/*.termplex/config,*/termplex/themes/*,*.termplex setf termplex
    \\
;
pub const ftplugin =
    \\" Vim filetype plugin file
    \\" Language: Termplex config file
    \\" Maintainer: Termplex <https://github.com/termplex-org/termplex>
    \\"
    \\" THIS FILE IS AUTO-GENERATED
    \\
    \\if exists('b:did_ftplugin')
    \\  finish
    \\endif
    \\let b:did_ftplugin = 1
    \\
    \\setlocal commentstring=#\ %s
    \\setlocal iskeyword+=-
    \\
    \\" Use syntax keywords for completion
    \\setlocal omnifunc=syntaxcomplete#Complete
    \\
    \\let b:undo_ftplugin = 'setl cms< isk< ofu<'
    \\
    \\if !exists('current_compiler')
    \\  compiler termplex
    \\  let b:undo_ftplugin .= " makeprg< errorformat<"
    \\endif
    \\
;
pub const compiler =
    \\" Vim compiler file
    \\" Language: Termplex config file
    \\" Maintainer: Termplex <https://github.com/termplex-org/termplex>
    \\"
    \\" THIS FILE IS AUTO-GENERATED
    \\
    \\if exists("current_compiler")
    \\  finish
    \\endif
    \\let current_compiler = "termplex"
    \\
    \\CompilerSet makeprg=termplex\ +validate-config\ --config-file=%:S
    \\CompilerSet errorformat=%f:%l:%m,%m
    \\
;

/// Generates the syntax file at comptime.
fn comptimeGenSyntax() []const u8 {
    comptime {
        @setEvalBranchQuota(50000);
        var counter: std.Io.Writer.Discarding = .init(&.{});
        try writeSyntax(&counter.writer);

        var buf: [counter.count]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        try writeSyntax(&writer);
        const final = buf;
        return final[0..writer.end];
    }
}

/// Writes the syntax file to the given writer.
fn writeSyntax(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\" Vim syntax file
        \\" Language: Termplex config file
        \\" Maintainer: Termplex <https://github.com/termplex-org/termplex>
        \\"
        \\" THIS FILE IS AUTO-GENERATED
        \\
        \\if exists('b:current_syntax')
        \\  finish
        \\endif
        \\
        \\let b:current_syntax = 'termplex'
        \\
        \\let s:cpo_save = &cpo
        \\set cpo&vim
        \\
        \\syn iskeyword @,48-57,-
        \\syn keyword termplexConfigKeyword
    );

    const config_fields = @typeInfo(Config).@"struct".fields;
    inline for (config_fields) |field| {
        if (field.name[0] == '_') continue;
        try writer.print("\n\t\\ {s}", .{field.name});
    }

    try writer.writeAll(
        \\
        \\
        \\syn match termplexConfigComment /^\s*#.*/ contains=@Spell
        \\
        \\hi def link termplexConfigComment Comment
        \\hi def link termplexConfigKeyword Keyword
        \\
        \\let &cpo = s:cpo_save
        \\unlet s:cpo_save
        \\
    );
}

test {
    _ = syntax;
}

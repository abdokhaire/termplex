//! Build logic for Termplex. A single "build.zig" file became far too complex
//! and spaghetti, so this package extracts the build logic into smaller,
//! more manageable pieces.

pub const gtk = @import("gtk.zig");
pub const Config = @import("Config.zig");
pub const GitVersion = @import("GitVersion.zig");

// Artifacts
pub const TermplexBench = @import("TermplexBench.zig");
pub const TermplexDist = @import("TermplexDist.zig");
pub const TermplexDocs = @import("TermplexDocs.zig");
pub const TermplexExe = @import("TermplexExe.zig");
pub const TermplexFrameData = @import("TermplexFrameData.zig");
pub const TermplexLib = @import("TermplexLib.zig");
pub const TermplexLibVt = @import("TermplexLibVt.zig");
pub const TermplexResources = @import("TermplexResources.zig");
pub const TermplexI18n = @import("TermplexI18n.zig");
pub const TermplexXcodebuild = @import("TermplexXcodebuild.zig");
pub const TermplexXCFramework = @import("TermplexXCFramework.zig");
pub const TermplexWebdata = @import("TermplexWebdata.zig");
pub const TermplexZig = @import("TermplexZig.zig");
pub const HelpStrings = @import("HelpStrings.zig");
pub const SharedDeps = @import("SharedDeps.zig");
pub const UnicodeTables = @import("UnicodeTables.zig");

// Steps
pub const LibtoolStep = @import("LibtoolStep.zig");
pub const LipoStep = @import("LipoStep.zig");
pub const MetallibStep = @import("MetallibStep.zig");
pub const XCFrameworkStep = @import("XCFrameworkStep.zig");

// Helpers
pub const requireZig = @import("zig.zig").requireZig;

//! Typed runtime errors grouped by failure class.

const std = @import("std");

/// The input is not well-formed CBOR (RFC 8949 Section 3 and Appendix F).
pub const MalformedError = error{
    UnexpectedEndOfInput,
    ReservedAdditionalInfo,
    InvalidIndefiniteLength,
    UnexpectedBreak,
    InvalidIndefiniteStringChunk,
    InvalidSimpleValue,
    TrailingBytes,
};

/// The data is well-formed but not valid CBOR (RFC 8949 Section 5.3.1), or an
/// encoder was handed a value that cannot be emitted as valid CBOR.
pub const InvalidError = error{
    InvalidUtf8,
    DuplicateMapKey,
    InvalidEncodedItem,
};

/// Valid input violating core deterministic encoding when it is required
/// (RFC 8949 Section 4.2.1).
pub const NonDeterministicError = error{
    NonPreferredArgument,
    NonPreferredFloat,
    IndefiniteLengthNotAllowed,
    UnsortedMapKeys,
};

/// Valid CBOR that does not match the schema of a generated codec.
pub const SchemaError = error{
    TypeMismatch,
    IntegerOutOfRange,
    ValueMismatch,
    LengthMismatch,
    MissingMapKey,
    UnexpectedMapKey,
    ConstraintViolation,
    NoMatchingChoice,
    TagMismatch,
};

/// A configured resource limit was exceeded.
pub const LimitError = error{
    DepthLimitExceeded,
    ItemLimitExceeded,
    StringLengthLimitExceeded,
    AllocationLimitExceeded,
    WorkLimitExceeded,
};

pub const AllocationError = std.mem.Allocator.Error;

/// Encoded output did not fit or could not be written.
pub const OutputError = error{
    OutputCapacityExceeded,
    WriteFailed,
};

pub const DecodeError = MalformedError ||
    error{ InvalidUtf8, DuplicateMapKey } ||
    NonDeterministicError ||
    SchemaError ||
    LimitError ||
    AllocationError;

pub const EncodeError = OutputError ||
    AllocationError ||
    InvalidError ||
    error{InvalidSimpleValue} ||
    SchemaError;

pub const Error = DecodeError || EncodeError;

pub const ErrorKind = enum {
    malformed,
    invalid,
    nondeterministic,
    schema_mismatch,
    limit,
    allocation,
    output_capacity,
};

pub fn errorKind(err: Error) ErrorKind {
    return switch (err) {
        error.UnexpectedEndOfInput,
        error.ReservedAdditionalInfo,
        error.InvalidIndefiniteLength,
        error.UnexpectedBreak,
        error.InvalidIndefiniteStringChunk,
        error.InvalidSimpleValue,
        error.TrailingBytes,
        => .malformed,
        error.InvalidUtf8,
        error.DuplicateMapKey,
        error.InvalidEncodedItem,
        => .invalid,
        error.NonPreferredArgument,
        error.NonPreferredFloat,
        error.IndefiniteLengthNotAllowed,
        error.UnsortedMapKeys,
        => .nondeterministic,
        error.TypeMismatch,
        error.IntegerOutOfRange,
        error.ValueMismatch,
        error.LengthMismatch,
        error.MissingMapKey,
        error.UnexpectedMapKey,
        error.ConstraintViolation,
        error.NoMatchingChoice,
        error.TagMismatch,
        => .schema_mismatch,
        error.DepthLimitExceeded,
        error.ItemLimitExceeded,
        error.StringLengthLimitExceeded,
        error.AllocationLimitExceeded,
        error.WorkLimitExceeded,
        => .limit,
        error.OutOfMemory => .allocation,
        error.OutputCapacityExceeded,
        error.WriteFailed,
        => .output_capacity,
    };
}

test "every error has a class" {
    try std.testing.expectEqual(ErrorKind.malformed, errorKind(error.UnexpectedBreak));
    try std.testing.expectEqual(ErrorKind.invalid, errorKind(error.DuplicateMapKey));
    try std.testing.expectEqual(ErrorKind.nondeterministic, errorKind(error.UnsortedMapKeys));
    try std.testing.expectEqual(ErrorKind.schema_mismatch, errorKind(error.TypeMismatch));
    try std.testing.expectEqual(ErrorKind.limit, errorKind(error.WorkLimitExceeded));
    try std.testing.expectEqual(ErrorKind.allocation, errorKind(error.OutOfMemory));
    try std.testing.expectEqual(ErrorKind.output_capacity, errorKind(error.OutputCapacityExceeded));
}

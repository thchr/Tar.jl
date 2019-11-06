"""
The `Header` type is a struct representing the essential metadata for a single
record in a tar file with this definition:

    struct Header
        path :: String # path relative to the root
        type :: Symbol # type indicator (see below)
        mode :: UInt16 # mode/permissions (best viewed in octal)
        size :: Int64  # size of record data in bytes
        link :: String # target path of a symlink
    end

Types are represented with the following symbols: `file`, `hardlink`, `symlink`,
`chardev`, `blockdev`, `directory`, `fifo`, or for unknown types, the typeflag
character as a symbol. Note that [`extract`](@ref) refuses to extract records
types other than `file`, `symlink` and `directory`; [`list`](@ref) will only
list other kinds of records if called with `strict=false`.

The tar format includes various other metadata about records, including user and
group IDs, user and group names, and timestamps. The `Tar` package, by design,
completely ignores these. When creating tar files, these fields are always set
to zero/empty. When reading tar files, these fields are ignored aside from
verifying header checksums for each header record for all fields.
"""
struct Header
    path::String
    type::Symbol
    mode::UInt16
    size::Int64
    link::String
end

function Base.show(io::IO, hdr::Header)
    show(io, Header)
    print(io, "(")
    show(io, hdr.path)
    print(io, ", ")
    show(io, hdr.type)
    print(io, ", 0o", string(hdr.mode, base=8, pad=3), ", ")
    show(io, hdr.size)
    print(io, ", ")
    show(io, hdr.link)
    print(io, ")")
end

const TYPE_SYMBOLS = (
    '0'  => :file,
    '\0' => :file, # legacy encoding
    '1'  => :hardlink,
    '2'  => :symlink,
    '3'  => :chardev,
    '4'  => :blockdev,
    '5'  => :directory,
    '6'  => :fifo,
)

function to_symbolic_type(type::Char)
    for (t, s) in TYPE_SYMBOLS
        type == t && return s
    end
    isascii(type) ||
        error("invalid type flag: $(repr(type))")
    return Symbol(type)
end

function from_symbolic_type(sym::Symbol)
    for (t, s) in TYPE_SYMBOLS
        sym == s && return t
    end
    str = String(sym)
    ncodeunits(str) == 1 && isascii(str[1]) ||
        throw(ArgumentError("invalid type symbol: $(repr(sym))"))
    return str[1]
end

function check_header(hdr::Header)
    hdr.path == "." && hdr.type != :directory &&
        throw(@error("path '.' not a directory", type=hdr.type))
    hdr.type in (:file, :directory, :symlink) ||
        throw(@error("unsupported file type", path=hdr.path, type=hdr.type))
    hdr.type != :symlink && !isempty(hdr.link) &&
        throw(@error("non-link with link path", path=hdr.path, link=hdr.link))
    hdr.type == :symlink && hdr.size != 0 &&
        throw(@error("symlink with non-zero size", path=hdr.path, size=hdr.size))
    hdr.type == :directory && hdr.size != 0 &&
        throw(@error("directory with non-zero size", path=hdr.path, size=hdr.size))
    hdr.type != :directory && !isempty(hdr.path) && hdr.path[end] == '/' &&
        throw(@error("non-directory ending with '/'", path=hdr.path, type=hdr.type))
    hdr.size < 0 &&
        throw(@error("negative file size", path=hdr.path, size=hdr.size))
    # TODO: check mode
    check_paths(hdr.path, hdr.link)
end

# used by check_header and write_header
function check_paths(path::String, link::String)
    # checks for both path and link
    for (x, p) in (("path", path), ("link", link))
        !isempty(p) && p[1] == '/' &&
            error("$x is absolute: $(repr(p))")
        occursin("//", p) &&
            error("$x has conscutive slashes: $(repr(p))")
        0x0 in codeunits(p) &&
            error("$x contains NUL bytes: $(repr(p))")
    end
    # checks for path only
    isempty(path) &&
        error("path is empty")
    path != "." && occursin(r"(^|/)\.\.?(/|$)", path) &&
        error("path has '.' or '..' components: $(repr(path))")
    # checks for link only
    if !isempty(link)
        dir = dirname(path)
        fullpath = isempty(dir) ? link : "$dir/$link"
        level = count("/", fullpath) + 1
        level -= count(r"(^|/)\.(/|$)", fullpath)
        level -= count(r"(^|/)\.\.(/|$)", fullpath) * 2
        level < 0 &&
            throw(@error("link points above root", path=path, link=link))
    end
end

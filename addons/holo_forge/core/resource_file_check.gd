@tool
extends RefCounted
## Checks that a binary resource file (.res) is whole before Godot is asked to load it.
##
## Godot can crash (not just fail) while loading a binary resource file that was cut short or
## damaged, mostly a compressed one. So a file Holo Forge did not write or note itself in this
## session is looked at here first, in plain script, and only a file that passes is handed to
## ResourceLoader:
##   - an uncompressed file ("RSRC") must start and end with its "RSRC" mark;
##   - a compressed file ("RSCC") must start and end with its "RSCC" mark, its block table must
##     add up to exactly the file's size, every block must unpack to its full length, and what
##     they unpack to must end with "RSRC" (it does not start with one: "RSCC" stands for it).
## A file that fails is treated like a missing one: the caller writes it again from what it holds.

const PLAIN := "RSRC"
const PACKED := "RSCC"
const MAX_BLOCKS := 1 << 20


## True when the file at path is a whole binary resource file (see above).
static func is_whole(path: String) -> bool:
	var bytes := FileAccess.get_file_as_bytes(path)
	return bytes_are_whole(bytes)


## True when ResourceLoader may be asked to load the file at path: a text resource (.tres,
## .tscn; Godot reads those safely and reports what is wrong), or a binary one that is_whole().
## Told apart by the file's first bytes, not its name.
static func safe_to_load(path: String) -> bool:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false
	var head := file.get_buffer(4).get_string_from_ascii()
	file.close()
	return is_whole(path) if head == PLAIN or head == PACKED else true


## is_whole() for a file's bytes.
static func bytes_are_whole(bytes: PackedByteArray) -> bool:
	var size := bytes.size()
	if size < 16:
		return false
	var head := bytes.slice(0, 4).get_string_from_ascii()
	var tail := bytes.slice(size - 4).get_string_from_ascii()
	if head == PLAIN:
		return tail == PLAIN
	if head != PACKED or tail != PACKED:
		return false
	var mode := bytes.decode_u32(4)
	var block_size := bytes.decode_u32(8)
	var total := bytes.decode_u32(12)
	if mode > FileAccess.COMPRESSION_BROTLI or block_size == 0 or total < 8:
		return false
	var blocks := int(ceil(float(total) / float(block_size)))
	if blocks > MAX_BLOCKS or 16 + blocks * 4 + 4 > size:
		return false
	var at := 16 + blocks * 4
	var sizes := PackedInt64Array()
	var packed_total := 0
	for i in blocks:
		var length := bytes.decode_u32(16 + i * 4)
		if length == 0:
			return false
		sizes.append(length)
		packed_total += length
	if at + packed_total + 4 != size:
		return false
	var tail_bytes := PackedByteArray()
	for i in blocks:
		var expected := block_size if i < blocks - 1 else total - block_size * (blocks - 1)
		var unpacked := bytes.slice(at, at + sizes[i]).decompress(expected, mode)
		if unpacked.size() != expected:
			return false
		# (The end mark can straddle the last two blocks when the last one is under 4 bytes.)
		tail_bytes = (tail_bytes + unpacked).slice(-4) if unpacked.size() < 4 else unpacked.slice(unpacked.size() - 4)
		at += sizes[i]
	return tail_bytes.get_string_from_ascii() == PLAIN

@tool
extends Resource
## A stored mesh body: the triangles and face groups of a CadMesh as zstd-compressed "HFM1" bytes
## (CadMesh.to_blob), with a checksum of the uncompressed bytes.
##
## A feature keeps one under options.mesh (Insert Mesh as a mesh body, Direct Edit). A MeshBlob
## never changes once made: never write to data, make a new blob. Undo relies on that: a document
## snapshot copies feature options with Dictionary.duplicate(true), which shares Resource values,
## so every undo state holds this same instance and costs no blob memory.
##
## Small blobs stay in the scene. One whose data is larger than EMBED_LIMIT is written to a file
## of its own beside the scene (CadPart.externalize_mesh_blobs), named after its digest.
##
## const MESH_BLOB := preload("res://addons/holo_forge/core/mesh/mesh_blob.gd")

## Compressed bytes above this go to a sidecar file when the scene is saved.
const EMBED_LIMIT := 256 * 1024
const FORMAT := "HFM1"
## On a stand-in for a stored mesh whose file is gone: that file's path (missing()).
const MISSING_META := "holo_forge_missing_file"

@export var format := "HFM1"
## SHA-256 (hex) of the uncompressed HFM1 bytes.
@export var digest := ""
## The uncompressed byte count.
@export var size := 0
@export var vertices := 0
@export var triangles := 0
## The HFM1 bytes, zstd-compressed.
@export var data := PackedByteArray()

## Why the last to_mesh() gave null ("" when it worked): a short reason for a sentence, such as
## "checksum mismatch".
var last_error := ""
## What check() found for this instance: null until it ran, then "" (sound) or the problem.
var _checked: Variant = null


## A blob of a CadMesh, or null when there is no mesh (or it holds no triangles).
static func from_mesh(mesh: RefCounted) -> Resource:
	if mesh == null or not mesh.has_method("to_blob") or mesh.is_null():
		return null
	var raw: PackedByteArray = mesh.to_blob()
	if raw.is_empty():
		return null
	var blob: Resource = new()
	blob.format = FORMAT
	blob.digest = sha256_hex(raw)
	blob.size = raw.size()
	blob.vertices = int(mesh.vertex_count())
	blob.triangles = int(mesh.triangle_count())
	blob.data = raw.compress(FileAccess.COMPRESSION_ZSTD)
	# (Made from a mesh just now: there is nothing to check it against.)
	blob._checked = ""
	return blob


## A stand-in for a stored mesh whose file beside the scene is missing: no triangles, only the
## file's path. A scene saved with it still points at that file, so putting the file back works
## (without it the save would write "nothing" where the mesh was, and the link would be lost).
## It is never written to a file itself, and a feature that holds one is an error (core/regen.gd).
static func missing(file: String) -> Resource:
	var blob: Resource = new()
	blob.set_meta(MISSING_META, file)
	blob.set_path_cache(file)
	blob._checked = "its file is missing"
	return blob


## The file a stand-in stands for ("" for a real stored mesh).
func missing_file() -> String:
	return str(get_meta(MISSING_META, ""))


## A new CadMesh of the stored triangles, or null with last_error set. The checksum is checked
## before the bytes are decoded, so a damaged file never becomes a body.
func to_mesh() -> RefCounted:
	last_error = ""
	if not ClassDB.class_exists("CadMesh"):
		last_error = "the mesh kernel is not loaded"
		return null
	if format != FORMAT:
		last_error = "unknown format '%s'" % format
		return null
	if data.is_empty() or size <= 0:
		last_error = "it is empty"
		return null
	var raw := data.decompress(size, FileAccess.COMPRESSION_ZSTD)
	if raw.size() != size:
		last_error = "it could not be unpacked"
		return null
	if sha256_hex(raw) != digest:
		last_error = "checksum mismatch"
		return null
	var mesh: RefCounted = ClassDB.instantiate("CadMesh")
	if not mesh.from_blob(raw):
		last_error = str(mesh.get_last_error())
		if last_error == "":
			last_error = "it could not be read"
		return null
	return mesh


## "" when the stored bytes unpack to what the digest says, else the problem in a few words
## ("checksum mismatch", "it could not be unpacked", ...). Worked out once for an instance (a blob
## never changes), so it costs nothing to ask on every rebuild and every save. A blob made in this
## session by from_mesh() is sound by construction; one loaded from a scene or a file is checked
## the first time it is asked.
func check() -> String:
	if _checked == null:
		_checked = _problem()
	return str(_checked)


func _problem() -> String:
	if format != FORMAT:
		return "unknown format '%s'" % format
	if data.is_empty() or size <= 0:
		return "it is empty"
	var raw := data.decompress(size, FileAccess.COMPRESSION_ZSTD)
	if raw.size() != size:
		return "it could not be unpacked"
	if sha256_hex(raw) != digest:
		return "checksum mismatch"
	return ""


## True when the blob is too big to stay inside a scene file.
func is_large() -> bool:
	return data.size() > EMBED_LIMIT


## The first 16 characters of the digest (sidecar file names use it).
func short_digest() -> String:
	return digest.substr(0, 16)


static func sha256_hex(bytes: PackedByteArray) -> String:
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	if not bytes.is_empty():
		hashing.update(bytes)
	return hashing.finish().hex_encode()

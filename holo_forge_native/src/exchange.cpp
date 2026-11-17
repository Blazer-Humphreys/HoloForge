#include "exchange.h"

#include <algorithm>
#include <fstream>
#include <string>

#include <godot_cpp/classes/project_settings.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <BRepBuilderAPI_MakeShapeOnMesh.hxx>
#include <BRep_Tool.hxx>
#include <BRepBuilderAPI_MakeSolid.hxx>
#include <BRepBuilderAPI_Sewing.hxx>
#include <BRepBuilderAPI_Transform.hxx>
#include <BRepCheck_Analyzer.hxx>
#include <BRepGProp.hxx>
#include <BRepLib.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRepTools.hxx>
#include <BRep_Builder.hxx>
#include <GProp_GProps.hxx>
#include <IGESControl_Controller.hxx>
#include <IGESControl_Reader.hxx>
#include <IGESControl_Writer.hxx>
#include <OSD_OpenFile.hxx>
#include <Poly_Triangulation.hxx>
#include <RWStl.hxx>
#include <STEPControl_Reader.hxx>
#include <STEPControl_Writer.hxx>
#include <ShapeAnalysis_FreeBounds.hxx>
#include <Standard_Failure.hxx>
#include <StlAPI_Writer.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Compound.hxx>
#include <TopoDS_Shell.hxx>
#include <TopTools_IndexedMapOfShape.hxx>
#include <TopExp.hxx>
#include <gp_Trsf.hxx>

#include "measure.h"
#include "solid_ops.h"

using namespace godot;

namespace holo_forge::exchange
{
namespace
{
constexpr double MM_PER_M = 1000.0;
/// Meshes with more triangles than this are refused (each triangle becomes a face).
constexpr int MAX_TRIANGLES = 60000;

std::string extension_of(const String& path)
{
    std::string ext = path.get_extension().to_lower().utf8().get_data();
    return ext;
}

std::string local_path(const String& path)
{
    String os_path = path;
    if (path.begins_with("res://") || path.begins_with("user://")) {
        os_path = ProjectSettings::get_singleton()->globalize_path(path);
    }
    return os_path.utf8().get_data();
}

TopoDS_Shape scaled(const TopoDS_Shape& shape, double factor)
{
    gp_Trsf scale;
    scale.SetScale(gp_Pnt(0.0, 0.0, 0.0), factor);
    return BRepBuilderAPI_Transform(shape, scale, true).Shape();
}

/// A closed shell becomes a solid (outward oriented); anything else is returned as it is.
TopoDS_Shape solidify(const TopoDS_Shape& shape)
{
    TopoDS_Shell shell;
    int shells = 0;
    for (TopExp_Explorer it(shape, TopAbs_SHELL); it.More(); it.Next()) {
        shell = TopoDS::Shell(it.Current());
        ++shells;
    }
    if (shells != 1 || !BRep_Tool::IsClosed(shell)) {
        return shape;
    }
    BRepBuilderAPI_MakeSolid maker(shell);
    if (!maker.IsDone()) {
        return shape;
    }
    TopoDS_Solid solid = maker.Solid();
    BRepLib::OrientClosedSolid(solid);
    return solid;
}

Shape mesh_shape(const Handle(Poly_Triangulation) & mesh, double scale, const std::string& tag, String& error)
{
    if (mesh.IsNull() || mesh->NbTriangles() == 0) {
        error = "The mesh has no triangles";
        return Shape();
    }
    if (mesh->NbTriangles() > MAX_TRIANGLES) {
        error = vformat("The mesh has %d triangles; Holo Forge takes up to %d (reduce it first)", mesh->NbTriangles(), MAX_TRIANGLES);
        return Shape();
    }
    BRepBuilderAPI_MakeShapeOnMesh maker(mesh);
    maker.Build();
    if (!maker.IsDone()) {
        error = "The mesh could not be turned into faces";
        return Shape();
    }
    // Shared nodes give one shell; when it isn't closed, sewing closes hairline gaps the file had.
    TopoDS_Shape shape = solidify(maker.Shape());
    if (shape.ShapeType() != TopAbs_SOLID) {
        BRepBuilderAPI_Sewing sewing(scale == 1.0 ? 1e-7 : 1e-4);
        sewing.Add(maker.Shape());
        sewing.Perform();
        shape = solidify(sewing.SewedShape());
    }
    if (scale != 1.0) {
        shape = scaled(shape, scale);
    }
    return ops::named(shape, tag);
}
}  // namespace

Shape import_file(const String& path, const std::string& tag, String& error)
{
    const std::string ext = extension_of(path);
    const std::string file = local_path(path);
    try {
        TopoDS_Shape shape;
        if (ext == "step" || ext == "stp") {
            STEPControl_Reader reader;
            if (reader.ReadFile(file.c_str()) != IFSelect_RetDone) {
                error = "The STEP file could not be read";
                return Shape();
            }
            reader.TransferRoots();
            shape = reader.OneShape();
            shape = scaled(shape, 1.0 / MM_PER_M);
        }
        else if (ext == "iges" || ext == "igs") {
            IGESControl_Controller::Init();
            IGESControl_Reader reader;
            if (reader.ReadFile(file.c_str()) != IFSelect_RetDone) {
                error = "The IGES file could not be read";
                return Shape();
            }
            reader.TransferRoots();
            shape = reader.OneShape();
            shape = scaled(shape, 1.0 / MM_PER_M);
        }
        else if (ext == "brep") {
            BRep_Builder builder;
            if (!BRepTools::Read(shape, file.c_str(), builder)) {
                error = "The BREP file could not be read";
                return Shape();
            }
        }
        else if (ext == "stl") {
            Handle(Poly_Triangulation) mesh = RWStl::ReadFile(file.c_str());
            return mesh_shape(mesh, 1.0 / MM_PER_M, tag, error);
        }
        else {
            error = "Holo Forge reads STEP, IGES, BREP and STL files";
            return Shape();
        }
        if (shape.IsNull()) {
            error = "The file holds no shapes";
            return Shape();
        }
        return ops::named(shape, tag);
    }
    catch (const Standard_Failure& failure) {
        error = String("Import failed: ") + failure.GetMessageString();
        return Shape();
    }
}

bool export_file(const Array& shapes, const String& path, String& error)
{
    BRep_Builder builder;
    TopoDS_Compound compound;
    builder.MakeCompound(compound);
    int count = 0;
    for (int64_t i = 0; i < shapes.size(); ++i) {
        Ref<CadShape> s = shapes[i];
        if (s.is_valid() && !s->get_occ_shape().IsNull()) {
            builder.Add(compound, s->get_occ_shape());
            ++count;
        }
    }
    if (count == 0) {
        error = "There is nothing to export";
        return false;
    }
    const std::string ext = extension_of(path);
    const std::string file = local_path(path);
    try {
        if (ext == "brep") {
            if (!BRepTools::Write(compound, file.c_str())) {
                error = "The BREP file could not be written";
                return false;
            }
            return true;
        }
        const TopoDS_Shape in_mm = scaled(compound, MM_PER_M);
        if (ext == "step" || ext == "stp") {
            STEPControl_Writer writer;
            if (writer.Transfer(in_mm, STEPControl_AsIs) != IFSelect_RetDone || writer.Write(file.c_str()) != IFSelect_RetDone) {
                error = "The STEP file could not be written";
                return false;
            }
            return true;
        }
        if (ext == "iges" || ext == "igs") {
            IGESControl_Controller::Init();
            IGESControl_Writer writer("MM", 1);
            writer.AddShape(in_mm);
            writer.ComputeModel();
            if (!writer.Write(file.c_str())) {
                error = "The IGES file could not be written";
                return false;
            }
            return true;
        }
        if (ext == "stl") {
            BRepMesh_IncrementalMesh mesher(in_mm, 0.01, false, 0.3, false);
            // (A flat face whose mesh doesn't cover it, a rim the mesher closed over its opening,
            // is written from pieces it meshes right, as the viewport draws it: measure.)
            TopoDS_Shape written_shape = in_mm;
            {
                BRep_Builder builder;
                TopoDS_Compound faces;
                builder.MakeCompound(faces);
                bool remade = false;
                for (TopExp_Explorer it(in_mm, TopAbs_FACE); it.More(); it.Next()) {
                    const TopoDS_Face& face = TopoDS::Face(it.Current());
                    double own = 0.0;
                    if (!measure::mesh_covers_face(face, 0.01, 0.3, &own)) {
                        const std::vector<TopoDS_Face> pieces = measure::flat_face_pieces(face, own, 0.01, 0.3);
                        if (!pieces.empty()) {
                            for (const TopoDS_Face& piece : pieces) {
                                builder.Add(faces, piece);
                            }
                            remade = true;
                            continue;
                        }
                        UtilityFunctions::push_warning("Holo Forge STL export: a face's mesh doesn't cover the face, so the STL is wrong there");
                    }
                    builder.Add(faces, face);
                }
                if (remade) {
                    written_shape = faces;
                }
            }
            StlAPI_Writer writer;
            writer.ASCIIMode() = false;
            // StlAPI_Writer::Write(shape, const char*) opens a narrow file name, which Windows
            // reads in the ANSI code page: a non-ASCII UTF-8 path was written under a garbled name
            // or not at all. OSD_OpenStream opens the UTF-8 path as UTF-16, as the STEP, IGES and
            // BREP writers do.
            std::ofstream stream;
            OSD_OpenStream(stream, file.c_str(), std::ios::out | std::ios::binary | std::ios::trunc);
            if (!stream.is_open()) {
                error = "The STL file could not be written";
                return false;
            }
            const bool written = writer.Write(written_shape, stream);
            stream.close();
            if (!written || stream.fail()) {
                error = "The STL file could not be written";
                return false;
            }
            return true;
        }
        error = "Holo Forge writes STEP, IGES, BREP and STL files";
        return false;
    }
    catch (const Standard_Failure& failure) {
        error = String("Export failed: ") + failure.GetMessageString();
        return false;
    }
}

Shape mesh_to_shape(const PackedVector3Array& positions, const PackedInt32Array& indices, const std::string& tag, String& error)
{
    const int triangles = int(indices.size() / 3);
    if (positions.is_empty() || triangles == 0) {
        error = "The mesh has no triangles";
        return Shape();
    }
    Handle(Poly_Triangulation) mesh = new Poly_Triangulation(int(positions.size()), triangles, false);
    for (int64_t i = 0; i < positions.size(); ++i) {
        const Vector3 p = positions[i];
        mesh->SetNode(int(i) + 1, gp_Pnt(p.x, p.y, p.z));
    }
    for (int t = 0; t < triangles; ++t) {
        // Godot meshes wind clockwise; OCCT wants counter-clockwise for outward faces.
        mesh->SetTriangle(t + 1, Poly_Triangle(indices[t * 3] + 1, indices[t * 3 + 2] + 1, indices[t * 3 + 1] + 1));
    }
    return mesh_shape(mesh, 1.0, tag, error);
}

}  // namespace holo_forge::exchange

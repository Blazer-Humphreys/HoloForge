// ---------------------------------------------------------------- direct shell build (no sewing), quad-only cages
// One face per cage quad (ptex face == base face). Shared TopoDS_Edge per cage edge: 3D curve = boundary iso of the
// first face, pcurves = exact iso lines on both faces. One TopoDS_Vertex per cage vertex (limit point).
#include <BRep_Builder.hxx>
#include <TopoDS_Edge.hxx>
#include <TopoDS_Wire.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Vertex.hxx>
#include <Geom2d_Line.hxx>
#include <Geom_Curve.hxx>
#include <BRepLib.hxx>

struct ShellResult {
    bool ok = false, closed = false, valid = false, validAfterSP = false;
    double volume = 0, msBuild = 0, msCheck = 0, msSameParam = 0;
    int faces = 0, edges = 0;
};

static ShellResult directShell(Cage const &c, std::vector<Handle(Geom_BSplineSurface)> const &M) {
    ShellResult R;
    double t0 = now_ms();
    const double tol = 1e-7;
    BRep_Builder B;
    int nF = (int)c.nv.size();
    if ((int)M.size() != nF) return R;
    std::vector<TopoDS_Vertex> verts(c.pts.size());
    std::vector<int> fofs(nF + 1, 0);
    for (int f = 0; f < nF; ++f) {
        if (c.nv[f] != 4) return R;
        fofs[f + 1] = fofs[f] + 4;
    }
    struct E { TopoDS_Edge e; int start; };
    std::map<std::pair<int, int>, E> edges;
    TopoDS_Shell shell;
    B.MakeShell(shell);
    // side s: iso curve, uv(t), natural start/end corner
    auto isoUV = [](int s, double t) {
        switch (s) {
            case 0: return gp_Pnt2d(t, 0);
            case 1: return gp_Pnt2d(1, t);
            case 2: return gp_Pnt2d(t, 1);
            default: return gp_Pnt2d(0, t);
        }
    };
    static const int sa[4] = {0, 1, 3, 0}, sb[4] = {1, 2, 2, 3};
    static const int loopStart[4] = {0, 1, 2, 3};
    for (int f = 0; f < nF; ++f) {
        int const *fv = &c.idx[fofs[f]];
        Handle(Geom_BSplineSurface) S = M[f];
        TopoDS_Face F;
        B.MakeFace(F, S, tol);
        TopoDS_Wire W;
        B.MakeWire(W);
        for (int s = 0; s < 4; ++s) {
            int a = fv[sa[s]], b = fv[sb[s]];
            for (int vv : {a, b})
                if (verts[vv].IsNull()) {
                    gp_Pnt2d uv = isoUV(s, vv == a ? 0.0 : 1.0);
                    B.MakeVertex(verts[vv], S->Value(uv.X(), uv.Y()), tol);
                }
            auto key = std::make_pair(std::min(a, b), std::max(a, b));
            auto it = edges.find(key);
            bool created = false;
            if (it == edges.end()) {
                Handle(Geom_Curve) C3 = (s == 0 || s == 2) ? S->VIso(s == 0 ? 0.0 : 1.0) : S->UIso(s == 1 ? 1.0 : 0.0);
                TopoDS_Edge e;
                B.MakeEdge(e, C3, tol);
                B.Range(e, 0.0, 1.0);
                TopoDS_Vertex v1 = verts[a], v2 = verts[b];
                v1.Orientation(TopAbs_FORWARD);
                v2.Orientation(TopAbs_REVERSED);
                B.Add(e, v1);
                B.Add(e, v2);
                B.UpdateVertex(v1, 0.0, e, tol);
                B.UpdateVertex(v2, 1.0, e, tol);
                it = edges.emplace(key, E{e, a}).first;
                created = true;
            }
            E &ed = it->second;
            bool same = ed.start == a;  // edge param runs a->b on this face's iso
            gp_Pnt2d o = isoUV(s, same ? 0.0 : 1.0), p1 = isoUV(s, same ? 1.0 : 0.0);
            Handle(Geom2d_Line) pc = new Geom2d_Line(o, gp_Dir2d(p1.X() - o.X(), p1.Y() - o.Y()));
            B.UpdateEdge(ed.e, pc, F, tol);
            (void)created;
            // loop order v0->v1->v2->v3: forward if the edge starts at this side's loop start vertex
            int ls = fv[loopStart[s]];
            TopoDS_Edge eo = ed.e;
            eo.Orientation(ed.start == ls ? TopAbs_FORWARD : TopAbs_REVERSED);
            B.Add(W, eo);
        }
        W.Closed(true);
        B.Add(F, W);
        B.Add(shell, F);
        R.faces++;
    }
    for (auto &kv : edges) {
        B.SameParameter(kv.second.e, true);
        B.SameRange(kv.second.e, true);
    }
    R.edges = (int)edges.size();
    shell.Closed(BRep_Tool::IsClosed(shell));
    R.closed = shell.Closed();
    TopoDS_Solid so;
    B.MakeSolid(so);
    B.Add(so, shell);
    BRepLib::OrientClosedSolid(so);
    R.msBuild = now_ms() - t0;
    double t1 = now_ms();
    R.valid = BRepCheck_Analyzer(so).IsValid();
    R.msCheck = now_ms() - t1;
    t1 = now_ms();
    if (!R.valid) {
        BRepLib::SameParameter(so, tol, Standard_True);
        R.validAfterSP = BRepCheck_Analyzer(so).IsValid();
    }
    R.msSameParam = now_ms() - t1;
    GProp_GProps gp;
    BRepGProp::VolumeProperties(so, gp, 1e-9);
    R.volume = gp.Mass();
    R.ok = true;
    return R;
}

static void shellOne(const char *name, Cage const &c, std::vector<int> levels, bool alsoSew) {
    int nPtex = numPtex(c);
    printf("\n-- %s: %d faces\n", name, nPtex);
    for (int L : levels) {
        double a = now_ms();
        auto pt = buildPT(c, Far::PatchTableFactory::Options::ENDCAP_GREGORY_BASIS, L);
        std::map<int, int> index;
        auto P = extractPatches(*pt, &index, nullptr);
        long long poles = 0;
        int fails = 0, spans = 0;
        auto M = mergePerFaceGraded(*pt, P, index, nPtex, &poles, &fails, &spans);
        double tPrep = now_ms() - a;
        ShellResult R = directShell(c, M);
        SewResult s;
        if (alsoSew) s = sewFaces(M, 1e-6);
        printf("L%-2d patches %6d poles %8lld: table+extract+merge %7.0f ms | direct shell: %d faces %d edges closed %d valid %d (after SameParameter %d) vol %.7f build %.0f ms check %.0f ms sameParam %.0f ms | sewing: %s closed %d valid %d vol %.7f %.0f ms\n",
               L, (int)P.size(), poles, tPrep, R.faces, R.edges, R.closed, R.valid, R.validAfterSP, R.volume, R.msBuild, R.msCheck,
               R.msSameParam, alsoSew ? "" : "(skipped)", s.closed, s.valid, s.volume, s.ms);
        fflush(stdout);
    }
}

static void testShell(int which) {
    printf("\n=== 8. Direct shell build (shared edges + iso pcurves) vs BRepBuilderAPI_Sewing ===\n");
    if (which & 1) shellOne("cube cage", makeCube(1), {4, 8}, true);
    if (which & 1) shellOne("noisy cube 3x3", makeNoisyCube(3, 7), {4}, true);
    if (which & 1) shellOne("torus 12x6", makeTorus(12, 6), {3}, true);
    if (which & 2) shellOne("ico L1 split (240 quads, 122 EVs)", makeIco(1, true), {3, 4}, true);
    if (which & 4) shellOne("cube 29x29 per side (5046 quads)", makeCube(29), {4}, false);
    if (which & 4) shellOne("ico L3 split (3840 quads, 1922 EVs)", makeIco(3, true), {3, 4}, false);
}

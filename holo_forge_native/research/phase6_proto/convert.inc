// ---------------------------------------------------------------- graded per-face merge + convert benchmark
// One B-spline surface per ptex face. Knots = union of the patch boundaries inside the face (graded toward the
// extraordinary corners), so the pole count grows ~ (2L)^2 instead of 4^L.
static std::vector<Handle(Geom_BSplineSurface)> mergePerFaceGraded(PT const &pt, std::vector<OPatch> const &P,
                                                                   std::map<int, int> const &index, int nFaces,
                                                                   long long *poles, int *fails, int *maxSpans) {
    std::vector<std::vector<int>> byFace(nFaces);
    for (int i = 0; i < (int)P.size(); ++i) byFace[P[i].face].push_back(i);
    std::vector<Handle(Geom_BSplineSurface)> out(nFaces);
    *poles = 0;
    *fails = 0;
    *maxSpans = 0;
    for (int f = 0; f < nFaces; ++f) {
        std::vector<double> U, Vv;
        for (int k : byFace[f]) {
            U.push_back(P[k].u0); U.push_back(P[k].u0 + P[k].frac);
            Vv.push_back(P[k].v0); Vv.push_back(P[k].v0 + P[k].frac);
        }
        std::sort(U.begin(), U.end()); U.erase(std::unique(U.begin(), U.end()), U.end());
        std::sort(Vv.begin(), Vv.end()); Vv.erase(std::unique(Vv.begin(), Vv.end()), Vv.end());
        int nu = (int)U.size() - 1, nv = (int)Vv.size() - 1;
        *maxSpans = std::max(*maxSpans, std::max(nu, nv));
        TColGeom_Array2OfBezierSurface grid(1, nu, 1, nv);
        bool ok = true;
        for (int i = 0; i < nu && ok; ++i)
            for (int j = 0; j < nv; ++j) {
                double uc = 0.5 * (U[i] + U[i + 1]), vc = 0.5 * (Vv[j] + Vv[j + 1]);
                int k = -1;
                for (int c : byFace[f])
                    if (uc > P[c].u0 && uc < P[c].u0 + P[c].frac && vc > P[c].v0 && vc < P[c].v0 + P[c].frac) { k = c; break; }
                if (k < 0) { ok = false; break; }
                OPatch const &op = P[k];
                double s1 = (U[i] - op.u0) / op.frac, s2 = (U[i + 1] - op.u0) / op.frac;
                double t1 = (Vv[j] - op.v0) / op.frac, t2 = (Vv[j + 1] - op.v0) / op.frac;
                Handle(Geom_BSplineSurface) c = op.s;
                if (s2 - s1 < 1.0 - 1e-12 || t2 - t1 < 1.0 - 1e-12) {
                    c = Handle(Geom_BSplineSurface)::DownCast(op.s->Copy());
                    c->Segment(s1, s2, t1, t2);
                }
                TColgp_Array2OfPnt pl(1, 4, 1, 4);
                c->Poles(pl);
                grid(i + 1, j + 1) = new Geom_BezierSurface(pl);
            }
        if (!ok) { ++*fails; continue; }
        TColStd_Array1OfReal UK(1, nu + 1), VK(1, nv + 1);
        for (int i = 0; i <= nu; ++i) UK(i + 1) = U[i];
        for (int j = 0; j <= nv; ++j) VK(j + 1) = Vv[j];
        GeomConvert_CompBezierSurfacesToBSplineSurface conv(grid, UK, VK, GeomAbs_C0, GeomAbs_C0, 1e-9);
        if (!conv.IsDone()) { ++*fails; continue; }
        Handle(Geom_BSplineSurface) bs = new Geom_BSplineSurface(conv.Poles()->Array2(), conv.UKnots()->Array1(), conv.VKnots()->Array1(),
                                                                 conv.UMultiplicities()->Array1(), conv.VMultiplicities()->Array1(),
                                                                 conv.UDegree(), conv.VDegree());
        const double ktol = 1e-9;
        for (int i = bs->NbUKnots() - 1; i >= 2; --i)
            if (!bs->RemoveUKnot(i, 1, ktol)) bs->RemoveUKnot(i, 2, ktol);
        for (int i = bs->NbVKnots() - 1; i >= 2; --i)
            if (!bs->RemoveVKnot(i, 1, ktol)) bs->RemoveVKnot(i, 2, ktol);
        *poles += (long long)bs->NbUPoles() * bs->NbVPoles();
        out[f] = bs;
    }
    std::vector<Handle(Geom_BSplineSurface)> res;
    for (auto &s : out) if (!s.IsNull()) res.push_back(s);
    return res;
}

// max |merged(u,v) - patch(u,v)| over a corner-graded sample grid
static double mergedVsPatches(PT const &pt, std::vector<OPatch> const &P, std::map<int, int> const &index,
                              std::vector<Handle(Geom_BSplineSurface)> const &M) {
    static const double S[] = {0, 1e-4, 1e-3, 1e-2, 0.05, 0.1, 0.25, 0.5, 0.75, 0.9, 0.95, 0.99, 0.999, 0.9999, 1};
    double mx = 0;
    for (int f = 0; f < (int)M.size(); ++f)
        for (double u : S)
            for (double v : S) {
                auto h = pt.m->FindPatch(f, u, v);
                if (!h) continue;
                auto it = index.find(h->patchIndex);
                if (it == index.end()) continue;
                OPatch const &op = P[it->second];
                double s = std::clamp((u - op.u0) / op.frac, 0.0, 1.0), t = std::clamp((v - op.v0) / op.frac, 0.0, 1.0);
                mx = std::max(mx, op.s->Value(s, t).Distance(M[f]->Value(u, v)));
            }
    return mx;
}

static void convertOne(const char *name, Cage const &c, std::vector<int> levels, bool perPatch, bool refDev) {
    int nPtex = numPtex(c);
    std::unique_ptr<PT> ref;
    if (refDev) ref = buildPT(c, Far::PatchTableFactory::Options::ENDCAP_GREGORY_BASIS, 10);
    printf("\n-- %s: %d ptex faces\n", name, nPtex);
    for (int L : levels) {
        auto pt = buildPT(c, Far::PatchTableFactory::Options::ENDCAP_GREGORY_BASIS, L);
        std::map<int, int> index;
        double a = now_ms();
        auto P = extractPatches(*pt, &index, nullptr);
        double tEx = now_ms() - a;
        double dev = 0, meanDev = 0;
        if (refDev) dev = measureDeviation(P, *ref, 3, &meanDev);
        SewResult sp;
        if (perPatch) {
            std::vector<Handle(Geom_BSplineSurface)> S;
            for (auto &p : P) S.push_back(p.s);
            g_sewCutting = true;
            sp = sewFaces(S, 1e-6);
        }
        long long poles = 0;
        int fails = 0, spans = 0;
        a = now_ms();
        auto M = mergePerFaceGraded(*pt, P, index, nPtex, &poles, &fails, &spans);
        double tM = now_ms() - a;
        double mdev = mergedVsPatches(*pt, P, index, M);
        g_sewCutting = true;
        SewResult s1 = sewFaces(M, 1e-6);
        g_sewCutting = false;
        SewResult s2 = sewFaces(M, 1e-6);
        g_sewCutting = true;
        printf("GREGORY L%-2d patches %6d build %6.1f ms extract %6.1f ms | dev vs L10 max %.2e mean %.1e | per-patch sew %s free %d closed %d valid %d vol %.7f %.0f ms | "
               "graded merge %d faces (%d fail) maxspans %d poles %lld %.0f ms, merged-vs-patch %.1e | sew(cut) free %d closed %d valid %d vol %.7f %.0f ms | sew(no cut) free %d closed %d valid %d vol %.7f %.0f ms\n",
               L, (int)P.size(), pt->ms_build, tEx, dev, meanDev, perPatch ? "" : "(skipped)", sp.freeEdges, sp.closed, sp.valid,
               sp.volume, sp.ms, (int)M.size(), fails, spans, poles, tM, mdev, s1.freeEdges, s1.closed, s1.valid, s1.volume,
               s1.ms, s2.freeEdges, s2.closed, s2.valid, s2.volume, s2.ms);
        fflush(stdout);
    }
}

static void testConvert(int which) {
    printf("\n=== 7. Convert: graded per-face merge vs per-patch faces, isolation 4..10 (Gregory end caps -> bicubic) ===\n");
    if (which & 1) convertOne("cube cage", makeCube(1), {2, 3, 4, 6, 8, 10}, true, true);
    if (which & 1) convertOne("pentagonal prism", makePentaPrism(), {4, 6, 8, 10}, true, true);
    if (which & 1) convertOne("noisy cube 3x3", makeNoisyCube(3, 7), {4, 6, 8}, true, true);
    if (which & 2) convertOne("ico L1 split (240 quads, 122 EVs)", makeIco(1, true), {3, 4, 6}, false, true);
    if (which & 4) convertOne("ico L3 split (3840 quads, 1922 EVs)", makeIco(3, true), {3, 4}, false, false);
    if (which & 8) convertOne("cube 29x29 per side (5046 quads, 8 EVs)", makeCube(29), {4, 6}, false, false);
}

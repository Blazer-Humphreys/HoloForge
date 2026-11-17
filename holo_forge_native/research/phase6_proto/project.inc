// ---------------------------------------------------------------- Interpolate on general cages + limit closest point
// Vertex limit matrix A (nV x nV) from limit stencils at each vertex's corner of an incident quad.
static bool vertexLimitMatrix(Cage const &c, Eigen::SparseMatrix<double> &A, double *msStencil) {
    double t0 = now_ms();
    std::unique_ptr<Far::TopologyRefiner> r(makeRefiner(c));
    Far::PatchTableFactory::Options po(6);
    po.SetPatchPrecision<double>();
    po.useInfSharpPatch = true;
    po.SetEndCapType(Far::PatchTableFactory::Options::ENDCAP_GREGORY_BASIS);
    r->RefineAdaptive(po.GetRefineAdaptiveOptions());
    auto const &l0 = r->GetLevel(0);
    int nV = (int)c.pts.size();
    std::vector<double> us(nV), vs(nV);
    Far::LimitStencilTableFactoryReal<double>::LocationArrayVec locs(nV);
    static const double cu[4] = {0, 1, 1, 0}, cv[4] = {0, 0, 1, 1};
    for (int v = 0; v < nV; ++v) {
        auto vf = l0.GetVertexFaces(v);
        int f = vf[0];
        auto fv = l0.GetFaceVertices(f);
        if (fv.size() != 4) return false;
        int corner = 0;
        for (int i = 0; i < fv.size(); ++i) if (fv[i] == v) corner = i;
        us[v] = cu[corner]; vs[v] = cv[corner];
        locs[v].ptexIdx = f; locs[v].numLocations = 1; locs[v].s = &us[v]; locs[v].t = &vs[v];
    }
    Far::LimitStencilTableFactoryReal<double>::Options lo;
    lo.generate1stDerivatives = false;
    std::unique_ptr<Far::LimitStencilTableReal<double> const> lst(Far::LimitStencilTableFactoryReal<double>::Create(*r, locs, nullptr, nullptr, lo));
    std::vector<Eigen::Triplet<double>> trip;
    for (int i = 0; i < lst->GetNumStencils(); ++i) {
        auto st = lst->GetStencil(i);
        for (int j = 0; j < st.GetSize(); ++j)
            if (std::fabs(st.GetWeights()[j]) > 1e-15) trip.emplace_back(i, st.GetVertexIndices()[j], st.GetWeights()[j]);
    }
    A.resize(nV, nV);
    A.setFromTriplets(trip.begin(), trip.end());
    *msStencil = now_ms() - t0;
    return true;
}

static void interpOne(const char *name, Cage c) {
    int nV = (int)c.pts.size();
    Eigen::SparseMatrix<double> A;
    double ms = 0;
    if (!vertexLimitMatrix(c, A, &ms)) { printf("%s: non-quad, skipped\n", name); return; }
    // targets: current vertex positions (make the limit pass through the cage points)
    Eigen::MatrixXd Q(nV, 3);
    for (int v = 0; v < nV; ++v) { Q(v, 0) = c.pts[v].x; Q(v, 1) = c.pts[v].y; Q(v, 2) = c.pts[v].z; }
    double t0 = now_ms();
    Eigen::SparseLU<Eigen::SparseMatrix<double>> lu;
    lu.compute(A);
    bool ok = lu.info() == Eigen::Success;
    Eigen::MatrixXd X = lu.solve(Q);
    double tSolve = now_ms() - t0;
    // Tikhonov-regularized least squares: (A^T A + lam I) x = A^T q + lam x0  (handles singular cages, e.g. the 8-vertex cube)
    t0 = now_ms();
    const double lam = 1e-8;
    Eigen::SparseMatrix<double> I(nV, nV);
    I.setIdentity();
    Eigen::SparseMatrix<double> N = Eigen::SparseMatrix<double>(A.transpose()) * A + lam * I;
    Eigen::MatrixXd X0(nV, 3);
    for (int v = 0; v < nV; ++v) { X0(v, 0) = c.pts[v].x; X0(v, 1) = c.pts[v].y; X0(v, 2) = c.pts[v].z; }
    Eigen::SimplicialLDLT<Eigen::SparseMatrix<double>> ldlt(N);
    Eigen::MatrixXd XR = ldlt.solve(Eigen::MatrixXd(A.transpose() * Q) + lam * X0);
    double tReg = now_ms() - t0;
    double regRes = (Eigen::MatrixXd(A * XR) - Q).rowwise().norm().maxCoeff();
    double regMove = (XR - X0).rowwise().norm().maxCoeff();
    // verify with uniform level-1 PrimvarRefiner::Limit (vertex-children-first ordering: index v)
    std::unique_ptr<Far::TopologyRefiner> r2(makeRefiner(c));
    r2->RefineUniform(uopt(1));
    std::vector<V> buf(r2->GetNumVerticesTotal());
    for (int v = 0; v < nV; ++v) buf[v] = V(X(v, 0), X(v, 1), X(v, 2));
    Far::PrimvarRefinerReal<double> pr(*r2);
    { V *s0 = buf.data(), *d1 = buf.data() + nV; pr.Interpolate(1, s0, d1); }
    std::vector<V> lim(r2->GetLevel(1).GetNumVertices());
    { V *s1 = buf.data() + nV, *dl = lim.data(); pr.Limit(s1, dl); }
    double maxres = 0, maxMove = 0;
    for (int v = 0; v < nV; ++v) {
        maxres = std::max(maxres, (lim[v] - c.pts[v]).len());
        maxMove = std::max(maxMove, (V(X(v, 0), X(v, 1), X(v, 2)) - c.pts[v]).len());
    }
    // condition estimate (dense, small cages only)
    double cond = -1;
    if (nV <= 400) {
        Eigen::MatrixXd D(A);
        Eigen::JacobiSVD<Eigen::MatrixXd> svd(D);
        cond = svd.singularValues()(0) / svd.singularValues()(svd.singularValues().size() - 1);
    }
    printf("%-44s nV %5d nnz %6d: stencils %.1f ms, SparseLU %s %.1f ms, max |limit(v)-target| %.1e, max control-point move %.3f, cond(A) %.3g | Tikhonov 1e-8 LDLT %.1f ms residual %.1e move %.3f\n",
           name, nV, (int)A.nonZeros(), ms, ok ? "ok" : "FAIL", tSolve, maxres, maxMove, cond, tReg, regRes, regMove);
}

// closest point on the limit surface: Bfr surfaces + seed points + clamped Newton (quads only)
static int g_projFaces = 3;
struct LimitProjector {
    std::unique_ptr<Far::TopologyRefiner> r;
    std::unique_ptr<Bfr::RefinerSurfaceFactory<>> fac;
    std::vector<Bfr::Surface<double>> surf;
    std::vector<std::vector<double>> pp;
    struct Seed { V p; int f; double u, v; };
    std::vector<Seed> seeds;
    double cell = 0;
    std::map<std::tuple<int, int, int>, std::vector<int>> grid;
    void build(Cage const &c, int rate) {
        r.reset(makeRefiner(c));
        fac = std::make_unique<Bfr::RefinerSurfaceFactory<>>(*r);
        int nF = r->GetLevel(0).GetNumFaces();
        surf.resize(nF);
        pp.resize(nF);
        std::vector<double> mp(c.pts.size() * 3);
        for (size_t i = 0; i < c.pts.size(); ++i) { mp[3 * i] = c.pts[i].x; mp[3 * i + 1] = c.pts[i].y; mp[3 * i + 2] = c.pts[i].z; }
        Bfr::Surface<double>::PointDescriptor pd(3);
        double minEdge = 1e30;
        for (int f = 0; f < nF; ++f) {
            fac->InitVertexSurface<double>(f, &surf[f]);
            pp[f].resize(surf[f].GetNumPatchPoints() * 3);
            surf[f].PreparePatchPoints(mp.data(), pd, pp[f].data(), pd);
            for (int j = 0; j <= rate; ++j)
                for (int i = 0; i <= rate; ++i) {
                    double uv[2] = {(double)i / rate, (double)j / rate}, P[3];
                    surf[f].Evaluate(uv, pp[f].data(), pd, P);
                    seeds.push_back({V(P[0], P[1], P[2]), f, uv[0], uv[1]});
                }
        }
        // uniform hash grid over seeds
        Bnd_Box b;
        for (auto &s : seeds) b.Add(gp_Pnt(s.p.x, s.p.y, s.p.z));
        double x0, y0, z0, x1, y1, z1;
        b.Get(x0, y0, z0, x1, y1, z1);
        cell = std::cbrt((x1 - x0 + 1e-9) * (y1 - y0 + 1e-9) * (z1 - z0 + 1e-9) / std::max<size_t>(1, seeds.size() / 8));
        for (int i = 0; i < (int)seeds.size(); ++i) grid[key(seeds[i].p)].push_back(i);
    }
    std::tuple<int, int, int> key(V p) const { return {(int)std::floor(p.x / cell), (int)std::floor(p.y / cell), (int)std::floor(p.z / cell)}; }
    // returns distance; out face/u/v
    double project(V p, int &of, double &ou, double &ov, int *iters = nullptr) const {
        // nearest seeds: search growing shells until something found, then one more ring
        auto k = key(p);
        std::vector<int> cand;
        int extra = -1;
        for (int R = 0; R < 64 && extra != 0; ++R) {
            if (!cand.empty() && extra < 0) extra = 2;  // two more rings after the first hit (cube cells: nearest may be farther out)
            if (extra > 0) --extra;
            for (int dx = -R; dx <= R; ++dx) for (int dy = -R; dy <= R; ++dy) for (int dz = -R; dz <= R; ++dz) {
                if (std::max({std::abs(dx), std::abs(dy), std::abs(dz)}) != R) continue;
                auto it = grid.find({std::get<0>(k) + dx, std::get<1>(k) + dy, std::get<2>(k) + dz});
                if (it != grid.end()) cand.insert(cand.end(), it->second.begin(), it->second.end());
            }
        }
        // take best 3 seeds on distinct faces, Newton on each, keep best
        std::sort(cand.begin(), cand.end(), [&](int a, int b) { return (seeds[a].p - p).len() < (seeds[b].p - p).len(); });
        std::vector<int> faces;
        double best = 1e30;
        int totalIt = 0;
        Bfr::Surface<double>::PointDescriptor pd(3);
        for (int ci : cand) {
            Seed const &s = seeds[ci];
            if (std::find(faces.begin(), faces.end(), s.f) != faces.end()) continue;
            faces.push_back(s.f);
            double u = s.u, v = s.v;
            for (int it = 0; it < 25; ++it, ++totalIt) {
                double uv[2] = {u, v}, P[3], Du[3], Dv[3], Duu[3], Duv[3], Dvv[3];
                surf[s.f].Evaluate(uv, pp[s.f].data(), pd, P, Du, Dv, Duu, Duv, Dvv);
                V r(P[0] - p.x, P[1] - p.y, P[2] - p.z), su(Du[0], Du[1], Du[2]), sv(Dv[0], Dv[1], Dv[2]);
                V suu(Duu[0], Duu[1], Duu[2]), suv(Duv[0], Duv[1], Duv[2]), svv(Dvv[0], Dvv[1], Dvv[2]);
                double gu = dot(r, su), gv = dot(r, sv);
                double huu = dot(su, su) + dot(r, suu), hvv = dot(sv, sv) + dot(r, svv), huv = dot(su, sv) + dot(r, suv);
                double det = huu * hvv - huv * huv;
                if (det <= 1e-30 || huu <= 0) { huu = dot(su, su); hvv = dot(sv, sv); huv = dot(su, sv); det = huu * hvv - huv * huv; }
                double du = -(hvv * gu - huv * gv) / det, dv = -(huu * gv - huv * gu) / det;
                double nu = std::clamp(u + du, 0.0, 1.0), nv = std::clamp(v + dv, 0.0, 1.0);
                bool done = std::fabs(nu - u) < 1e-13 && std::fabs(nv - v) < 1e-13;
                u = nu; v = nv;
                if (done) break;
            }
            double uv[2] = {u, v}, P[3];
            surf[s.f].Evaluate(uv, pp[s.f].data(), pd, P);
            double d = (V(P[0], P[1], P[2]) - p).len();
            if (d < best) { best = d; of = s.f; ou = u; ov = v; }
            if ((int)faces.size() >= g_projFaces) break;
        }
        if (iters) *iters = totalIt;
        return best;
    }
};

static void projectOne(const char *name, Cage const &c, int nQueries) {
    LimitProjector lp;
    double t0 = now_ms();
    lp.build(c, 6);
    double tBuild = now_ms() - t0;
    // brute-force reference: dense sampling rate 96 + same Newton from the best dense sample
    unsigned s = 12345;
    auto rnd = [&]() { s = s * 1664525u + 1013904223u; return ((s >> 8) & 0xffff) / 65535.0 - 0.5; };
    std::vector<V> Q(nQueries);
    // near-surface queries (Pull/Match use case): random seed point + random offset up to 0.25
    for (auto &q : Q) {
        auto const &sd = lp.seeds[(size_t)((rnd() + 0.5) * (lp.seeds.size() - 1))];
        q = sd.p + V(rnd(), rnd(), rnd()) * 0.5;
    }
    std::vector<double> D(nQueries);
    t0 = now_ms();
    long long it = 0;
    for (int i = 0; i < nQueries; ++i) { int f; double u, v; int k = 0; D[i] = lp.project(Q[i], f, u, v, &k); it += k; }
    double tQ = (now_ms() - t0) / nQueries;
    LimitProjector dense;
    dense.build(c, 48);
    double maxErr = 0;
    int worse = 0;
    for (int i = 0; i < std::min(nQueries, 300); ++i) {
        double bd = 1e30;
        for (auto &sd : dense.seeds) bd = std::min(bd, (sd.p - Q[i]).len());
        if (D[i] > bd + 1e-9) { worse++; maxErr = std::max(maxErr, D[i] - bd); }
    }
    printf("%-34s build %.1f ms, %.1f us/query (avg %.1f Newton iters), queries worse than dense-48 sampling: %d/300 (max excess %.2e)\n",
           name, tBuild, 1000 * tQ, (double)it / nQueries, worse, maxErr);
}

static void testProject() {
    printf("\n=== 9. Interpolate on general cages (creases, boundaries) ===\n");
    interpOne("cube cage", makeCube(1));
    Cage cc = makeCube(1);
    {   // inf-sharp crease loop around the top face + one sharp corner
        auto const &P = cc.pts;
        std::vector<int> top;
        for (int i = 0; i < 8; ++i) if (P[i].z > 0) top.push_back(i);
        // order top verts around: (+,+),( -,+),(-,-),(+,-)
        std::sort(top.begin(), top.end(), [&](int a, int b) { return std::atan2(P[a].y, P[a].x) < std::atan2(P[b].y, P[b].x); });
        for (int i = 0; i < 4; ++i) { cc.creasePairs.push_back(top[i]); cc.creasePairs.push_back(top[(i + 1) % 4]); cc.creaseW.push_back(10.0f); }
        for (int i = 0; i < 8; ++i) if (P[i].z < 0 && P[i].x > 0 && P[i].y > 0) { cc.cornerIdx.push_back(i); cc.cornerW.push_back(10.0f); }
    }
    interpOne("cube + inf-sharp top loop + sharp corner", cc);
    interpOne("open wavy plane 4x4", makePlane(4));
    interpOne("open wavy plane 16x16", makePlane(16));
    interpOne("noisy cube 3x3", makeNoisyCube(3, 7));
    interpOne("ico L1 split (240 quads)", makeIco(1, true));
    interpOne("ico L3 split (3840 quads)", makeIco(3, true));
    interpOne("torus 12x6", makeTorus(12, 6));
    printf("\n=== 10. Closest point on the limit surface (Bfr + hash-grid seeds rate 6 + clamped Newton, 3 faces) ===\n");
    for (int nf : {1, 3, 6}) {
    g_projFaces = nf;
    printf("-- up to %d candidate faces per query\n", nf);
    projectOne("cube cage", makeCube(1), 20000);
    projectOne("noisy cube 3x3", makeNoisyCube(3, 7), 20000);
    projectOne("ico L1 split (240 quads)", makeIco(1, true), 20000);
    projectOne("cube 16x16 per side (1536 quads)", makeCube(16), 20000);
    }
}

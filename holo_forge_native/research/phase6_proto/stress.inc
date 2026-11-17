// ---------------------------------------------------------------- stress cages (n-gons, EV-dense, open, torus)
static Cage makeIco(int level, bool splitToQuads) {
    const double t = (1 + std::sqrt(5.0)) / 2;
    std::vector<V> P = {{-1, t, 0}, {1, t, 0}, {-1, -t, 0}, {1, -t, 0}, {0, -1, t}, {0, 1, t},
                        {0, -1, -t}, {0, 1, -t}, {t, 0, -1}, {t, 0, 1}, {-t, 0, -1}, {-t, 0, 1}};
    std::vector<std::array<int, 3>> T = {{0, 11, 5}, {0, 5, 1}, {0, 1, 7}, {0, 7, 10}, {0, 10, 11}, {1, 5, 9}, {5, 11, 4},
                                         {11, 10, 2}, {10, 7, 6}, {7, 1, 8}, {3, 9, 4}, {3, 4, 2}, {3, 2, 6}, {3, 6, 8},
                                         {3, 8, 9}, {4, 9, 5}, {2, 4, 11}, {6, 2, 10}, {8, 6, 7}, {9, 8, 1}};
    for (auto &p : P) p = p * (1.0 / p.len());
    for (int l = 0; l < level; ++l) {
        std::map<std::pair<int, int>, int> mid;
        auto m = [&](int a, int b) {
            auto key = std::make_pair(std::min(a, b), std::max(a, b));
            auto it = mid.find(key);
            if (it != mid.end()) return it->second;
            V q = (P[a] + P[b]) * 0.5;
            q = q * (1.0 / q.len());
            P.push_back(q);
            return mid[key] = (int)P.size() - 1;
        };
        std::vector<std::array<int, 3>> T2;
        for (auto &tr : T) {
            int a = m(tr[0], tr[1]), b = m(tr[1], tr[2]), c = m(tr[2], tr[0]);
            T2.push_back({tr[0], a, c});
            T2.push_back({tr[1], b, a});
            T2.push_back({tr[2], c, b});
            T2.push_back({a, b, c});
        }
        T = T2;
    }
    Cage c;
    c.pts = P;
    if (!splitToQuads) {
        for (auto &tr : T) {
            c.nv.push_back(3);
            for (int i = 0; i < 3; ++i) c.idx.push_back(tr[i]);
        }
        return c;
    }
    std::map<std::pair<int, int>, int> mid;
    auto m = [&](int a, int b) {
        auto key = std::make_pair(std::min(a, b), std::max(a, b));
        auto it = mid.find(key);
        if (it != mid.end()) return it->second;
        V q = (c.pts[a] + c.pts[b]) * 0.5;
        q = q * (1.0 / q.len());
        c.pts.push_back(q);
        return mid[key] = (int)c.pts.size() - 1;
    };
    for (auto &tr : T) {
        V ce = (c.pts[tr[0]] + c.pts[tr[1]] + c.pts[tr[2]]) * (1.0 / 3);
        ce = ce * (1.0 / ce.len());
        c.pts.push_back(ce);
        int C = (int)c.pts.size() - 1;
        for (int i = 0; i < 3; ++i) {
            int a = tr[i], b = tr[(i + 1) % 3], p = tr[(i + 2) % 3];
            c.nv.push_back(4);
            int q[4] = {a, m(a, b), C, m(p, a)};
            for (int k = 0; k < 4; ++k) c.idx.push_back(q[k]);
        }
    }
    return c;
}

static Cage makePentaPrism() {
    Cage c;
    for (int z = 0; z < 2; ++z)
        for (int i = 0; i < 5; ++i) {
            double a = 2 * M_PI * i / 5;
            c.pts.push_back(V(std::cos(a), std::sin(a), z ? 1.0 : -1.0));
        }
    c.nv.push_back(5);
    for (int i = 4; i >= 0; --i) c.idx.push_back(i);  // bottom (outward -Z)
    c.nv.push_back(5);
    for (int i = 0; i < 5; ++i) c.idx.push_back(5 + i);  // top
    for (int i = 0; i < 5; ++i) {
        int j = (i + 1) % 5;
        c.nv.push_back(4);
        int q[4] = {i, j, 5 + j, 5 + i};
        for (int k = 0; k < 4; ++k) c.idx.push_back(q[k]);
    }
    return c;
}

static Cage makePlane(int k) {
    Cage c;
    for (int j = 0; j <= k; ++j)
        for (int i = 0; i <= k; ++i) c.pts.push_back(V(-1 + 2.0 * i / k, -1 + 2.0 * j / k, 0.3 * std::sin(3.0 * i / k) * std::cos(2.0 * j / k)));
    for (int j = 0; j < k; ++j)
        for (int i = 0; i < k; ++i) {
            c.nv.push_back(4);
            int a = j * (k + 1) + i;
            int q[4] = {a, a + 1, a + k + 2, a + k + 1};
            for (int n = 0; n < 4; ++n) c.idx.push_back(q[n]);
        }
    return c;
}

static Cage makeTorus(int nu, int nv, double R = 1.0, double r = 0.4) {
    Cage c;
    for (int j = 0; j < nv; ++j)
        for (int i = 0; i < nu; ++i) {
            double a = 2 * M_PI * i / nu, b = 2 * M_PI * j / nv;
            c.pts.push_back(V((R + r * std::cos(b)) * std::cos(a), (R + r * std::cos(b)) * std::sin(a), r * std::sin(b)));
        }
    for (int j = 0; j < nv; ++j)
        for (int i = 0; i < nu; ++i) {
            int i1 = (i + 1) % nu, j1 = (j + 1) % nv;
            c.nv.push_back(4);
            int q[4] = {j * nu + i, j1 * nu + i, j1 * nu + i1, j * nu + i1};
            for (int n = 0; n < 4; ++n) c.idx.push_back(q[n]);
        }
    return c;
}

static Cage makeNoisyCube(int k, unsigned seed) {
    Cage c = makeCube(k);
    unsigned s = seed;
    auto rnd = [&]() { s = s * 1664525u + 1013904223u; return ((s >> 8) & 0xffff) / 65535.0 - 0.5; };
    for (auto &p : c.pts) p = p + V(rnd(), rnd(), rnd()) * (0.6 / k);
    return c;
}

static int numPtex(Cage const &c) {
    std::unique_ptr<Far::TopologyRefiner> r(makeRefiner(c));
    Far::PtexIndices pi(*r);
    return pi.GetNumFaces();
}

static void stressOne(const char *name, Cage const &c, bool closedExpected, int maxL, bool measureGapsToo) {
    int nPtex = numPtex(c);
    auto ref = buildPT(c, Far::PatchTableFactory::Options::ENDCAP_GREGORY_BASIS, 10);
    double vref = closedExpected ? refVolume(*ref, nPtex, 64) : 0;
    // valence histogram
    std::unique_ptr<Far::TopologyRefiner> r0(makeRefiner(c));
    auto const &l0 = r0->GetLevel(0);
    int nEV = 0;
    for (int v = 0; v < l0.GetNumVertices(); ++v) {
        bool bnd = l0.IsVertexBoundary(v);
        int val = l0.GetVertexEdges(v).size();
        if ((!bnd && val != 4) || (bnd && val != 3 && val != 2)) nEV++;
    }
    int nNonQuad = 0;
    for (int f = 0; f < l0.GetNumFaces(); ++f) nNonQuad += l0.GetFaceVertices(f).size() != 4;
    printf("\n-- %s: %d faces (%d non-quad), %d verts, %d extraordinary, %d ptex faces, ref volume %.6f\n", name,
           l0.GetNumFaces(), nNonQuad, l0.GetNumVertices(), nEV, nPtex, vref);
    int ecs[2] = {Far::PatchTableFactory::Options::ENDCAP_BSPLINE_BASIS, Far::PatchTableFactory::Options::ENDCAP_GREGORY_BASIS};
    for (int ec : ecs)
        for (int L = 2; L <= maxL; ++L) {
            auto pt = buildPT(c, (Far::PatchTableFactory::Options::EndCapType)ec, L);
            std::map<int, int> index;
            int skipped = 0;
            double a = now_ms();
            auto P = extractPatches(*pt, &index, &skipped);
            double tExtract = now_ms() - a;
            int nGreg = 0;
            for (auto &p : P) nGreg += p.type == Far::PatchDescriptor::GREGORY_BASIS;
            GapStats g;
            if (measureGapsToo) g = measureGaps(P, 4, 6);
            double meanDev = 0;
            double maxDev = measureDeviation(P, *ref, 3, &meanDev);
            SewResult sp;
            if (P.size() <= 25000) {
                std::vector<Handle(Geom_BSplineSurface)> S;
                for (auto &p : P) S.push_back(p.s);
                sp = sewFaces(S, 1e-6);
            }
            int spans = 0, fails = 0;
            a = now_ms();
            g_mergedPoles = 0;
            auto M = mergePerFace(*pt, P, index, nPtex, &spans, &fails);
            double tMerge = now_ms() - a;
            SewResult sm = sewFaces(M, 1e-6);
            printf("%-8s L%d patches %6d (gregory %5d, skipped %d) build %6.1f ms extract %6.1f ms | gap %s%.1e%s ang %.3f° | dev max %.2e mean %.1e | "
                   "per-patch sew: free %d shells %d closed %d valid %d vol_err %.4f%% %.0f ms | merged %d faces (%d fail, maxspans %d, poles %lld) %.0f ms, sew free %d closed %d valid %d vol_err %.4f%% %.0f ms\n",
                   ecName(ec), L, (int)P.size(), nGreg, skipped, pt->ms_build, tExtract, measureGapsToo ? "" : "(n/a ", g.maxGap,
                   measureGapsToo ? "" : ")", g.maxAngleDeg, maxDev, meanDev, sp.freeEdges, sp.shells, sp.closed, sp.valid,
                   vref > 0 ? 100 * (sp.volume - vref) / vref : 0.0, sp.ms, (int)M.size(), fails, spans, g_mergedPoles, tMerge,
                   sm.freeEdges, sm.closed, sm.valid, vref > 0 ? 100 * (sm.volume - vref) / vref : 0.0, sm.ms);
            fflush(stdout);
        }
}

static void testStress(int which) {
    printf("\n=== 6. Stress cages: n-gons, triangles, EV-dense, open, torus, noisy ===\n");
    if (which & 1) stressOne("pentagonal prism (n-gons)", makePentaPrism(), true, 5, true);
    if (which & 1) stressOne("icosahedron L0 (20 triangles, TRI_SUB_SMOOTH)", makeIco(0, false), true, 5, true);
    if (which & 1) stressOne("ico L1 split to quads (240 quads, val 3/5/6)", makeIco(1, true), true, 4, true);
    if (which & 1) stressOne("noisy cube 3x3 (54 quads, asymmetric)", makeNoisyCube(3, 7), true, 4, true);
    if (which & 1) stressOne("open wavy plane 4x4 (boundary edge+corner)", makePlane(4), false, 3, true);
    if (which & 1) stressOne("torus 12x6 (all regular)", makeTorus(12, 6), true, 3, true);
    if (which & 2) stressOne("ico L2 split to quads (960 quads)", makeIco(2, true), true, 3, false);
    if (which & 4) stressOne("ico L3 split to quads (3840 quads, 1922 EVs)", makeIco(3, true), true, 3, false);
}
